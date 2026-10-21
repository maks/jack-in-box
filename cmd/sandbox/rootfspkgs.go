package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/ayush6624/sandbox/internal/config"
)

// defaultGuestGoVersion is what `rootfs-pkgs --go` installs when no version is
// given. Keep in sync with go.mod, scripts/build-devbox-rootfs.sh (GO_VERSION)
// and infra/gcp/startup-control.sh.
const defaultGuestGoVersion = "1.25.3"

// safePkgName keeps a package name from becoming shell in the chroot script.
// Debian names are alphanumerics plus + . - : (the last for arch qualifiers).
var safePkgName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+._:-]*$`)

func rootfsPkgsCmd() *cobra.Command {
	var (
		pkgCfg    string
		rootfs    string
		goVersion string
		listFile  string
		withGo    bool
		force     bool
	)
	cmd := &cobra.Command{
		Use:   "rootfs-pkgs [package...]",
		Short: "Install packages into the BASE rootfs so every new sandbox has them",
		// No args = the declared set in scripts/guest-packages.txt, which is the
		// same list the from-scratch build installs.
		Long: `Installs into the base image itself (/opt/fc/devbox-rootfs.ext4) by loop-mounting
it and chrooting in, so every NEWLY created sandbox boots with the software
already present. No apt at boot, no per-sandbox install.

Installing inside a running sandbox is NOT the same thing: a sandbox's files
live in its own copy of this image and are deleted with it.

The base image is edited offline, so this needs no debootstrap, no dnf
--installroot and no rebuild of the base OS — it is the fast path for adding a
package to a working box. It works on either guest distro: the package manager is
read off the mounted tree (apt-get / dnf / microdnf).

WARNING — the golden snapshot. Mounting the image dirties its mtime, and the
golden's validity is keyed on the base rootfs (mtime, size). So the next
"sandbox serve" cold-boots a throwaway VM to rebuild the golden (~1 minute), and
creates are hot again after that. Destroy your sandboxes first: a RUNNING one is
refused here (override with --force), and a HIBERNATED one survives this check
but has a memory diff anchored to the old golden base, so wake or destroy it
beforehand.

With no package names it installs the declared set for that image —
scripts/guest-packages.txt for an apt guest, scripts/guest-packages-fedora.txt
for a dnf one (--list-file to point elsewhere) — the same lists the from-scratch
builders install. Those files are where vim, micro, go, htop, jq and the rest are
declared, so adding software to every VM means adding a line there and then
running this command; it does not mean rebuilding the image.

Examples:
  sudo ./sandbox rootfs-pkgs                 # the declared list, into this image
  sudo ./sandbox rootfs-pkgs --rootfs /opt/fc/devbox-rootfs.ext4.bak --force micro
  sudo ./sandbox rootfs-pkgs micro ripgrep   # just these, right now
  sudo ./sandbox rootfs-pkgs --go            # + the Go toolchain
  sudo ./sandbox rootfs-pkgs --go --go-version 1.26.0 golang-mode-go
`,
		Args: cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			// Naming a version implies the toolchain, so --go-version alone works.
			if cmd.Flags().Changed("go-version") {
				withGo = true
			}
			return rootfsPkgs(pkgCfg, rootfs, args, listFile, withGo, goVersion, force)
		},
	}
	cmd.Flags().StringVar(&pkgCfg, "config", "configs/devbox.json", "path to JSON config")
	cmd.Flags().StringVar(&rootfs, "rootfs", "", "base rootfs image (defaults to config.rootfs_base)")
	cmd.Flags().BoolVar(&withGo, "go", false, "install the Go toolchain from the go.dev tarball")
	cmd.Flags().StringVar(&goVersion, "go-version", "", "Go version for --go (default "+defaultGuestGoVersion+")")
	cmd.Flags().StringVar(&listFile, "list-file", "", "package list used when no packages are named (default: scripts/guest-packages-fedora.txt for a dnf image, scripts/guest-packages.txt for apt)")
	cmd.Flags().BoolVar(&force, "force", false, "proceed even while Firecracker VMs are running")
	return cmd
}

// rootfsPkgs mounts the base image, installs the requested apt packages and/or
// the Go toolchain, then unmounts and reports what the golden snapshot now
// needs. Every failure path unwinds the mounts (LIFO) before returning.
func rootfsPkgs(cfgFile, rootfs string, pkgs []string, listFile string, withGo bool, goVersion string, force bool) error {
	if rootfs == "" {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}
		rootfs = cfg.RootfsBase
	}
	if _, err := os.Stat(rootfs); err != nil {
		return fmt.Errorf("base rootfs: %w (build it with scripts/build-devbox-rootfs.sh, or restore a backup)", err)
	}
	if goVersion == "" {
		goVersion = defaultGuestGoVersion
	}
	if !force {
		if pids := runningFirecrackers(); len(pids) > 0 {
			return fmt.Errorf("%d Firecracker VM(s) running (pid %s): destroy them first, or pass --force.\n"+
				"  hibernated sandboxes are not running and so are not detected here — wake or destroy\n"+
				"  those too, because their memory diff is anchored to the current golden base",
				len(pids), strings.Join(pids, " "))
		}
	}

	mnt, err := os.MkdirTemp("", "rootfs-pkgs-")
	if err != nil {
		return err
	}
	defer os.Remove(mnt)

	var mounted []string
	unmountAll := func() {
		for i := len(mounted) - 1; i >= 0; i-- {
			out, err := exec.Command("umount", mounted[i]).CombinedOutput()
			if err == nil {
				continue
			}
			// Lazy detach: after a failed apt a busy bind mount would otherwise
			// leave the image mounted until someone finds who holds it.
			if out2, err2 := exec.Command("umount", "-l", mounted[i]).CombinedOutput(); err2 != nil {
				fmt.Fprintf(os.Stderr, "WARN umount %s: %v: %s (lazy: %v: %s)\n",
					mounted[i], err, strings.TrimSpace(string(out)), err2, strings.TrimSpace(string(out2)))
			}
		}
		mounted = nil
	}
	defer unmountAll()

	mount := func(source, target string, opts ...string) error {
		args := []string{}
		if len(opts) > 0 {
			args = append(args, "-o", strings.Join(opts, ","))
		}
		args = append(args, source, target)
		if out, err := exec.Command("mount", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("mount %s at %s: %w: %s", source, target, err, strings.TrimSpace(string(out)))
		}
		mounted = append(mounted, target)
		return nil
	}

	fmt.Printf("==> mounting %s at %s\n", rootfs, mnt)
	if err := mount(rootfs, mnt, "loop"); err != nil {
		return err
	}
	// apt needs /dev (null, urandom), /proc and /sys to exist and be real.
	for _, d := range []string{"dev", "proc", "sys"} {
		if err := mount("/"+d, filepath.Join(mnt, d), "bind"); err != nil {
			return err
		}
	}
	// The image's resolv.conf carries the config's guest nameservers, which the
	// chroot cannot reach; bind the host's so apt resolves. Bind rather than
	// copy: the image's own file must survive untouched.
	if err := mount("/etc/resolv.conf", filepath.Join(mnt, "etc", "resolv.conf"), "bind"); err != nil {
		return err
	}
	// The same command patches Ubuntu and Fedora images, and the two differ from
	// here on: install command, cache cleanup, and installed-check.
	mgr, err := detectPkgManager(mnt)
	if err != nil {
		return err
	}
	fmt.Printf("==> guest package manager: %s\n", mgr)

	if len(pkgs) == 0 && !withGo {
		resolved := listFile
		if resolved == "" {
			resolved = defaultListFile(mgr)
		}
		list, lerr := loadGuestPackages(resolved)
		if lerr != nil {
			return lerr
		}
		fmt.Printf("==> no packages named, using %s (%d of them)\n", resolved, len(list))
		pkgs = list
	}
	for _, p := range pkgs {
		if !safePkgName.MatchString(p) {
			return fmt.Errorf("refusing suspicious package name %q", p)
		}
	}
	if len(pkgs) == 0 && !withGo {
		return errors.New("nothing to do: no packages named and the list is empty")
	}

	// No systemd is running in a chroot, so tell dpkg postinst hooks not to start
	// or restart services (RPM scriptlets ignore this file; harmless either way).
	// Removed while still mounted (defer is LIFO).
	policyFile := filepath.Join(mnt, "usr", "sbin", "policy-rc.d")
	if err := os.WriteFile(policyFile, []byte("#!/bin/sh\n# sandbox rootfs-pkgs\nexit 101\n"), 0o755); err != nil {
		return fmt.Errorf("write policy-rc.d: %w", err)
	}
	defer func() {
		if err := os.Remove(policyFile); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "WARN remove policy-rc.d: %v\n", err)
		}
	}()

	run := func(label, script string) error {
		fmt.Printf("==> %s\n", label)
		c := exec.Command("chroot", mnt, "/bin/sh", "-c", script)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		return nil
	}

	if len(pkgs) > 0 {
		quoted := make([]string, 0, len(pkgs))
		for _, p := range pkgs {
			quoted = append(quoted, "'"+p+"'")
		}
		script := installScript(mgr) + strings.Join(quoted, " ")
		if err := run(mgr+" install "+strings.Join(pkgs, " "), script); err != nil {
			return err
		}
	}

	if withGo && mgr != "apt" {
		// Fedora's golang tracks current releases, so the distro package IS the
		// toolchain: the go.dev tarball below exists only to dodge noble's Go 1.22.
		if err := run(mgr+" install golang", installScript(mgr)+"'golang'"); err != nil {
			return err
		}
	}

	if withGo && mgr == "apt" {
		// Distro golang-go is deliberately not used: the Ubuntu noble archive is
		// Go 1.22, which refuses to build a go.mod declaring a newer `go`
		// directive — every copied project would fail its first `go build`.
		tgz := filepath.Join(os.TempDir(), fmt.Sprintf("sandbox-go-%s.tgz", goVersion))
		if err := downloadFile(fmt.Sprintf("https://go.dev/dl/go%s.linux-amd64.tar.gz", goVersion), tgz); err != nil {
			return err
		}
		defer os.Remove(tgz)
		if out, err := exec.Command("gzip", "-t", tgz).CombinedOutput(); err != nil {
			return fmt.Errorf("verify go tarball: %w: %s", err, strings.TrimSpace(string(out)))
		}
		if err := os.RemoveAll(filepath.Join(mnt, "usr", "local", "go")); err != nil {
			return fmt.Errorf("replace existing toolchain: %w", err)
		}
		fmt.Printf("==> extracting Go %s into the image\n", goVersion)
		if out, err := exec.Command("tar", "-C", filepath.Join(mnt, "usr", "local"), "-xzf", tgz).CombinedOutput(); err != nil {
			return fmt.Errorf("extract go tarball: %w: %s", err, strings.TrimSpace(string(out)))
		}
		for _, b := range []string{"go", "gofmt"} {
			link := filepath.Join(mnt, "usr", "local", "bin", b)
			_ = os.Remove(link)
			// Absolute target: inside a VM the image is mounted at /, so a
			// relative-to-the-mount path would be wrong once booted.
			if err := os.Symlink("/usr/local/go/bin/"+b, link); err != nil {
				return fmt.Errorf("link %s: %w", b, err)
			}
		}
		// The go binary resolves its own symlink, so GOROOT needs no env var.
		// profile.d is for login shells (sandboxd runs exec and the pty as
		// `bash -l`); the /usr/local/bin links cover everything else.
		sh := "export PATH=\"$PATH:/usr/local/go/bin\"\n"
		if err := os.WriteFile(filepath.Join(mnt, "etc", "profile.d", "golang.sh"), []byte(sh), 0o644); err != nil {
			return fmt.Errorf("write profile.d/golang.sh: %w", err)
		}
	}

	// Trim what the package manager fetched, or every added package grows the
	// image permanently.
	_ = run("cleaning package caches", cleanScript(mgr))

	fmt.Println("==> verifying inside the image")
	checks := make([]string, 0, len(pkgs)+1)
	for _, p := range pkgs {
		checks = append(checks, installedCheck(mgr, p))
	}
	if withGo {
		if mgr == "apt" {
			checks = append(checks, "/usr/local/go/bin/go version")
		} else {
			checks = append(checks, "go version")
		}
	}
	if err := run("verify", strings.Join(checks, "; ")); err != nil {
		return fmt.Errorf("post-install verification failed (the image is installed but unverified): %w", err)
	}

	if out, err := exec.Command("sync").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "WARN sync: %v: %s\n", err, strings.TrimSpace(string(out)))
	}
	unmountAll()

	nf, err := os.Stat(rootfs)
	if err != nil {
		return err
	}
	self := os.Args[0]
	fmt.Printf("\n==> %s is now %d bytes (mtime %s)\n", rootfs, nf.Size(), nf.ModTime().Format("2006-01-02T15:04:05Z07:00"))
	fmt.Println("    The golden snapshot is keyed on this (mtime, size), so it is now invalid:")
	fmt.Println("    the next `sandbox serve` cold-boots one throwaway VM to rebuild it (~1 min),")
	fmt.Println("    and creates are hot again after that.")
	fmt.Println("    Next, in this order:")
	fmt.Printf("      sudo %s install-agent --agent ./sandboxd\n", self)
	fmt.Println("        (re-stamps the image for its baked agent; without it the following")
	fmt.Println("         restart rebuilds the golden, then a later install-agent invalidates it again)")
	fmt.Println("      sudo ./sandbox stop-server")
	fmt.Println("      sudo ./sandbox serve --config configs/devbox.json   # + your --listen/--token flags")
	return nil
}

// detectPkgManager reads the package manager out of the mounted guest tree,
// because this command has to patch both the Ubuntu and the Fedora image.
func detectPkgManager(mnt string) (string, error) {
	for _, c := range []struct{ path, mgr string }{
		{"usr/bin/apt-get", "apt"},
		{"usr/bin/dnf", "dnf"},
		{"usr/bin/dnf5", "dnf"},
		{"usr/bin/dnf-3", "dnf"},
		{"usr/bin/microdnf", "microdnf"},
	} {
		if _, err := os.Stat(filepath.Join(mnt, c.path)); err == nil {
			return c.mgr, nil
		}
	}
	return "", fmt.Errorf("no package manager found in %s (expected apt-get, dnf or microdnf) — "+
		"a tree built by debootstrap with --variant=minbase has none; install one first", mnt)
}

// defaultListFile picks the declared list that matches the guest distro. Both
// live next to each other in scripts/, so one repo drives either image.
func defaultListFile(mgr string) string {
	if mgr == "apt" {
		return "scripts/guest-packages.txt"
	}
	for _, c := range []string{"scripts/guest-packages-fedora.txt", "scripts/guest-packages.txt"} {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return "scripts/guest-packages-fedora.txt"
}

func installScript(mgr string) string {
	switch mgr {
	case "apt":
		return "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y --no-install-recommends "
	case "microdnf":
		return "microdnf -y install "
	default: // dnf, dnf5
		return "dnf -y install "
	}
}

func cleanScript(mgr string) string {
	if mgr == "apt" {
		return "apt-get clean; rm -rf /var/lib/apt/lists/*"
	}
	return "dnf clean all 2>/dev/null || microdnf clean all; rm -rf /var/cache/dnf /var/cache/libdnf5"
}

func installedCheck(mgr, pkg string) string {
	if mgr == "apt" {
		return "dpkg-query -W --showformat='${Version}  " + pkg + "\\n' '" + pkg + "'"
	}
	return "rpm -q --qf '%{VERSION}-%{RELEASE}  " + pkg + "\\n' '" + pkg + "'"
}

// loadGuestPackages reads the declared guest package list: one apt package per
// line, blank lines and `#` comments ignored. It is the same file
// scripts/build-devbox-rootfs.sh installs, so patching an existing image and
// building a new one cannot drift apart.
func loadGuestPackages(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("no packages named and the default list is unreadable: %w\n"+
			"  pass package names explicitly, or run from the deployed repo (which has scripts/guest-packages.txt)", err)
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s lists no packages", path)
	}
	return out, nil
}

// downloadFile pulls a URL to a host path with curl, so the Go tarball does not
// need a working resolver inside the chroot.
func downloadFile(url, dst string) error {
	fmt.Printf("==> downloading %s\n", url)
	c := exec.Command("curl", "-fsSL", "--retry", "3", "-o", dst, url)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		_ = os.Remove(dst)
		return fmt.Errorf("download %s: %w", url, err)
	}
	return nil
}

// runningFirecrackers lists live Firecracker pids by /proc/<pid>/comm, the same
// test reconcile() uses to identify orphans.
func runningFirecrackers() []string {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var pids []string
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		comm, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm"))
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(comm)) == "firecracker" {
			pids = append(pids, e.Name())
		}
	}
	return pids
}

#!/usr/bin/env bash
# Build the devbox guest image with dnf — the Fedora/RHEL-native equivalent of
# build-devbox-rootfs.sh (which uses Debian's debootstrap).
#
#   sudo bash scripts/build-devbox-rootfs-fedora.sh
#
# Produces the SAME artifact at /opt/fc/devbox-rootfs.ext4, so `sandbox serve`,
# the golden snapshot, hibernation and the agent all work unchanged. It differs
# only in how the tree is populated: `dnf --installroot` instead of debootstrap,
# `dnf` instead of apt inside the chroot.
#
# The guest distro is a free choice — the host only needs KVM, loop devices and
# iptables. What has to match is the *toolchain* used to build it: this script
# needs dnf on the host (Fedora/RHEL/Stream), and the other needs debootstrap.
# Fedora's guest also gets real current Go (`golang`) from the distro, so the
# go.dev tarball the Ubuntu image needs is not used here.
#
# Supports resuming: completed steps are marked in $BUILD_DIR and skipped.
set -euo pipefail

ASSET_DIR="${ASSET_DIR:-/opt/fc}"
ROOTFS_PATH="${ROOTFS_PATH:-${ASSET_DIR}/devbox-rootfs.ext4}"
ROOTFS_SIZE="${ROOTFS_SIZE:-10G}"
BUILD_DIR="${BUILD_DIR:-/opt/fc/rootfs-build-fedora}"

# Guest Fedora release. Defaults to the host's, which is what you want on a
# single-distro fleet; override to build a different release than you run.
REL="${FEDORA_RELEASE:-$(rpm -E '%fedora' 2>/dev/null || echo 44)}"

PKG_LIST="$(dirname "${BASH_SOURCE[0]}")/guest-packages-fedora.txt"

# The guest runs in permissive-to-off SELinux territory on purpose: the image is
# created by `mkfs.ext4 -d`, which cannot apply an RPM-era file_contexts label,
# so an enforcing policy would deny sshd and sandboxd on files labelled with
# whatever the build host's fs carries. We exclude the policy package and pin
# disabled; flip it on only with a real relabel story.
DNF_OPTS=(--setopt=install_weak_deps=False --setopt=tsflags=nocontexts
  --exclude=selinux-policy-targeted --exclude=selinux-policy-mls --exclude=firewalld)

if [[ -f "$ROOTFS_PATH" ]]; then
  echo "==> Rootfs already exists at ${ROOTFS_PATH}"
  echo "  Move it aside first if you want to rebuild:"
  echo "    sudo mv ${ROOTFS_PATH} ${ROOTFS_PATH}.bak"
  echo "  (the golden snapshot is keyed on this file's mtime+size, so replacing it"
  echo "   makes the next 'sandbox serve' cold-build a fresh golden, ~1 min.)"
  exit 0
fi

# dnf5 is the default on recent Fedora and does not necessarily ship a `dnf`
# symlink, so resolve whichever the host actually has and use it everywhere.
DNF="$(command -v dnf 2>/dev/null || command -v dnf5 2>/dev/null || true)"
if [[ -z "$DNF" ]]; then
  echo "ERROR: neither dnf nor dnf5 found. This builder needs a Fedora/RHEL host." >&2
  echo "  On a Debian/Ubuntu host use: sudo bash scripts/build-devbox-rootfs.sh" >&2
  echo "  Or skip building entirely and pull a prebuilt image: sudo bash scripts/fetch-rootfs.sh" >&2
  exit 1
fi
if [[ ! -s "$PKG_LIST" ]]; then
  echo "ERROR: guest package list missing at $PKG_LIST" >&2
  exit 1
fi

# dnf5 deliberately does NOT read the host's repo configuration when an
# --installroot is given: an empty installroot therefore resolves ZERO
# repositories and every transaction dies with "No repositories were loaded from
# the installroot" plus a suggestion to pass --use-host-config. dnf4 loads host
# repos unasked and rejects that flag as an unknown argument, so gate on the
# reported version rather than the binary name -- Fedora ships `dnf` as dnf5 on
# some releases and as dnf4 on others. Every installroot call needs it, because
# the packages that would provide repo files are the ones being installed.
HOST_CONFIG=()
DNF_IS_5=0
# Ask the binary whether it accepts the flag rather than trusting its name or its
# --version banner (which needs /etc/dnf/dnf.conf to be readable, and is a dnf5
# alias under several names). A rejected option exits non-zero, so this probe is
# the same question the build actually cares about.
if "$DNF" --use-host-config --version >/dev/null 2>&1; then
  DNF_IS_5=1
elif [[ "$(basename "$DNF")" == dnf5 ]] || "$DNF" --version 2>/dev/null | head -1 | grep -qi 'dnf5'; then
  DNF_IS_5=1
fi
# Escape hatch for a release whose --version output this heuristic misses.
if [[ "${DNF_USE_HOST_CONFIG:-}" == "1" ]]; then DNF_IS_5=1; fi
if [[ "${DNF_USE_HOST_CONFIG:-}" == "0" ]]; then DNF_IS_5=0; fi
if [[ "$DNF_IS_5" == "1" ]]; then
  HOST_CONFIG=(--use-host-config)
  echo "   dnf: ${DNF} (dnf5) -> ${HOST_CONFIG[*]} for --installroot transactions"
else
  echo "   dnf: ${DNF} (dnf4) -> host repos are loaded unasked"
fi

# One host-side --installroot transaction, retrying without the SELinux excludes.
# selinux-policy-targeted is a MANDATORY member of @core on some releases, so
# excluding it is a hard dependency error rather than a smaller image; the
# fallback keeps the build going and step 5's SELINUX=disabled is what actually
# matters (an enforcing policy would deny sshd + sandboxd, because mkfs.ext4 -d
# cannot apply RPM file_contexts to the tree).
dnf_installroot() {
  if ! "$DNF" --installroot="$BUILD_DIR" --releasever="$REL" -y "${HOST_CONFIG[@]}" \
      "${DNF_OPTS[@]}" "$@"; then
    echo "  ^^ retrying without the SELinux excludes (mandatory @core member on some releases)" >&2
    "$DNF" --installroot="$BUILD_DIR" --releasever="$REL" -y "${HOST_CONFIG[@]}" \
      --setopt=install_weak_deps=False --setopt=tsflags=nocontexts "$@"
  fi
}
if [[ "$(id -u)" != "0" ]]; then
  echo "needs root (dnf --installroot, mknod, mkfs)" >&2
  exit 1
fi

echo "==> Building Fedora ${REL} devbox rootfs (${ROOTFS_SIZE})"
echo "  Build dir: ${BUILD_DIR}"
echo "  Output:    ${ROOTFS_PATH}"
mkdir -p "$ASSET_DIR" "$BUILD_DIR"

# /dev, /proc and /sys are bound for the chroot steps (RPM scriptlets and npm
# want /dev/null, dnf wants /proc) and unmounted before mkfs, so the image
# carries an EMPTY /dev — devtmpfs populates it at boot.
MOUNTED=()
cleanup_mounts() {
  local i
  for ((i = ${#MOUNTED[@]} - 1; i >= 0; i--)); do
    umount "${MOUNTED[i]}" 2>/dev/null || umount -l "${MOUNTED[i]}" 2>/dev/null ||
      echo "WARN: could not unmount ${MOUNTED[i]}" >&2
  done
  MOUNTED=()
}
trap cleanup_mounts EXIT

bind_mounts() {
  local d
  for d in dev proc sys; do
    mkdir -p "$BUILD_DIR/$d"
    if ! grep -q " $BUILD_DIR/$d " /proc/mounts; then
      mount --bind "/$d" "$BUILD_DIR/$d"
      MOUNTED+=("$BUILD_DIR/$d")
    fi
  done
  # A resolver the chroot can actually use. Fedora ships the host's
  # /etc/resolv.conf as a symlink into /run/systemd/resolve, and neither the
  # path nor the 127.0.0.53 stub exists in the target tree. Written as a REAL
  # file: /proc/net/pnp symlinks are the c-ares bug documented in CLAUDE.md, and
  # step 5 swaps in the boot-time materializer regardless.
  local ns="" candidate
  for candidate in "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" \
    /run/systemd/resolve/resolv.conf; do
    if [[ -n "$candidate" && -r "$candidate" ]]; then
      ns="$(grep -hoE '^nameserver[[:space:]]+[^[:space:]]+' "$candidate" 2>/dev/null |
        awk '$2 !~ /^127\./ { print $2; exit }' || true)"
      [[ -n "$ns" ]] && break
    fi
  done
  rm -f "$BUILD_DIR/etc/resolv.conf" # rm first: tee follows symlinks out of the tree
  printf 'nameserver %s\n' "${ns:-1.1.1.1}" >"$BUILD_DIR/etc/resolv.conf"
}

# --- Step 1: Fedora base tree ---
if [[ -f "$BUILD_DIR/.step1-done" ]]; then
  echo "==> [1/6] Base tree already installed, skipping"
else
  echo ""
  echo "==> [1/6] dnf --installroot @core (Fedora ${REL})..."
  # @core is the debootstrap "required+important" equivalent: systemd, coreutils,
  # dnf, userspace. No kernel package — Firecracker boots the host-side vmlinux,
  # same as every other guest here. Group and package installs are separate
  # commands because dnf5 (the default on recent Fedora) spells the group form as
  # `group install`, which cannot also take loose packages.
  dnf_installroot group install core
  dnf_installroot install dnf dnf-plugins-core systemd curl ca-certificates iproute \
    procps-ng util-linux passwd shadow-utils which tar xz gzip findutils sudo \
    openssh-server openssh-clients

  bind_mounts
  touch "$BUILD_DIR/.step1-done"
fi
# Resume-safe: every later step needs these bound.
bind_mounts

# --- Step 2: Node.js 22 ---
if [[ -f "$BUILD_DIR/.step2-done" ]]; then
  echo "==> [2/6] Node.js already installed, skipping"
else
  echo ""
  echo "==> [2/6] Installing Node.js 22 LTS..."
  # NodeSource RPM rather than Fedora's nodejs module, so the guest gets the same
  # pinned major as the Ubuntu image and the docs ("Node 22") either way.
  # The installroot gets its own resolver line below, and the same dnf-or-dnf5
  # choice: a Fedora 44 tree ships dnf5, and `dnf` is only a compatibility alias.
  chroot "$BUILD_DIR" bash -c '
    set -e
    D="$(command -v dnf || command -v dnf5)"
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    "$D" install -y nodejs
    node --version
    npm --version
  '
  touch "$BUILD_DIR/.step2-done"
fi

# --- Step 3: pnpm, TypeScript, AI coding CLIs ---
if [[ -f "$BUILD_DIR/.step3-done" ]]; then
  echo "==> [3/6] pnpm + TypeScript + AI CLIs already installed, skipping"
else
  echo ""
  echo "==> [3/6] Installing pnpm, TypeScript and the pi coding agent..."
  # pi (@earendil-works/pi-coding-agent, binary `pi`) is a global npm CLI. Users
  # bring their own model credentials at runtime; nothing secret is baked in.
  # --ignore-scripts is upstream's documented global-install flag (pi needs no
  # lifecycle scripts). Requires Node >= 22.19, which step 2's NodeSource 22
  # satisfies. Claude Code and Codex are deliberately not installed — ~250 MB of
  # image for agents this project does not use.
  chroot "$BUILD_DIR" bash -c '
    npm install -g --ignore-scripts pnpm typescript @earendil-works/pi-coding-agent
    node --version
    pnpm --version
    tsc --version
    pi --version || true
  '
  touch "$BUILD_DIR/.step3-done"
fi

# --- Step 4: Python, Go, editors, build tooling, the sandbox user ---
if [[ -f "$BUILD_DIR/.step4-done" ]]; then
  echo "==> [4/6] Packages + user already installed, skipping"
else
  echo ""
  echo "==> [4/6] Installing guest packages (scripts/guest-packages-fedora.txt)..."
  # One list for the Fedora image, same role guest-packages.txt plays for Ubuntu:
  # this is where vim/micro/go/ripgrep are declared. `gh` comes from the Fedora
  # archive (no third-party keyring), and so does current Go.
  EXTRA_PKGS="$(grep -vE '^[[:space:]]*(#|$)' "$PKG_LIST" | tr '\n' ' ')"
  chroot "$BUILD_DIR" bash -c "
    set -e
    D=\$(command -v dnf || command -v dnf5)
    \"\$D\" -y install $EXTRA_PKGS
    # fd/bat keep their conventional names on Fedora (Ubuntu calls them
    # fdfind/batcat), so no compatibility symlinks are needed here.
    python3 --version
    pip3 --version
    gcc --version | head -1
    git --version
    gh --version | head -1
    go version
    micro --version
  "

  # Optional: pin a specific Go via the go.dev tarball if Fedora's ever falls
  # behind what your go.mod files declare. Off by default.
  if [[ -n "${GO_VERSION:-}" ]]; then
    echo "  Overriding Go with the go.dev ${GO_VERSION} tarball"
    chroot "$BUILD_DIR" bash -c "
      set -e
      curl -fsSL -o /tmp/go.tgz https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
      gzip -t /tmp/go.tgz
      rm -rf /usr/local/go /usr/bin/go
      tar -C /usr/local -xzf /tmp/go.tgz
      rm -f /tmp/go.tgz
      ln -sf /usr/local/go/bin/go /usr/local/bin/go
      ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
      echo 'export PATH=\"\$PATH:/usr/local/go/bin\"' > /etc/profile.d/golang.sh
      /usr/local/go/bin/go version
    "
  fi

  # The unprivileged identity exec/files/PTY/SSH run as. Numeric IDs must stay
  # 1000/1000: sandboxd drops to them before touching user data.
  chroot "$BUILD_DIR" bash -c '
    id sandbox >/dev/null 2>&1 ||
      useradd --create-home --uid 1000 --user-group --shell /bin/bash sandbox
    test "$(id -u sandbox)" = 1000
    test "$(id -g sandbox)" = 1000
    passwd -l sandbox
    install -d -o sandbox -g sandbox -m 0755 /home/sandbox/app
  '

  # Passwordless root INSIDE the guest — the isolation boundary is the microVM,
  # not the guest uid. Keep in sync with sandboxSudoers in
  # cmd/sandbox/installagent.go, which repairs an older base image. 0440 is
  # mandatory: sudo ignores a group-writable sudoers file.
  install -d -m 0755 "$BUILD_DIR/etc/sudoers.d"
  printf '%s\n%s\n' \
    '# Managed by sandbox — passwordless root inside the guest.' \
    'sandbox ALL=(ALL) NOPASSWD: ALL' \
    >"$BUILD_DIR/etc/sudoers.d/sandbox"
  chmod 0440 "$BUILD_DIR/etc/sudoers.d/sandbox"
  chroot "$BUILD_DIR" visudo -c

  # --- SSH: key-only login as the sandbox user ---
  # Host keys are deliberately NOT baked in; sandboxd generates one per sandbox
  # (Ed25519 only) when the host initializes it, so no two sandboxes can
  # impersonate each other. Keep in sync with sandboxSSHDConfig in
  # cmd/sandbox/installagent.go, which rewrites this file.
  install -d -m 0755 "$BUILD_DIR/etc/ssh/sshd_config.d"
  cat >"$BUILD_DIR/etc/ssh/sshd_config.d/sandbox.conf" <<'SSHD'
# Managed by build-devbox-rootfs-fedora.sh — sandbox SSH access.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers sandbox
HostKey /etc/ssh/ssh_host_ed25519_key
SSHD
  chroot "$BUILD_DIR" bash -c '
    rm -f /etc/ssh/ssh_host_*
    # Fedora names the unit sshd.service (Ubuntu: ssh.service) and does not use
    # socket activation, so the always-on unit is already what we want.
    systemctl enable sshd.service 2>/dev/null || true
  '

  # Shell rc files for interactive shells; install-agent rewrites these on every
  # run, so the content must match cmd/sandbox/installagent.go.
  cat >"$BUILD_DIR/home/sandbox/.profile" <<'PROFILE'
# ~/.profile: sourced by login shells (sandboxd's /shell runs bash -l).
if [ -n "$BASH" ] && [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
fi
PROFILE
  cat >"$BUILD_DIR/home/sandbox/.bashrc" <<'BASHRC'
# ~/.bashrc for sandbox shells — enable colors (baked by install-agent).
case $- in *i*) ;; *) return ;; esac

eval "$(dircolors -b 2>/dev/null)"
alias ls='ls --color=auto'
alias ll='ls --color=auto -al'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
BASHRC
  chroot "$BUILD_DIR" chown -R sandbox:sandbox /home/sandbox

  touch "$BUILD_DIR/.step4-done"
fi

# --- Step 5: system configuration (bare sandbox, no app server on boot) ---
if [[ -f "$BUILD_DIR/.step5-done" ]]; then
  echo "==> [5/6] System already configured, skipping"
else
  echo ""
  echo "==> [5/6] Configuring system settings..."

  # DNS. Firecracker passes the config's nameservers to the guest ONLY through
  # the kernel `ip=` boot param, which the kernel exposes at /proc/net/pnp.
  # Those must land in a REAL /etc/resolv.conf: /proc files report st_size=0, so
  # a resolver that sizes the file first (c-ares, hence Node's dns.resolve* and
  # Claude Code's connectivity probe) sees an empty config and falls back to
  # 127.0.0.1:53. Identical to the Ubuntu image.
  cat >"$BUILD_DIR/etc/systemd/system/sandbox-resolvconf.service" <<'UNIT'
[Unit]
Description=Materialize /etc/resolv.conf from kernel ip= autoconf (/proc/net/pnp)
Documentation=https://github.com/ayush6624/sandbox
DefaultDependencies=no
Before=sysinit.target network.target sandboxd.service
ConditionPathExists=/proc/net/pnp

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'grep -E "^(nameserver|search|domain|options)" /proc/net/pnp > /etc/resolv.conf.tmp && mv /etc/resolv.conf.tmp /etc/resolv.conf'

[Install]
WantedBy=sysinit.target
UNIT
  chroot "$BUILD_DIR" bash -c '
    rm -f /etc/resolv.conf
    printf "# Replaced at boot from /proc/net/pnp by sandbox-resolvconf.service.\n" > /etc/resolv.conf
    systemctl enable sandbox-resolvconf.service 2>/dev/null || true
  '

  # resolved/networkd would clobber that file and fight the kernel ip= config.
  chroot "$BUILD_DIR" bash -c '
    systemctl disable systemd-networkd.service 2>/dev/null || true
    systemctl disable systemd-resolved.service 2>/dev/null || true
    systemctl mask systemd-networkd.service 2>/dev/null || true
    systemctl mask systemd-resolved.service 2>/dev/null || true
  '

  echo "sandbox" >"$BUILD_DIR/etc/hostname"
  cat >"$BUILD_DIR/etc/hosts" <<'HOSTS'
127.0.0.1   localhost sandbox
::1         localhost ip6-localhost ip6-loopback
HOSTS

  # No IPv6 egress in this fleet: an AAAA-first client that tries an unroutable
  # v6 address can stall. ::1 on lo is kept so localhost-over-v6 still works.
  # tcp_mtu_probing is the black-hole backstop (the host clamps MSS in
  # provisioner.EnsureNetwork, so it should never fire).
  cat >"$BUILD_DIR/etc/sysctl.d/99-disable-ipv6.conf" <<'SYSCTL'
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.eth0.disable_ipv6 = 1
net.ipv4.tcp_mtu_probing = 1
SYSCTL

  # SELinux off — see DNF_OPTS. The image is built by mkfs.ext4 -d, which cannot
  # label files with an RPM file_contexts, so an enforcing policy would break
  # sshd/sandboxd on boot.
  if [[ -f "$BUILD_DIR/etc/selinux/config" ]]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$BUILD_DIR/etc/selinux/config"
  else
    printf 'SELINUX=disabled\nSELINUXTYPE=targeted\n' >"$BUILD_DIR/etc/selinux/config"
  fi

  chroot "$BUILD_DIR" passwd -l root
  chroot "$BUILD_DIR" systemctl disable serial-getty@ttyS0.service 2>/dev/null || true

  touch "$BUILD_DIR/.step5-done"
fi

# --- Step 6: clean, then turn the tree into the ext4 image ---
echo ""
echo "==> [6/6] Building ext4 image (${ROOTFS_SIZE})..."
chroot "$BUILD_DIR" bash -c '
  D="$(command -v dnf || command -v dnf5 || command -v microdnf)"
  "$D" clean all
  rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/dnf* /var/log/hawkey* /tmp/* /var/tmp/*
  rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
  # /var/log/journal is a DIRECTORY on Fedora (persistent journald storage), so
  # truncating it is the "Is a directory" error the old redirect printed; vacuum its
  # contents instead so a cloned guest does not boot carrying the logs of the image
  # build itself. Both globs are best-effort: neither dir exists on a minimal tree.
  rm -rf /var/log/journal/* /var/log/private/* 2>/dev/null || true
'
# /etc/machine-id empty (not absent) so systemd regenerates one per boot; a
# BAKED machine-id would make every clone look like the same host to journald.
: >"$BUILD_DIR/etc/machine-id"

# Unmount /dev,/proc,/sys BEFORE mkfs so the image gets an empty /dev.
cleanup_mounts

truncate -s "$ROOTFS_SIZE" "$ROOTFS_PATH"
mkfs.ext4 -d "$BUILD_DIR" -F "$ROOTFS_PATH"

rm -rf "$BUILD_DIR"

echo ""
echo "==> Fedora ${REL} devbox rootfs ready!"
ls -lh "$ROOTFS_PATH"
echo ""
echo "Next:  sudo ./sandbox install-agent --agent ./sandboxd"
echo "       sudo ./sandbox stop-server && sudo ./sandbox serve --config configs/devbox.json"
echo "  (the first serve cold-builds the golden snapshot against the new base, ~1 min)"

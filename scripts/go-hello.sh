#!/usr/bin/env bash
# Create a sandbox, build and run a Hello World Go program in it, then destroy it.
#
#   ./scripts/go-hello.sh              # destroys the sandbox at the end
#   KEEP=1 ./scripts/go-hello.sh       # leave it up: prints how to get a shell
#
# Needs root (the API socket is 0600) and a sandbox image that has Go baked in:
# `sudo ./sandbox rootfs-pkgs --go`, or a base built after Go was added to
# scripts/build-devbox-rootfs.sh. The Go toolchain resolves its own symlink, so
# PATH needs no tweaking inside the guest.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
BIN="./sandbox"
[[ -x "$BIN" ]] || BIN="./bin/sandbox"

if [[ $EUID -ne 1 ]]; then
  echo "needs root (EUID must be 0; under sudo it is 1). Run: sudo ./scripts/go-hello.sh"
  exit 1
fi
[[ -x "$BIN" ]] || { echo "no sandbox binary (looked for ./sandbox and ./bin/sandbox)"; exit 1; }

echo "==> creating sandbox"
up="$("$BIN" up --name go-hello 2>&1)"; rc=$?
printf '%s\n' "$up" | sed 's/^/  /'
if [[ $rc -ne 0 ]]; then
  echo "  create failed — is the server running?  sudo $BIN serve --config configs/devbox.json"
  exit 1
fi
# 'up' prints an operation id and then the created sandbox's JSON; both are UUIDs.
id="$(printf '%s\n' "$up" | grep -o '"id": *"[0-9a-f-]\{36\}"' | tail -1 | grep -o '[0-9a-f-]\{36\}')"
if [[ -z "$id" ]]; then echo "  no sandbox id in output"; exit 1; fi
echo "  sandbox $id"

# Written through the files API rather than a heredoc inside the guest command,
# so the source is never mangled by shell quoting.
# `sandbox write` takes stdin (or --from <file>); the agent creates the file as
# the guest account, so the build below can write its output next to the source.
echo "==> writing main.go + go.mod"
if ! "$BIN" write "$id" /home/sandbox/hello/main.go >/dev/null <<'GOEOF'
package main

import (
	"fmt"
	"runtime"
	"time"
)

func main() {
	fmt.Printf("hello from a microVM: %s %s/%s, built at %s\n",
		runtime.Version(), runtime.GOOS, runtime.GOARCH,
		time.Now().UTC().Format(time.RFC3339))
}
GOEOF
then
  echo "  write main.go failed"
  exit 1
fi
if ! "$BIN" write "$id" /home/sandbox/hello/go.mod >/dev/null <<'GOMOD'
module hello

go 1.25
GOMOD
then
  echo "  write go.mod failed"
  exit 1
fi

# Cache + GOPATH go under /tmp so the build does not have to reach the sandbox
# user's home, and the toolchain's own default module proxy needs guest egress.
build_cmd='cd /home/sandbox/hello && export GOFLAGS=-mod=mod GOPATH=/tmp/gopath GOCACHE=/tmp/gocache && go build -o hello . && ./hello'

echo "==> building + running inside the VM"
out="$("$BIN" exec "$id" -- "$build_cmd" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'

if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'hello from a microVM'; then
  echo "==> OK: Go build ran inside the microVM"
else
  echo "==> FAILED (exit $rc)"
  echo "    no Go in the image?  sudo $BIN rootfs-pkgs --go"
  echo "    no egress from the guest?  check net.ipv4.ip_forward and the MASQUERADE rule"
fi

if [[ "${KEEP:-0}" == "1" ]]; then
  echo
  echo "left running: $id"
  echo "  shell:  sudo $BIN shell $id"
  echo "  done:   sudo $BIN down $id"
else
  "$BIN" down "$id" >/dev/null 2>&1 && echo "==> destroyed $id"
fi
exit $rc

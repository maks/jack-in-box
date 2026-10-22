#!/usr/bin/env bash
# End-to-end smoke test for a devbox sandbox on this host.
#
# It exercises the things most likely to be broken on a box that was just set up
# from another distro: guest egress through host NAT, the toolchain that is
# baked into the base image (Node, Python, Go, micro), the files API, and
# hibernate -> wake with the rootfs intact.
#
#   sudo bash scripts/smoke-devbox.sh          # destroys the sandbox at the end
#   KEEP=1 sudo bash scripts/smoke-devbox.sh   # leave it up for poking around
#
# Run it as root: the API socket is mode 0600.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# On the deployed box the binary is ./sandbox; in a dev checkout it is bin/sandbox.
BIN="./sandbox"
[[ -x "$BIN" ]] || BIN="./bin/sandbox"
SOCK="/run/sandbox.sock"
NAME="${NAME:-smoke-$(date +%H%M%S)}"

PASS=0
FAIL=0
CREATED_ID=""

hr() { printf '%s\n' "----------------------------------------------------------------------"; }
step() { printf '\n==> %s\n' "$1"; }
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# run <id> <cmd...> -> guest command, host-visible output, caller handles status
run() {
  local id="$1"; shift
  "$BIN" exec "$id" -- "$*" 2>&1
}

cleanup() {
  if [[ -n "$CREATED_ID" && "${KEEP:-0}" != "1" ]]; then
    step "cleanup"
    "$BIN" down "$CREATED_ID" >/dev/null 2>&1 \
      && echo "  destroyed $CREATED_ID" \
      || echo "  could not destroy $CREATED_ID (remove it manually)"
  elif [[ -n "$CREATED_ID" ]]; then
    echo
    echo "  left running (KEEP=1): $CREATED_ID"
    echo "  shell:  sudo $BIN shell $CREATED_ID"
    echo "  done:   sudo $BIN down $CREATED_ID"
  fi
}
trap cleanup EXIT

hr
echo "devbox smoke test"
echo "  binary : $BIN"
echo "  cwd    : $PWD"
echo "  socket : $SOCK"
echo "  name   : $NAME"
hr

step "preflight"
# The API socket is 0600 and root-owned, so a non-root run fails on every step --
# unless the CLI is pointed at the TCP listener, which the CLI takes from
# SANDBOX_API_URL / SANDBOX_API_KEY without any privilege.
if [[ -z "${SANDBOX_API_URL:-}" ]] && [[ $EUID -ne 0 ]]; then
  echo "  needs root for the Unix socket. Run: sudo bash scripts/smoke-devbox.sh"
  echo "  or unprivileged against a listener:"
  echo "    SANDBOX_API_URL=http://127.0.0.1:<port> SANDBOX_API_KEY=<tok> bash scripts/smoke-devbox.sh"
  exit 1
fi
[[ -x "$BIN" ]] || { echo "  no sandbox binary (looked for ./sandbox and ./bin/sandbox) — run 'make build-linux'"; exit 1; }
if [[ -z "${SANDBOX_API_URL:-}" ]]; then
  [[ -S "$SOCK" ]] || { echo "  $SOCK not found - start the server first:"; echo "    sudo $BIN serve --config configs/devbox.json"; exit 1; }
fi
ok "binary and API socket present"

step "create sandbox"
up_out="$("$BIN" up --name "$NAME" 2>&1)"; up_rc=$?
printf '%s\n' "$up_out" | sed 's/^/  /'
if [[ $up_rc -ne 0 ]]; then
  echo
  echo "  'up' failed. Most common causes:"
  echo "    - base rootfs has no agent baked in -> sudo $BIN install-agent --agent ./sandboxd"
  echo "    - no free slots / guest subnet exhausted -> sudo $BIN list"
  echo "    - KVM unavailable -> sudo $BIN doctor --config configs/devbox.json"
  exit 1
fi
# 'up' prints an operation id and the created sandbox's JSON; both are UUIDs.
ID=$(printf '%s\n' "$up_out" | grep -o '"id": *"[0-9a-f-]\{36\}"' | tail -1 | grep -o '[0-9a-f-]\{36\}')
if [[ -z "$ID" ]]; then
  echo "  could not read a sandbox id from the output above"; exit 1
fi
CREATED_ID="$ID"
ok "created $ID"

step "guest identity + resources"
ident="$(run "$ID" 'echo user=$(id -un) host=$(uname -r) cores=$(nproc) mem=$(awk "/MemTotal/{print int(\$2/1024)}MiB" /proc/meminfo)')"
printf '  %s\n' "$ident"
case "$ident" in *"user=sandbox"*) ok "runs as the sandbox user" ;; *) bad "unexpected user: $ident" ;; esac

step "guest internet (via host NAT)"
net="$(run "$ID" 'curl -fsS --max-time 25 -o /dev/null -w "http=%{http_code} time=%{time_total}s" https://archive.ubuntu.com/ 2>&1 || echo FAILED')"
printf '  %s\n' "$net"
case "$net" in *"http=2"*) ok "guest reaches the internet" ;; *)
  bad "guest egress failed"
  echo "     check the host: sysctl net.ipv4.ip_forward (=1) and"
  echo "     iptables -t nat -S POSTROUTING | grep MASQUERADE   (both are set by serve on startup)"
  ;;
esac

step "toolchain in the base image"
for check in "node --version" "python3 --version" "go version" "micro --version" "git --version"; do
  out="$(run "$ID" "$check")"; crc=$?
  if [[ $crc -eq 0 ]]; then
    ok "$check -> $(printf '%s' "$out" | tail -1)"
  else
    bad "$check -> ${out:-no output}"
  fi
done

step "go build inside the VM"
# Written as one argument each, so $(...) stays literal here and runs in-guest.
# `write` takes stdin (or --from); files land owned by the guest account, so the
# build below can write next to them.
if ! "$BIN" write "$ID" /home/sandbox/gosmoke/main.go >/dev/null <<'GOEOF'
package main

import (
	"fmt"
	"runtime"
	"time"
)

func main() {
	fmt.Printf("hello from a microVM: %s %s/%s at %s\n",
		runtime.Version(), runtime.GOOS, runtime.GOARCH, time.Now().UTC().Format(time.RFC3339))
}
GOEOF
then
  bad "writing main.go into the guest failed"
fi
if ! "$BIN" write "$ID" /home/sandbox/gosmoke/go.mod >/dev/null <<'GOMOD'
module gosmoke

go 1.25
GOMOD
then
  bad "writing go.mod into the guest failed"
fi

build="$(run "$ID" 'cd /home/sandbox/gosmoke && export GOFLAGS=-mod=mod GOPATH=/tmp/gopath GOCACHE=/tmp/gocache && go build -o hello . && echo BUILD_OK')"; brc=$?
printf '  %s\n' "$build"
if printf '%s' "$build" | grep -q BUILD_OK; then ok "go build produced a binary"; else bad "go build failed"; fi

step "run the built binary"
res="$(run "$ID" 'cd /home/sandbox/gosmoke && ./hello')"
printf '  %s\n' "$res"
printf '%s' "$res" | grep -q "hello from a microVM" && ok "binary ran" || bad "binary did not run"

step "guest clock is stepped (snapshot resume)"
clk="$(run "$ID" 'date -u +%s')"
# exec merges stderr, and a guest warning would otherwise fail a strict match.
clk="$(printf '%s' "$clk" | grep -oE '[0-9]{9,}' | tail -1)"
host_now=$(date +%s)
if [[ -n "$clk" ]]; then
  drift=$(( host_now - clk )); [[ $drift -lt 0 ]] && drift=$(( -drift ))
  if (( drift < 120 )); then ok "guest clock within ${drift}s of host"; else bad "guest clock off by ${drift}s"; fi
else
  bad "could not read guest clock: $clk"
fi

step "host-side metrics"
mets="$("$BIN" metrics "$ID" 2>&1)"; mrc=$?
printf '%s\n' "$mets" | head -8 | sed 's/^/  /'
[[ $mrc -eq 0 ]] && ok "metrics readable" || bad "metrics failed: $(printf '%s' "$mets" | head -1)"

step "hibernate, then wake by running the binary again"
"$BIN" hibernate "$ID" >/dev/null 2>&1 && ok "hibernated" || bad "hibernate request failed"
res2="$(run "$ID" 'cd /home/sandbox/gosmoke && ./hello')"
printf '  %s\n' "$res2"
printf '%s' "$res2" | grep -q "hello from a microVM" \
  && ok "wake-on-access restored the sandbox with its files" \
  || bad "post-wake run failed (rootfs or wake broken)"

step "ssh into the sandbox as the sandbox user"
# The Ed25519 host key is generated lazily on first SSH use, so this is what
# creates it — do not treat a pre-ssh absence as a failure.
if ! command -v ssh >/dev/null 2>&1; then
  echo "  skipped: no ssh client on this host"
else
  ssh_out=$(mktemp); ssh_err=$(mktemp)
  if "$BIN" ssh "$ID" -- 'echo SSH_USER=$(id -un) PWD=$PWD' >"$ssh_out" 2>"$ssh_err"; then
    printf '  %s\n' "$(tail -3 "$ssh_out")"
    if grep -q 'SSH_USER=sandbox' "$ssh_out"; then
      ok "ssh ran a command as the sandbox user"
    else
      bad "ssh connected but not as sandbox: $(tail -1 "$ssh_out")"
    fi
  else
    bad "sandbox ssh failed: $(tail -1 "$ssh_err")"
  fi
  rm -f "$ssh_out" "$ssh_err"
fi
h1="$(run "$ID" 'cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null')"
printf '%s\n' "$h1" | grep 'ssh-ed25519' | cut -c1-70 | sed 's/^/  /'
if printf '%s' "$h1" | grep -q 'ssh-ed25519 '; then
  ok "unique Ed25519 host key in place"
else
  bad "no Ed25519 host key (agent too old? re-run install-agent / rebake the image)"
fi

hr
printf 'summary: %d passed, %d failed  (sandbox %s)\n' "$PASS" "$FAIL" "$ID"
hr
[[ $FAIL -eq 0 ]] || exit 1

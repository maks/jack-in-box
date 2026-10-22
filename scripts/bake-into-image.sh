#!/usr/bin/env bash
# Copy a host directory into the BASE guest rootfs at a chosen path.
#
# Software belongs in the base image (a sandbox's own files die with it), and the
# same is true of the configuration a tool needs at first run: pi's provider list,
# git identity, ssh config, dotfiles. Doing it inside a sandbox is never the fix --
# the next create is a fresh copy of the base again.
#
# This is the primitive for the cases rootfs-pkgs does not cover (it installs
# distro packages; it has no notion of "put these files at this path, owned by the
# sandbox user"). It takes no dependencies on the repo being checked out at the
# destination.
#
#   sudo scripts/bake-into-image.sh ./pi-guest /home/sandbox/.pi/agent
#   sudo scripts/bake-into-image.sh ./dotfiles /home/sandbox 1000:1000
#
# What it costs: writing the base image bumps its mtime, which is what goldenUsable
# keys on, so the next `sandbox serve` discards the golden snapshot and cold-boots
# a replacement (~1 min). Any EXISTING sandbox keeps its own copy of the old base --
# including a hibernated one, whose memory diff is anchored to it -- so the change
# only reaches sandboxes created afterwards.
set -euo pipefail

# Modes in the image must not inherit the caller's umask: a restrictive one ships
# files the guest's non-root user cannot read (this exact failure produced a
# root-only npm global tree, which made `pi` look uninstalled). Pinned here, and
# the destination tree is normalized below rather than trusted from the source.
umask 022

BASE="${ROOTFS_PATH:-/opt/fc/devbox-rootfs.ext4}"
SRCDIR="${1:-}"
DEST="${2:-}"
OWNER="${3:-1000:1000}" # 1000 is the `sandbox` user in the devbox images

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (loop-mounts $BASE)" >&2
  exit 1
fi
if [[ -z "$SRCDIR" || -z "$DEST" ]]; then
  echo "usage: $0 <src-dir> <guest-absolute-path> [uid:gid]" >&2
  exit 1
fi
if [[ ! -d "$SRCDIR" ]]; then
  echo "source directory not found: $SRCDIR" >&2
  exit 1
fi
if [[ ! -f "$BASE" ]]; then
  echo "base image not found: $BASE (set ROOTFS_PATH)" >&2
  exit 1
fi
if [[ "$DEST" != /* ]]; then
  echo "destination must be an absolute guest path, got: $DEST" >&2
  exit 1
fi
# The server holds clones of this image and re-reads it for every golden load; a
# live golden also pins the OLD content, so a bake it never sees is a silent no-op.
if pgrep -f 'sandbox serve' >/dev/null 2>&1; then
  echo "a 'sandbox serve' is running; stop it first (sudo sandbox stop-server)" >&2
  exit 1
fi

MNT="$(mktemp -d "${TMPDIR:-/tmp}/bake-img.XXXXXX")"
cleanup() {
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop "$BASE" "$MNT"

target="$MNT/${DEST#/}"
mkdir -p "$target"

# tar rather than cp -a so a symlink or special file in the source is copied as
# itself instead of following out of the tree and into the host filesystem.
tar -C "$SRCDIR" -cf - . | tar -C "$target" -xf -

chown -R "$OWNER" "$target"
find "$target" -type d -exec chmod 0755 {} +
find "$target" -type f ! -perm -u+x -exec chmod 0644 {} +
find "$target" -type f -perm -u+x -exec chmod 0755 {} +

echo "baked $(find "$target" -type f | wc -l) file(s) into ${DEST} (owner ${OWNER}):"
find "$target" -maxdepth 2 -printf '  %M %u:%g %P\n' 2>/dev/null | head -20 ||
  ls -lR "$target" | head -20

cat <<NOTE

Next: the base image changed, so restart the server and let it rebuild the golden.

  sudo ./sandbox serve --config configs/devbox.json \\
    --listen 127.0.0.1:8080 --token-file ~/.sandbox-token --management-transport private_proxy

Wait for "golden snapshot ... built in ...; creates are hot", then DEST only
applies to NEW sandboxes -- destroy or ignore any created before this bake.
NOTE

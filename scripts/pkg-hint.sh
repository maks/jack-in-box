# shellcheck shell=bash
# Sourced helper — no side effects. Prints an install command for the HOST distro.
#
# Every host-side dependency hint in this repo used to hardcode `apt-get`, which
# is wrong on a Fedora/RHEL/Arch host — and those hosts are fully supported: the
# GUEST image is Ubuntu either way, because every apt-get that actually installs
# something into it runs inside `chroot "$BUILD_DIR"`, not on the host.
#
#   echo "ERROR: 'zstd' is missing (try: sudo $(pkg_install_hint zstd))" >&2
#
# Package NAMES can still differ per distro (gnupg2 vs gnupg, zstd vs libzstd);
# the helper only spells the package MANAGER correctly.
#
# Kept bash-3.2 clean (no ${var,,}, no arrays) for the same reason as the infra
# wrappers: a developer box may well be a Mac, even though the scripts that
# source this one only run on Linux.
pkg_install_hint() {
  local ids=""
  if [ -r /etc/os-release ]; then
    # Subshell so ID/ID_LIKE never leak into the caller's environment.
    ids="$(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    ids="$(printf '%s' "$ids" | tr '[:upper:]' '[:lower:]')"
  fi
  case " $ids " in
    *debian* | *ubuntu* | *linuxmint*) echo "apt-get install -y $*" ;;
    *fedora* | *rhel* | *centos*) echo "dnf install -y $*" ;;
    *suse* | *sles*) echo "zypper --non-interactive install $*" ;;
    *arch* | *manjaro*) echo "pacman -S --noconfirm $*" ;;
    *alpine*) echo "apk add --no-cache $*" ;;
    *) echo "<your distro's package manager> $*" ;;
  esac
}

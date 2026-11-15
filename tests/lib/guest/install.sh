#!/usr/bin/env bash
# Runs INSIDE the guest (container or VM). Installs one package and prints the
# command line that launches it on stdout. Install output goes to stderr.
#
# usage: install.sh <deb|rpm|appimage|tar.xz|unpacked|flatpak|snap|nix|installed> <path>
# env:   SUDO         prefix for privileged commands (VMs: "sudo"; containers: empty)
#        APPIMAGE_EXTRACT=1  run the AppImage without FUSE (--appimage-extract-and-run)
set -euo pipefail
TYPE=$1 PKG=${2:-}
SUDO=${SUDO:-}

find_bin() {
	command -v deezer-desktop 2>/dev/null && return
	ls /opt/*/deezer-desktop 2>/dev/null | head -1
}

case $TYPE in
deb)
	$SUDO apt-get update -q >&2
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$PKG" >&2
	echo "$(find_bin)"
	;;
rpm)
	if command -v dnf >/dev/null; then
		$SUDO dnf install -y -q "$PKG" >&2
	else
		$SUDO zypper --non-interactive --no-gpg-checks install --allow-unsigned-rpm "$PKG" >&2
	fi
	echo "$(find_bin)"
	;;
appimage)
	$SUDO install -m 755 "$PKG" /opt/deezer-desktop.AppImage
	if [ "${APPIMAGE_EXTRACT:-0}" = 1 ]; then
		echo "/opt/deezer-desktop.AppImage --appimage-extract-and-run --no-sandbox"
	else
		echo "/opt/deezer-desktop.AppImage --no-sandbox"
	fi
	;;
tar.xz)
	$SUDO mkdir -p /opt/deezer-desktop
	$SUDO tar -xJf "$PKG" -C /opt/deezer-desktop --strip-components=1
	echo "/opt/deezer-desktop/deezer-desktop --no-sandbox"
	;;
unpacked)
	echo "$PKG/deezer-desktop --no-sandbox"
	;;
flatpak)
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >&2
	flatpak install --user -y --noninteractive "$PKG" >&2
	echo "flatpak run dev.aunetx.deezer"
	;;
snap)
	$SUDO snap install --dangerous "$PKG" >&2
	echo "snap run deezer-desktop"
	;;
nix)
	# $PKG is a checkout containing default.nix and artifacts/<arch>/linux*-unpacked
	ARCH=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo x64)
	nix-build "$PKG/default.nix" -A deezer-desktop --argstr arch "$ARCH" --out-link /tmp/deezer-nix >&2
	echo "/tmp/deezer-nix/bin/deezer-desktop --no-sandbox"
	;;
installed)
	if B=$(find_bin) && [ -n "$B" ]; then
		echo "$B"
	elif flatpak info dev.aunetx.deezer >/dev/null 2>&1; then
		echo "flatpak run dev.aunetx.deezer"
	elif snap list deezer-desktop >/dev/null 2>&1; then
		echo "snap run deezer-desktop"
	else
		echo "no installed deezer-desktop found (PATH, /opt, flatpak, snap)" >&2
		exit 1
	fi
	;;
*)
	echo "unknown package type: $TYPE" >&2
	exit 2
	;;
esac

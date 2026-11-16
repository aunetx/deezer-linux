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

# Installs a desktop file the way users integrate portable formats (README "AppImage"):
# same file name, Exec pointing at the app, its icon in hicolor.
integrate() { # $1 = desktop file, $2 = Exec command, $3 = icon file (optional)
	local apps=/usr/local/share/applications icon
	$SUDO mkdir -p "$apps"
	sed -e "s|^Exec=.*|Exec=$2 %U|" -e '/^TryExec=/d' "$1" | $SUDO tee "$apps/$(basename "$1")" >/dev/null
	if [ -n "${3:-}" ]; then
		icon=$(sed -n 's/^Icon=//p' "$1")
		$SUDO install -D -m 644 "$3" "/usr/local/share/icons/hicolor/scalable/apps/$icon.${3##*.}"
	fi
	if command -v update-desktop-database >/dev/null; then $SUDO update-desktop-database "$apps" >&2 || true; fi
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
	# The embedded desktop file and icon, as AppImage integration tools and the README do.
	x=$(mktemp -d) && (cd "$x" && /opt/deezer-desktop.AppImage --appimage-extract '*.desktop' >/dev/null &&
		/opt/deezer-desktop.AppImage --appimage-extract 'usr/share/icons/hicolor/256x256/apps/*' >/dev/null)
	integrate "$(ls "$x"/squashfs-root/*.desktop)" /opt/deezer-desktop.AppImage \
		"$(ls "$x"/squashfs-root/usr/share/icons/hicolor/256x256/apps/*.png | head -1)"
	rm -rf "$x"
	if [ "${APPIMAGE_EXTRACT:-0}" = 1 ]; then
		echo "/opt/deezer-desktop.AppImage --appimage-extract-and-run --no-sandbox"
	else
		echo "/opt/deezer-desktop.AppImage --no-sandbox"
	fi
	;;
tar.xz)
	$SUDO mkdir -p /opt/deezer-desktop
	$SUDO tar -xJf "$PKG" -C /opt/deezer-desktop --strip-components=1
	# The desktop file and icon the archive ships for Flathub and Nix, as they install them.
	integrate /opt/deezer-desktop/resources/dev.aunetx.deezer.desktop /opt/deezer-desktop/deezer-desktop \
		/opt/deezer-desktop/resources/dev.aunetx.deezer.svg
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
	# A Nix profile puts the package's share/ in XDG_DATA_DIRS: link its desktop file and icon likewise.
	for f in applications/dev.aunetx.deezer.desktop icons/hicolor/scalable/apps/dev.aunetx.deezer.svg; do
		$SUDO install -d "/usr/local/share/$(dirname "$f")"
		$SUDO ln -sf "/tmp/deezer-nix/share/$f" "/usr/local/share/$f"
	done
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

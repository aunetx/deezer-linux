# shellcheck shell=bash
# shellcheck disable=SC2034 # variables are used by the sourcing script
# Shared helpers for the host-side runners. Sourced by tests/run.sh.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
GUEST_DIR=$TESTS_DIR/lib/guest
CACHE_DIR=${DEEZER_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/deezer-linux-tests}

if [ -t 2 ]; then C_B=$'\e[1m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_0=$'\e[0m'; else C_B='' C_R='' C_G='' C_Y='' C_0=''; fi
log() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { for t in "$@"; do have "$t" || die "'$t' is required (see tests/README.md#host-requirements)"; done; }

host_arch() { case $(uname -m) in aarch64 | arm64) echo arm64 ;; *) echo x64 ;; esac; }

# ------------------------------------------------------------- distros ---
# distro -> "family base-image native-package"
distro_info() {
	case $1 in
	ubuntu-24.04) echo "debian ubuntu:24.04 deb" ;;
	ubuntu-26.04) echo "debian ubuntu:26.04 deb" ;;
	debian-12) echo "debian debian:12 deb" ;;
	debian-13) echo "debian debian:13 deb" ;;
	fedora) echo "fedora fedora:latest rpm" ;;
	opensuse) echo "opensuse opensuse/tumbleweed rpm" ;;
	arch) echo "arch archlinux:latest tar.xz" ;;
	nix) echo "nix nixos/nix:latest nix" ;;
	*) return 1 ;;
	esac
}
DISTROS="ubuntu-24.04 ubuntu-26.04 debian-12 debian-13 fedora opensuse arch nix"
PKG_TYPES="deb rpm appimage tar.xz unpacked flatpak snap nix installed"

# ----------------------------------------------------------- artifacts ---
# Finds the newest package of a type for an arch in artifacts/<arch>/.
find_artifact() { # $1 = type, $2 = arch
	local dir=$REPO_DIR/artifacts/$2 deb=amd64 rpm=x86_64 ai=x86_64 fp=x86_64 unp=linux-unpacked
	[ "$2" = arm64 ] && { deb=arm64 rpm=aarch64 ai=arm64 fp=aarch64 unp=linux-arm64-unpacked; }
	local pattern
	case $1 in
	deb) pattern="*_${deb}.deb" ;;
	rpm) pattern="*.${rpm}.rpm" ;;
	appimage) pattern="*-${ai}.AppImage" ;;
	tar.xz) pattern="*-$2.tar.xz" ;;
	flatpak) pattern="*-${fp}.flatpak" ;;
	snap) pattern="*_${deb}.snap" ;;
	unpacked) [ -x "$dir/$unp/deezer-desktop" ] && echo "$dir/$unp"; return ;;
	nix) [ -d "$dir/$unp" ] && echo "$REPO_DIR"; return ;;
	installed) echo "-"; return ;;
	esac
	# shellcheck disable=SC2012
	ls -t "$dir"/$pattern 2>/dev/null | head -1
}

# ------------------------------------------------------------- session ---
# The single host-provided Deezer session (see tests/README.md#logged-in-tests).
session_file() {
	if [ -n "${DEEZER_SESSION_FILE:-}" ]; then
		echo "$DEEZER_SESSION_FILE"
	elif [ -f "$TESTS_DIR/session.env" ]; then
		echo "$TESTS_DIR/session.env"
	else
		echo "${XDG_CONFIG_HOME:-$HOME/.config}/deezer-linux-tests/session.env"
	fi
}

# Logged-in app profile saved after a successful login, reused by later runs so
# the account logs in once instead of on every run. Same secrecy as session.env.
session_cache_dir() {
	local d=$CACHE_DIR/session
	(umask 077 && mkdir -p "$d")
	chmod 700 "$d"
	echo "$d"
}

# Prints a readable session file path, or dies. CI can pass DEEZER_ARL instead.
resolve_session() {
	if [ -n "${DEEZER_ARL:-}" ]; then
		local tmp
		tmp=$(mktemp "${TMPDIR:-/tmp}/deezer-session.XXXXXX")
		chmod 600 "$tmp"
		printf 'DEEZER_ARL=%s\n' "$DEEZER_ARL" >"$tmp"
		echo "$tmp"
		return
	fi
	local f
	f=$(session_file)
	[ -r "$f" ] || die "no session file at $f (copy tests/session.env.example, or set DEEZER_ARL)"
	grep -qE '^[[:space:]]*DEEZER_ARL=.+' "$f" || die "$f has no DEEZER_ARL=..."
	[ "$(stat -c %a "$f")" = 600 ] || warn "$f is readable by others: chmod 600 $f"
	echo "$f"
}

session_arl() { grep -E '^[[:space:]]*DEEZER_ARL=' "$1" | tail -1 | cut -d= -f2- | tr -d "\"' \r"; }

# ------------------------------------------------------------- results ---
new_out_dir() { # $@ = name parts
	local IFS=-
	local d
	mkdir -p "${OUT_ROOT:-$TESTS_DIR/out}"
	d=$(mktemp -d "$(realpath "${OUT_ROOT:-$TESTS_DIR/out}")/$(date +%Y%m%d-%H%M%S)-$*-XXXX")
	echo "$d"
}

# Prints a one-line verdict for a finished run and returns its status.
verdict() { # $1 = out dir
	local env=$1/result.env r
	[ -f "$env" ] || { printf '%sFAIL%s %s (no result.env)\n' "$C_R" "$C_0" "$1"; return 1; }
	r=$(grep -m1 '^RESULT=' "$env" | cut -d= -f2)
	if [ "$r" = pass ]; then
		printf '%sPASS%s %s\n' "$C_G" "$C_0" "$1"
	else
		printf '%sFAIL%s %s: %s\n' "$C_R" "$C_0" "$1" "$(grep -m1 '^FAILURES=' "$env" | cut -d= -f2-)"
	fi
	grep -m1 '^WARNINGS=.' "$env" | cut -d= -f2- | tr ';' '\n' | sed "s/^/  ${C_Y}warn${C_0} /"
	[ "$r" = pass ]
}

# Last line of defence: refuse to leave the session secret in an output tree.
scrub_out() { # $1 = out dir, $2 = session file (optional)
	local arl=""
	[ -n "${2:-}" ] && arl=$(session_arl "$2")
	python3 -I "$GUEST_DIR/redact.py" "$1" "$arl"
	if [ -n "$arl" ] && grep -rqF -- "$arl" "$1"; then
		die "session secret still present under $1, delete it before sharing"
	fi
}

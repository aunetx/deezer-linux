#!/usr/bin/env bash
# Cross-environment launcher, smoke tester and reporter for deezer-linux.
# Docs: tests/README.md. Run `tests/run.sh help` for usage.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
	cat <<EOF
usage: tests/run.sh <command> [options]

Commands
  container   smoke test in a throwaway container (X11 / Wayland / Xwayland, headless)
  vm          smoke test in a throwaway QEMU VM with a real desktop session
  host        smoke test on this machine, in your current session (Raspberry Pi, NixOS...)
  matrix      run every line of a matrix file (default: tests/matrix.txt), then report
  report      summarise results under tests/out/ as Markdown (paste into an issue)
  unit        fast checks of the repo and of the test tooling (no package, no display)
  session     manage the shared Deezer session: check | path | import-firefox | forget
  fetch       download release packages into artifacts/<arch>/  [--version vX.Y.Z] [--arch x64|arm64|all]
  doctor      show which host tools are present for each tier
  list        list distros, VM profiles, sessions and package types

Options (container / vm / host)
  -d, --distro NAME     container distro (default: ubuntu-24.04), see 'list'
  -P, --profile NAME    VM profile (default: ubuntu-gnome), see 'list'
  -p, --pkg TYPE        package type (default: the distro's native one)
  -s, --session TYPE    x11 | wayland | xwayland   (default: x11; host: current session)
  -a, --arch ARCH       x64 | arm64 (default: this machine's)
  -f, --file PATH       package to test (default: newest match in artifacts/<arch>/)
      --args "FLAGS"    extra app flags, e.g. "--start-in-tray"
      --login           log in with the shared session (tests/session.env)
      --play            after login, start playback over MPRIS and check it
      --portal          start a fake portal.Settings (for --sync-theme)
      --close           close the window at the end: the app must hide to tray
                        (or quit, with --args --disable-systray)
      --wait N          seconds to wait for the window (default: 30)
      --keep            keep the app/display/VM running after the checks (debug)
      --shell           like --keep, and open a shell in the guest
      --vnc             serve the display on 127.0.0.1:5900 (container) / :5901+ (VM)
      --out DIR         output directory (default: tests/out/<timestamp>-...)
EOF
}

# ------------------------------------------------------------- options ---
DISTRO=ubuntu-24.04 PROFILE=ubuntu-gnome PKG="" SESSION="" ARCH=$(host_arch) FILE=""
APP_ARGS="" LOGIN=0 PLAY=0 PORTAL=0 CLOSE=0 WAIT=30 HOLD=0 VNC=0 OUT=""
parse_opts() {
	while [ $# -gt 0 ]; do
		case $1 in
		-d | --distro) DISTRO=$2; shift ;;
		-P | --profile) PROFILE=$2; shift ;;
		-p | --pkg) PKG=$2; shift ;;
		-s | --session) SESSION=$2; shift ;;
		-a | --arch) ARCH=$2; shift ;;
		-f | --file) FILE=$(realpath "$2"); shift ;;
		--args) APP_ARGS=$2; shift ;;
		--login) LOGIN=1 ;;
		--play) LOGIN=1 PLAY=1 ;;
		--portal) PORTAL=1 ;;
		--close) CLOSE=1 ;;
		--wait) WAIT=$2; shift ;;
		--keep) HOLD=1 ;;
		--shell) HOLD=shell ;;
		--vnc) VNC=1 ;;
		--out) OUT=$(realpath -m "$2"); mkdir -p "$OUT"; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
		esac
		shift
	done
	case $SESSION in "" | x11 | wayland | xwayland) ;; *) die "--session must be x11, wayland or xwayland" ;; esac
	case $ARCH in x64 | arm64) ;; *) die "--arch must be x64 or arm64" ;; esac
	[ -z "$PKG" ] || [[ " $PKG_TYPES " == *" $PKG "* ]] || die "unknown package type '$PKG' (one of: $PKG_TYPES)"
}

resolve_pkg_file() {
	[ -n "$FILE" ] && return
	FILE=$(find_artifact "$PKG" "$ARCH")
	[ -n "$FILE" ] || die "no $PKG package for $ARCH in artifacts/$ARCH/ (build one, run 'tests/run.sh fetch', or pass --file)"
}

SESSION_SRC=""
cleanup_session() { [ -n "$SESSION_SRC" ] && [[ $SESSION_SRC == "${TMPDIR:-/tmp}"/deezer-session.* ]] && rm -f "$SESSION_SRC"; return 0; }
trap cleanup_session EXIT

# ----------------------------------------------------------- container ---
cmd_container() {
	parse_opts "$@"
	local family base native engine image platform=()
	read -r family base native <<<"$(distro_info "$DISTRO")" || die "unknown distro '$DISTRO' (one of: $DISTROS)"
	PKG=${PKG:-$native}
	SESSION=${SESSION:-x11}
	case $PKG in flatpak | snap) die "$PKG needs systemd and a nested sandbox: use 'tests/run.sh vm -p $PKG'" ;; installed) die "'installed' only makes sense for 'host'" ;; esac
	case $PKG/$family in deb/debian | rpm/fedora | rpm/opensuse | nix/nix | appimage/* | tar.xz/* | unpacked/*) ;;
	*) die "$PKG packages cannot be installed on $DISTRO" ;; esac
	[ "$family" = nix ] && [ "$PKG" != nix ] && die "the nix distro only tests -p nix"
	resolve_pkg_file

	engine=${CONTAINER_ENGINE:-$(have docker && echo docker || echo podman)}
	need "$engine" python3
	image=deezer-linux-test:$DISTRO
	local rt=0
	case $PKG in appimage | tar.xz | unpacked) rt=1 image+=-rt ;; esac
	if [ "$ARCH" != "$(host_arch)" ]; then
		platform=(--platform "linux/${ARCH/x64/amd64}")
		image+=-$ARCH
		warn "emulating $ARCH with qemu-user: slow, and needs binfmt (qemu-user-binfmt) on the host"
	fi
	log "building $image"
	"$engine" build -q "${platform[@]}" -t "$image" -f "$TESTS_DIR/containers/$family.Dockerfile" \
		--build-arg BASE="$base" --build-arg RUNTIME_DEPS=$rt "$TESTS_DIR/containers" >/dev/null

	OUT=${OUT:-$(new_out_dir container "$DISTRO" "$PKG" "$SESSION")}
	chmod 777 "$OUT"
	local run=(--rm --init --shm-size=1g --security-opt seccomp=unconfined "${platform[@]}"
		-v "$GUEST_DIR:/tests:ro" -v "$(dirname "$FILE"):/pkg:ro" -v "$OUT:/out"
		-e DISPLAY_MODE="$SESSION" -e APP_ARGS="$APP_ARGS" -e WAIT="$WAIT" -e HOLD="$HOLD" -e VNC="$VNC"
		-e PLAY="$PLAY" -e FAKE_PORTAL="$PORTAL" -e CLOSE="$CLOSE")
	[ "$HOLD" = shell ] && run+=(-it)
	[ "$VNC" = 1 ] && run+=(-p 127.0.0.1:5900:5900)
	if [ "$LOGIN" = 1 ]; then
		SESSION_SRC=$(resolve_session)
		run+=(-v "$SESSION_SRC:/run/secrets/deezer-session.env:ro" -v "$(session_cache_dir):/run/secrets/profile-cache")
	fi
	local guest_pkg=/pkg/$(basename "$FILE")
	[ "$PKG" = nix ] && run+=(-v "$REPO_DIR:/repo:ro") && guest_pkg=/repo
	log "container: $DISTRO / $PKG / $SESSION ($(basename "$FILE")) -> $OUT"
	[ "$VNC" = 1 ] && log "VNC: vncviewer 127.0.0.1:5900 (once the checks are done)"
	set +e
	if [ "$HOLD" = shell ]; then
		"$engine" run "${run[@]}" "$image" bash /tests/container-entry.sh "$PKG" "$guest_pkg"
	else
		"$engine" run "${run[@]}" "$image" bash /tests/container-entry.sh "$PKG" "$guest_pkg" 2>&1 |
			tee "$OUT/run.log" | grep --line-buffered -E '^---' >&2
	fi
	set -e
	scrub_out "$OUT" "$SESSION_SRC"
	verdict "$OUT"
}

# ---------------------------------------------------------------- host ---
cmd_host() {
	parse_opts "$@"
	need python3 dbus-send
	PKG=${PKG:-installed}
	OUT=${OUT:-$(new_out_dir host "$(. /etc/os-release && echo "${ID:-linux}")" "$PKG" "${SESSION:-session}")}
	local app
	if [ "$PKG" = installed ]; then
		app=$("$GUEST_DIR/install.sh" installed "") || die "no installed app found: install one or pass -p/-f"
	else
		resolve_pkg_file
		case $PKG in
		unpacked) app="$FILE/deezer-desktop --no-sandbox" ;;
		appimage) chmod +x "$FILE"; app="$FILE --no-sandbox" ;;
		*) die "host mode runs installed apps, unpacked builds or AppImages; install the $PKG yourself and use -p installed" ;;
		esac
	fi
	case $SESSION in
	wayland) APP_ARGS="--ozone-platform=wayland $APP_ARGS" ;;
	xwayland | x11) APP_ARGS="--ozone-platform=x11 $APP_ARGS" ;;
	esac
	if pgrep -x deezer-desktop >/dev/null; then die "Deezer is already running: quit it first (single-instance app)"; fi
	local env=(APP="$app" OUT="$OUT" DISPLAY_MODE=host APP_ARGS="$APP_ARGS" WAIT="$WAIT" HOLD="$HOLD" PLAY="$PLAY" FAKE_PORTAL="$PORTAL" CLOSE="$CLOSE")
	if [ "$LOGIN" = 1 ]; then
		SESSION_SRC=$(resolve_session)
		env+=(SESSION_FILE="$SESSION_SRC")
	fi
	log "host: $app ($([ "$LOGIN" = 1 ] && echo "logged in" || echo "logged out")) -> $OUT"
	warn "this uses your real profile (~/.config/deezer-desktop): --login replaces the account you are logged in with"
	set +e
	env "${env[@]}" "$GUEST_DIR/smoke.sh" 2>&1 | tee "$OUT/run.log" | grep -E '^(RESULT|FAILURES|WARNINGS|---)' >&2
	set -e
	scrub_out "$OUT" "$SESSION_SRC"
	verdict "$OUT"
}

# ------------------------------------------------------------------ vm ---
cmd_vm() {
	parse_opts "$@"
	# shellcheck source=lib/vm.sh
	. "$TESTS_DIR/lib/vm.sh"
	vm_main
}

# -------------------------------------------------------------- matrix ---
cmd_matrix() {
	local file=${1:-$TESTS_DIR/matrix.txt} n=0 failed=0 root
	[ -f "$file" ] || die "no matrix file $file"
	root=$(new_out_dir matrix)
	while read -r line; do
		line=${line%%#*}
		[ -z "${line// /}" ] && continue
		n=$((n + 1))
		log "[$n] tests/run.sh $line"
		# A matrix line is a (shell-quoted) argument list for this script.
		if ! eval "OUT_ROOT=\"\$root\" bash \"\$0\" $line" </dev/null; then failed=$((failed + 1)); fi
	done <"$file"
	cmd_report "$root" | tee "$root/report.md"
	log "$((n - failed))/$n passed, report: $root/report.md"
	[ $failed = 0 ]
}

# -------------------------------------------------------------- report ---
cmd_report() {
	local root=${1:-$TESTS_DIR/out} f d k v
	local -A r
	echo "| Result | Environment | OS | Session | Window (s) | Class / app_id | Taskbar entry | MPRIS | Tray icon | Notification | Patches | Login | Notes |"
	echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
	for f in $(find "$root" -name result.env | sort); do
		d=$(dirname "$f")
		r=()
		while IFS='=' read -r k v; do r[$k]=$v; done <"$f"
		printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
			"$([ "${r[RESULT]:-}" = pass ] && echo "✅" || echo "❌")" \
			"$(basename "$d" | cut -d- -f3- | sed 's/-[^-]*$//')${r[APP_ARGS]:+ \`${r[APP_ARGS]}\`}" "${r[OS]:-}" \
			"${r[DISPLAY_MODE]:-}/${r[DESKTOP]:-}" "${r[TIME_TO_WINDOW]:-none}" "${r[WINDOW_CLASS]:-}" \
			"${r[TASKBAR_LINK]:--}" "${r[MPRIS_IDENTITY]:-none} → ${r[MPRIS_LINK]:--}" "${r[TRAY_ICON]:-${r[TRAY_ITEMS]:-}}" \
			"${r[NOTIFY_COUNT]:--} → ${r[NOTIFY_LINK]:--}" "${r[PATCHES]:--}" "${r[LOGGED_IN]:--}${r[LOGIN_SOURCE]:+ (${r[LOGIN_SOURCE]})}" \
			"$(printf '%s;%s' "${r[FAILURES]:-}" "${r[WARNINGS]:-}" | sed 's/^;*//; s/;*$//; s/;/; /g; s/|/\\|/g')"
	done
	echo
	echo "<sub>Generated by \`tests/run.sh report\`. Logs and screenshots: \`$root\` (secrets redacted).</sub>"
}

# ---------------------------------------------------------------- unit ---
cmd_unit() {
	need python3
	python3 -m unittest discover -s "$TESTS_DIR/unit" -t "$TESTS_DIR/unit" "$@"
}

# ------------------------------------------------------------- session ---
cmd_session() {
	case ${1:-check} in
	path) session_file ;;
	check)
		local f
		f=$(resolve_session)
		SESSION_SRC=$f
		DEEZER_ARL_VALUE=$(session_arl "$f") python3 -I "$TESTS_DIR/lib/session.py" check
		;;
	import-firefox)
		local f
		f=$(session_file)
		mkdir -p "$(dirname "$f")"
		python3 -I "$TESTS_DIR/lib/session.py" import-firefox "$f"
		chmod 600 "$f"
		log "saved to $f, now run: tests/run.sh session check"
		;;
	forget)
		rm -rf "$CACHE_DIR/session"
		log "cached logged-in profile removed: the next --login run logs in through the deep link again"
		;;
	*) die "usage: tests/run.sh session check|path|import-firefox|forget" ;;
	esac
}

# --------------------------------------------------------------- fetch ---
cmd_fetch() {
	local version=latest arch
	arch=$(host_arch)
	while [ $# -gt 0 ]; do
		case $1 in
		--version) version=$2; shift ;;
		-a | --arch) arch=$2; shift ;;
		*) die "usage: tests/run.sh fetch [--version vX.Y.Z] [--arch x64|arm64|all]" ;;
		esac
		shift
	done
	need curl python3
	local api=https://api.github.com/repos/aunetx/deezer-linux/releases/$([ "$version" = latest ] && echo latest || echo "tags/$version")
	curl -fsSL "$api" | python3 -I -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    print(a["name"], a["browser_download_url"])' | while read -r name url; do
		case $name in
		*aarch64* | *arm64*) dir=$REPO_DIR/artifacts/arm64 ;;
		sha256) continue ;;
		*) dir=$REPO_DIR/artifacts/x64 ;;
		esac
		[ "$arch" = all ] || [ "$dir" = "$REPO_DIR/artifacts/$arch" ] || continue
		mkdir -p "$dir"
		[ -f "$dir/$name" ] && continue
		log "downloading $name"
		curl -fsSL -o "$dir/$name" "$url"
	done
}

# -------------------------------------------------------------- doctor ---
cmd_doctor() {
	local tier tools t
	for tier in "common:bash python3 curl" \
		"container:docker|podman" \
		"vm:qemu-system-x86_64 qemu-img genisoimage|xorriso|mkisofs ssh scp /dev/kvm" \
		"vm-arm64:qemu-system-aarch64 /usr/share/AAVMF/AAVMF_CODE.fd" \
		"host:dbus-send python3-gi xdotool|swaymsg|atspi"; do
		printf '%s%-10s%s' "$C_B" "${tier%%:*}" "$C_0"
		tools=${tier#*:}
		for t in $tools; do
			local ok=0 alt
			for alt in ${t//|/ }; do
				case $alt in
				/*) [ -e "$alt" ] && ok=1 ;;
				python3-gi) python3 -c 'import gi' 2>/dev/null && ok=1 ;;
				atspi) python3 -c 'import gi; gi.require_version("Atspi", "2.0")' 2>/dev/null && ok=1 ;;
				*) have "$alt" && ok=1 ;;
				esac
			done
			[ $ok = 1 ] && printf ' %s✓%s %s' "$C_G" "$C_0" "$t" || printf ' %s✗%s %s' "$C_R" "$C_0" "$t"
		done
		echo
	done
	[ -w /dev/kvm ] || warn "/dev/kvm is not writable: add yourself to the 'kvm' group (VMs will be very slow)"
	printf '%ssession%s    %s\n' "$C_B" "$C_0" "$(session_file)$([ -r "$(session_file)" ] && echo " (present)" || echo " (missing: needed for --login only)")"
}

cmd_list() {
	echo "Container distros: $DISTROS"
	echo "VM profiles:       $(. "$TESTS_DIR/lib/vm.sh" && echo "$VM_PROFILES")"
	echo "Sessions:          x11 (Xvfb + openbox), wayland (headless sway, no Xwayland), xwayland (headless sway + Xwayland)"
	echo "Package types:     $PKG_TYPES"
}

case ${1:-help} in
container | vm | host | matrix | report | unit | session | fetch | doctor | list)
	c=$1
	shift
	"cmd_$c" "$@"
	;;
help | -h | --help) usage ;;
*) usage >&2; exit 2 ;;
esac

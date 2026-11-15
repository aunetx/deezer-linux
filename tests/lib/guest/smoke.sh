#!/usr/bin/env bash
# Environment-agnostic smoke test. Runs INSIDE the guest: a container, a VM, or
# the machine you are sitting at. It starts a display (or reuses yours), launches
# the app, checks it, optionally logs in, writes $OUT/result.env and exits 0
# (pass) or 1 (fail).
#
# Required env:
#   APP            command line that launches the app (e.g. "deezer-desktop")
# Optional env:
#   DISPLAY_MODE   x11 | wayland | xwayland | host        (default: host)
#   APP_ARGS       extra app flags (e.g. "--start-in-tray")
#   OUT            output directory                        (default: /tmp/deezer-smoke)
#   WAIT           seconds to wait for the window          (default: 30)
#   EXPECT_WINDOW  yes | no (no with --start-in-tray)      (default: auto)
#   SESSION_FILE   session.env with DEEZER_ARL -> log in through deezer://.../autolog/
#   PLAY           1 = after login, send MPRIS Play and check PlaybackStatus
#   SNI_STUB       auto | yes | no  start a tray watcher stub (default: auto = if none on the bus)
#   FAKE_PORTAL    1 = start a fake portal.Settings (for --sync-theme)
#   CLOSE          1 = close the window at the end, check hide-to-tray (default with --disable-systray)
#   LAUNCHER       direct | systemd   (systemd-run --user, for real desktop sessions over ssh)
#   HOLD           0 | 1 | shell      keep everything running after the checks (debug)
#   VNC            1 = serve the display over VNC on port 5900 (x11/wayland/xwayland modes)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
DISPLAY_MODE=${DISPLAY_MODE:-host}
OUT=${OUT:-/tmp/deezer-smoke}
WAIT=${WAIT:-30}
APP_ARGS=${APP_ARGS:-}
LAUNCHER=${LAUNCHER:-direct}
DEEP_LINK_HOST=${DEEP_LINK_HOST:-www.deezer.com}
SLOW_WINDOW_SECONDS=${SLOW_WINDOW_SECONDS:-5}
: "${APP:?APP must be set to the command that launches the app}"

# Headless modes need a private session bus: re-exec under one.
if [ "$DISPLAY_MODE" != host ] && [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	exec dbus-run-session -- "$0" "$@"
fi

mkdir -p "$OUT"
: >"$OUT/result.env"
PIDS=()
FAILURES=()
WARNINGS=()

R() { printf '%s=%s\n' "$1" "$2" | tee -a "$OUT/result.env"; }
fail() { FAILURES+=("$1"); }
warn() { WARNINGS+=("$1"); }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
bg() { "$@" & PIDS+=($!); }

# ---------------------------------------------------------------- display ---
start_sway() { # $1 = xwayland setting (disable | force)
	export XDG_RUNTIME_DIR
	XDG_RUNTIME_DIR=$(mktemp -d /tmp/xdg.XXXX)
	chmod 700 "$XDG_RUNTIME_DIR"
	unset DISPLAY WAYLAND_DISPLAY
	export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
	printf 'output HEADLESS-1 mode 1280x800@60Hz\nxwayland %s\n' "$1" >"$XDG_RUNTIME_DIR/sway.cfg"
	local xsockets_before
	xsockets_before=$(ls /tmp/.X11-unix 2>/dev/null)
	bg sway --unsupported-gpu -c "$XDG_RUNTIME_DIR/sway.cfg" >"$OUT/compositor.log" 2>&1
	for _ in $(seq 100); do
		ls "$XDG_RUNTIME_DIR"/sway-ipc.* >/dev/null 2>&1 && ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && break
		sleep 0.1
	done
	WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")
	SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)
	export WAYLAND_DISPLAY SWAYSOCK
	if [ "$1" = force ]; then
		for _ in $(seq 100); do
			local new
			new=$(comm -13 <(echo "$xsockets_before") <(ls /tmp/.X11-unix 2>/dev/null) | head -1)
			[ -n "$new" ] && { export DISPLAY=":${new#X}"; break; }
			sleep 0.1
		done
	fi
}

discover_host_session() { # fill in what ssh / su sessions do not inherit
	local rt=/run/user/$(id -u)
	export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-$rt}
	[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] &&
		export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
	# Desktops export their session variables to the systemd user manager.
	local line name
	[ "${XDG_SESSION_TYPE:-}" = tty ] && unset XDG_SESSION_TYPE # ssh login, not the desktop's
	while IFS= read -r line; do
		name=${line%%=*}
		case $name in
		XDG_CURRENT_DESKTOP | XDG_SESSION_TYPE | DESKTOP_SESSION | WAYLAND_DISPLAY | DISPLAY | XAUTHORITY | SWAYSOCK)
			[ -z "${!name:-}" ] && export "${line?}" ;;
		esac
	done < <(systemctl --user show-environment 2>/dev/null)
	[ -z "${WAYLAND_DISPLAY:-}" ] && ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 &&
		export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")
	[ -z "${DISPLAY:-}" ] && ls /tmp/.X11-unix/X* >/dev/null 2>&1 &&
		export DISPLAY=":$(ls /tmp/.X11-unix | head -1 | tr -dc 0-9)"
	if [ -z "${XDG_SESSION_TYPE:-}" ]; then
		if [ -n "${WAYLAND_DISPLAY:-}" ]; then export XDG_SESSION_TYPE=wayland
		elif [ -n "${DISPLAY:-}" ]; then export XDG_SESSION_TYPE=x11; fi
	fi
	[ -z "${SWAYSOCK:-}" ] && ls "$XDG_RUNTIME_DIR"/sway-ipc.* >/dev/null 2>&1 &&
		export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* | head -1)
	return 0
}

APP_FLAGS=(--log-level=debug)
case $DISPLAY_MODE in
x11)
	export DISPLAY=:99
	unset WAYLAND_DISPLAY
	bg Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >"$OUT/compositor.log" 2>&1
	for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
	have openbox && bg openbox >"$OUT/wm.log" 2>&1
	WINDOW_BACKEND=xdotool
	;;
wayland)
	start_sway disable
	APP_FLAGS+=(--ozone-platform=wayland)
	WINDOW_BACKEND=sway
	;;
xwayland)
	start_sway force
	APP_FLAGS+=(--ozone-platform=x11)
	WINDOW_BACKEND=sway
	;;
host)
	discover_host_session
	if [ -n "${SWAYSOCK:-}" ] && have swaymsg; then
		WINDOW_BACKEND=sway
	elif [ "${XDG_SESSION_TYPE:-}" = x11 ] && [ -n "${DISPLAY:-}" ] && have xdotool; then
		WINDOW_BACKEND=xdotool # exact WM_CLASS and can close windows, unlike AT-SPI
	elif have python3 && python3 -c 'import gi; gi.require_version("Atspi", "2.0")' 2>/dev/null; then
		WINDOW_BACKEND=atspi
		APP_FLAGS+=(--force-renderer-accessibility)
	elif [ -n "${DISPLAY:-}" ] && have xdotool; then
		WINDOW_BACKEND=xdotool
	else
		WINDOW_BACKEND=none
	fi
	;;
*)
	echo "unknown DISPLAY_MODE: $DISPLAY_MODE" >&2
	exit 2
	;;
esac

# ------------------------------------------------------------ environment ---
{
	echo "== os-release"; cat /etc/os-release 2>/dev/null
	echo "== uname"; uname -a
	echo "== session"; env | grep -E '^(XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|DESKTOP_SESSION|WAYLAND_DISPLAY|DISPLAY)=' | sort
	echo "== gpu"; (have glxinfo && glxinfo -B 2>/dev/null) || (have lspci && lspci | grep -iE 'vga|3d|display') || echo unknown
	echo "== package"
	(dpkg -s deezer-desktop 2>/dev/null || rpm -q deezer-desktop 2>/dev/null ||
		flatpak info dev.aunetx.deezer 2>/dev/null || snap list deezer-desktop 2>/dev/null) | head -12
} >"$OUT/env.txt" 2>&1
. /etc/os-release 2>/dev/null || true
[ -z "${PRETTY_NAME:-}" ] && have nix-env && PRETTY_NAME="Nix ($(nix-env --version | awk '{print $NF}'))"
R OS "${PRETTY_NAME:-unknown}"
R ARCH "$(uname -m)"
R DISPLAY_MODE "$DISPLAY_MODE"
R DESKTOP "${XDG_CURRENT_DESKTOP:-none}"
R WINDOW_BACKEND "$WINDOW_BACKEND"
R APP "$APP $APP_ARGS"

# ----------------------------------------------------------- integration ---
bus_names() {
	dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus.ListNames 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'
}
SNI_STUB=${SNI_STUB:-auto}
if [ "$SNI_STUB" = auto ]; then
	bus_names | grep -qx org.kde.StatusNotifierWatcher && SNI_STUB=no || SNI_STUB=yes
fi
if [ "$SNI_STUB" = yes ]; then
	SNI_LOG="$OUT/sni.log" bg python3 "$HERE/sni_watcher.py" >/dev/null 2>&1
	sleep 0.5
fi
if [ "${FAKE_PORTAL:-0}" = 1 ]; then
	PORTAL_LOG="$OUT/portal.log" bg python3 "$HERE/fake_portal.py" >/dev/null 2>&1
	sleep 0.5
fi
# Headless guests get a null audio sink so playback can start after login.
if [ "$DISPLAY_MODE" != host ] && have pulseaudio && ! pactl info >/dev/null 2>&1; then
	pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=file:/tmp/pulse.log \
		-n -L module-null-sink -L module-native-protocol-unix -L module-always-sink >/dev/null 2>&1
fi

# ---------------------------------------------------------------- launch ---
# shellcheck disable=SC2206 # APP and APP_ARGS are intentionally word-split
CMD=($APP "${APP_FLAGS[@]}" $APP_ARGS)
T0=$(now)
if [ "$LAUNCHER" = systemd ]; then
	systemctl --user reset-failed deezer-smoke.service >/dev/null 2>&1
	systemd-run --user --unit=deezer-smoke --collect --quiet \
		-p StandardOutput=file:"$OUT/app.log" -p StandardError=file:"$OUT/app.log" \
		--setenv=DISPLAY="${DISPLAY:-}" --setenv=WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
		--setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		"${CMD[@]}"
	alive() { systemctl --user is-active --quiet deezer-smoke.service; }
	stop_app() { systemctl --user stop deezer-smoke.service >/dev/null 2>&1; }
else
	"${CMD[@]}" >"$OUT/app.log" 2>&1 &
	APP_PID=$!
	alive() { kill -0 "$APP_PID" 2>/dev/null; }
	stop_app() { kill "$APP_PID" 2>/dev/null; sleep 1; kill -9 "$APP_PID" 2>/dev/null; pkill -f deezer-desktop 2>/dev/null; }
fi

# Prints "<id>\t<class or app_id>\t<title>\t<shell>" for each visible app window.
windows() {
	case $WINDOW_BACKEND in
	xdotool)
		for w in $(xdotool search --classname deezer 2>/dev/null); do
			xwininfo -id "$w" 2>/dev/null | grep -q IsViewable || continue
			printf '%s\t%s\t%s\tx11\n' "$w" \
				"$(xprop -id "$w" WM_CLASS 2>/dev/null | cut -d= -f2 | tr -d ' "' | awk -F, '{ print $NF }')" \
				"$(xdotool getwindowname "$w" 2>/dev/null)"
		done
		;;
	sway)
		swaymsg -t get_tree 2>/dev/null | python3 "$HERE/sway_windows.py"
		;;
	atspi)
		python3 "$HERE/atspi_windows.py" 2>/dev/null | awk -F'\t' '$3 == "yes" { print NR "\t" $1 "\t" $2 "\tatspi" }'
		;;
	esac
}

case ${EXPECT_WINDOW:-auto} in
auto) [[ " $APP_ARGS " == *" --start-in-tray "* ]] && EXPECT_WINDOW=no || EXPECT_WINDOW=yes ;;
esac

TWIN=""
for _ in $(seq $((WAIT * 5))); do
	alive || break
	if [ -n "$(windows | head -1)" ]; then TWIN=$(elapsed "$T0"); break; fi
	sleep 0.2
done
[ "$EXPECT_WINDOW" = no ] && sleep "${SETTLE:-5}" || sleep "${SETTLE:-2}"

alive && R ALIVE yes || { R ALIVE no; fail "process exited"; }
R TIME_TO_WINDOW "${TWIN:-none}"
WIN=$(windows | head -1)
R WINDOW_CLASS "$(cut -f2 <<<"$WIN")"
R WINDOW_TITLE "$(cut -f3 <<<"$WIN")"
R WINDOW_SHELL "$(cut -f4 <<<"$WIN")"
if [ "$WINDOW_BACKEND" = none ]; then
	warn "no window backend (install xdotool, swaymsg or python3-gi + AT-SPI)"
elif [ "$EXPECT_WINDOW" = yes ]; then
	[ -z "$TWIN" ] && fail "no visible window after ${WAIT}s"
	[ -n "$TWIN" ] && awk -v t="$TWIN" -v m="$SLOW_WINDOW_SECONDS" 'BEGIN { exit !(t > m) }' &&
		warn "window took ${TWIN}s to show (> ${SLOW_WINDOW_SECONDS}s)"
	[ -n "$WIN" ] && [ "$(cut -f2 <<<"$WIN")" != dev.aunetx.deezer ] && [ "$WINDOW_BACKEND" != atspi ] &&
		warn "window class '$(cut -f2 <<<"$WIN")' != StartupWMClass 'dev.aunetx.deezer'"
else
	[ -n "$WIN" ] && fail "window is visible although EXPECT_WINDOW=no"
fi

mpris_get() { # $1 = interface, $2 = property
	dbus-send --session --print-reply --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 \
		org.freedesktop.DBus.Properties.Get string:"$1" string:"$2" 2>/dev/null |
		tail -n +2 | grep -o '"[^"]*"' | head -1 | tr -d '"'
}
MPRIS_NAME=$(bus_names | grep -m1 '^org.mpris.MediaPlayer2\.')
R MPRIS "${MPRIS_NAME:-none}"
if [ -n "$MPRIS_NAME" ]; then
	R MPRIS_IDENTITY "$(mpris_get org.mpris.MediaPlayer2 Identity)"
	R MPRIS_DESKTOP_ENTRY "$(mpris_get org.mpris.MediaPlayer2 DesktopEntry)"
	R MPRIS_STATUS "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)"
else
	fail "no MPRIS service on the session bus"
fi

if [ "$SNI_STUB" = yes ]; then
	SNI=$(grep -c SNI_REGISTERED "$OUT/sni.log" 2>/dev/null)
	R TRAY_ITEMS "${SNI:-0}"
	[ "${SNI:-0}" -eq 0 ] && fail "no tray icon registered"
	[ "${SNI:-0}" -gt 1 ] && warn "$SNI tray icons registered"
else
	R TRAY_ITEMS "host-watcher"
fi

if [ "${FAKE_PORTAL:-0}" = 1 ]; then
	pkill -USR1 -f fake_portal.py
	sleep 2
	R PORTAL_READS "$(grep -c 'PORTAL_Read' "$OUT/portal.log" 2>/dev/null)"
fi

# ------------------------------------------------------------ screenshot ---
screenshot() { # $1 = file
	case $WINDOW_BACKEND/$DISPLAY_MODE in
	*/x11) import -window root "$1" ;;
	sway/*) grim "$1" ;;
	*) (have grim && grim "$1") || (have spectacle && spectacle -b -n -f -o "$1") ||
		(have gnome-screenshot && gnome-screenshot -f "$1") || (have import && import -window root "$1") ;;
	esac >/dev/null 2>&1
}
screenshot "$OUT/screenshot.png"

# ----------------------------------------------------------------- login ---
read_arl() { grep -E '^[[:space:]]*DEEZER_ARL=' "$1" | tail -1 | cut -d= -f2- | tr -d "\"' \r"; }
ARL=""
[ -n "${SESSION_FILE:-}" ] && [ -r "$SESSION_FILE" ] && ARL=$(read_arl "$SESSION_FILE")
if [ -n "${SESSION_FILE:-}" ]; then
	if [ -z "$ARL" ]; then
		R LOGGED_IN no
		fail "SESSION_FILE has no DEEZER_ARL"
	elif ! alive; then
		R LOGGED_IN no
	else
		ok_before=$(grep -c 'User autolog succeeded, loading' "$OUT/app.log")
		lines_before=$(wc -l <"$OUT/app.log")
		# A second instance hands the deep link to the running one, like a browser would.
		"${CMD[@]}" "deezer://$DEEP_LINK_HOST/autolog/$ARL" >"$OUT/second-instance.log" 2>&1
		LOGGED=""
		for _ in $(seq $((${LOGIN_WAIT:-45} * 2))); do
			[ "$(grep -c 'User autolog succeeded, loading' "$OUT/app.log")" -gt "$ok_before" ] && { LOGGED=yes; break; }
			tail -n +"$((lines_before + 1))" "$OUT/app.log" |
				grep -qE 'User autolog failed|must re-authenticate|Arl token is not found' && { LOGGED=no; break; }
			sleep 0.5
		done
		R LOGGED_IN "${LOGGED:-timeout}"
		[ "$LOGGED" = yes ] || fail "login with the shared session failed (${LOGGED:-timeout})"
		sleep "${LOGIN_SETTLE:-8}"
		screenshot "$OUT/screenshot-logged-in.png"
		if [ "$LOGGED" = yes ] && [ "${PLAY:-0}" = 1 ] && [ -n "$MPRIS_NAME" ]; then
			dbus-send --session --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Play
			sleep "${PLAY_WAIT:-10}"
			R PLAY_STATUS "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)"
			R PLAY_TITLE "$(dbus-send --session --print-reply --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 \
				org.freedesktop.DBus.Properties.Get string:org.mpris.MediaPlayer2.Player string:Metadata 2>/dev/null |
				grep -A1 '"xesam:title"' | tail -1 | grep -o '"[^"]*"' | tr -d '"')"
			have pactl && R AUDIO_STREAM "$(pactl list sink-inputs 2>/dev/null | grep -m1 'application.name' | cut -d'"' -f2)"
			[ "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)" = Playing ] || warn "playback did not start"
		fi
	fi
fi

# ----------------------------------------------------------------- close ---
# Closing the window hides it to the tray, or quits with --disable-systray.
[[ " $APP_ARGS " == *" --disable-systray "* ]] && CLOSE=1
if [ "${CLOSE:-0}" = 1 ] && [ -n "$WIN" ] && alive; then
	case $WINDOW_BACKEND in
	xdotool) xdotool windowactivate --sync "$(cut -f1 <<<"$WIN")" key --clearmodifiers alt+F4 ;;
	sway) swaymsg "[con_id=$(cut -f1 <<<"$WIN")] kill" ;;
	*) WIN="" ;;
	esac >/dev/null 2>&1
	if [ -z "$WIN" ]; then
		warn "closing the window is not supported with the $WINDOW_BACKEND backend"
	else
		sleep "${CLOSE_WAIT:-5}"
		alive && R ALIVE_AFTER_CLOSE yes || R ALIVE_AFTER_CLOSE no
		if [[ " $APP_ARGS " == *" --disable-systray "* ]]; then
			alive && fail "app still running after closing its window with --disable-systray"
		else
			alive || fail "app quit when its window was closed (expected: hide to tray)"
		fi
	fi
fi

# ------------------------------------------------------------------ logs ---
FATAL_RE='Cannot find module|FATAL:|Failed to connect to Wayland display|Segmentation fault|Zygote process exited|Uncaught Exception|Missing X server'
grep -E "$FATAL_RE" "$OUT/app.log" >"$OUT/fatal.txt" 2>/dev/null
R LOG_FATAL "$(wc -l <"$OUT/fatal.txt")"
[ -s "$OUT/fatal.txt" ] && fail "fatal lines in app.log (see fatal.txt)"

# ---------------------------------------------------------------- verdict ---
R WARNINGS "$(IFS=';'; echo "${WARNINGS[*]}")"
R FAILURES "$(IFS=';'; echo "${FAILURES[*]}")"
[ ${#FAILURES[@]} -eq 0 ] && R RESULT pass || R RESULT fail

# Scrub session secrets before anything leaves the guest.
python3 "$HERE/redact.py" "$OUT" "$ARL"

if [ "${HOLD:-0}" != 0 ]; then
	if [ "${VNC:-0}" = 1 ]; then
		if [ "$WINDOW_BACKEND" = sway ] && have wayvnc; then
			bg wayvnc 0.0.0.0 5900 >"$OUT/vnc.log" 2>&1
		elif have x11vnc; then
			bg x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -rfbport 5900 >"$OUT/vnc.log" 2>&1
		fi
	fi
	echo "--- HOLD: app and display are still running (DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-})"
	if [ "$HOLD" = shell ] && [ -t 0 ]; then
		echo "--- debug shell; 'exit' tears everything down"
		bash -i
	else
		echo "--- press Ctrl+C (or stop the container/VM) to tear down"
		sleep infinity & wait $!
	fi
	python3 "$HERE/redact.py" "$OUT" "$ARL"
fi

stop_app
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
have pulseaudio && pulseaudio --kill >/dev/null 2>&1
[ ${#FAILURES[@]} -eq 0 ]

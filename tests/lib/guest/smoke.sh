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
#   PROFILE_IN     tar of a logged-in app profile to start from (skips the deep-link login)
#   PROFILE_OUT    where to save the app profile after a successful login (session cache)
#   CDP            0 = do not open the DevTools port (skips the in-page checks)
#
# No fixed sleeps: every wait polls for a specific signal (a socket, a bus name,
# a log line, a page state) and gives up after a maximum time. Each wait is
# logged to $OUT/waits.log with how long it took. Failures tagged "[<id>]" whose
# id is listed in known-issues.txt are known issues: they end the run as
# RESULT=known instead of pass or fail.
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
: >"$OUT/waits.log"
PIDS=()
FAILURES=()
WARNINGS=()
KNOWN=()
KNOWN_IDS=$(sed -n 's/^\([a-z0-9-]\{1,\}\)[[:space:]].*/\1/p' "$HERE/known-issues.txt" 2>/dev/null)

R() { printf '%s=%s\n' "$1" "$2" | tee -a "$OUT/result.env"; }
fail() { # "[<id>] reason" with an id from known-issues.txt is a known issue, not a failure
	if [[ $1 =~ ^\[([a-z0-9-]+)\]\  ]] && grep -qx "${BASH_REMATCH[1]}" <<<"$KNOWN_IDS"; then
		KNOWN+=("$1")
	else
		FAILURES+=("$1")
	fi
}
warn() { WARNINGS+=("$1"); }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
bg() { "$@" & PIDS+=($!); }
usec() { local t=${EPOCHREALTIME/[.,]/}; echo "$t"; } # bash 5; the decimal mark follows the locale

# Polls a condition until it holds (returns 0) or <max> seconds pass (returns 1).
wait_for() { # $1 = label (waits.log), $2 = max seconds, $3... = condition
	local label=$1 max=$2 start end
	shift 2
	start=$(usec)
	end=$((start + max * 1000000))
	until "$@"; do
		if [ "$(usec)" -ge "$end" ]; then
			printf '%s timeout %ss\n' "$label" "$max" >>"$OUT/waits.log"
			return 1
		fi
		sleep 0.1 # poll interval
	done
	printf '%s ok %s\n' "$label" "$(awk -v a="$start" -v b="$(usec)" 'BEGIN { printf "%.2fs", (b - a) / 1e6 }')" >>"$OUT/waits.log"
}
# The opposite: checks that something does NOT happen within <max> seconds (returns 0
# if it held). Use it only with a max taken from the app's own deadline.
holds_for() { # $1 = label, $2 = max seconds, $3... = condition that breaks it
	local label=$1 max=$2
	shift 2
	if wait_for "$label" "$max" "$@" 2>/dev/null; then
		sed -i "\$s/^$label ok /$label broken after /" "$OUT/waits.log"
		return 1
	fi
	sed -i "\$s/^$label timeout /$label held /" "$OUT/waits.log"
}
in_log() { grep -qE "$2" "$OUT/$1" 2>/dev/null; } # $1 = file in $OUT, $2 = regex
# A setup step that cannot complete makes every later check meaningless: stop here.
abort() {
	fail "$1"
	R FAILURES "$(IFS=';'; echo "${FAILURES[*]}")"
	R RESULT fail
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	exit 1
}

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
	sway_up() { ls "$XDG_RUNTIME_DIR"/sway-ipc.* "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; }
	SWAYSOCK=""
	sway_ipc() { SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1); [ -n "$SWAYSOCK" ] && SWAYSOCK=$SWAYSOCK sway_up; }
	wait_for sway 20 sway_ipc || abort "sway did not start (see compositor.log)"
	WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")
	export WAYLAND_DISPLAY SWAYSOCK
	if [ "$1" = force ]; then
		local new=""
		new_xsocket() { new=$(comm -13 <(echo "$xsockets_before") <(ls /tmp/.X11-unix 2>/dev/null) | head -1); [ -n "$new" ]; }
		wait_for xwayland 20 new_xsocket || abort "sway started no Xwayland server (see compositor.log)"
		export DISPLAY=":${new#X}"
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

APP_ARGS=${APP_ARGS//@TESTS@/$HERE} # lets matrix lines point at files shipped with the tests
has_arg() { [[ " $APP_ARGS " == *" $1 "* || " $APP_ARGS " == *" $1="* ]]; }
APP_FLAGS=(--log-level=debug)
if [ "${CDP:-1}" = 1 ]; then
	CDP_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
	APP_FLAGS+=(--remote-debugging-port="$CDP_PORT")
fi
# A portable cookie store, so the cached session works in every guest.
[ -n "${SESSION_FILE:-}" ] && APP_FLAGS+=(--password-store=basic)
# Login sessions list snapd's desktop files (its profile.d and systemd generator):
# libnotify only keeps a snap's desktop-entry hint when it finds the file there.
if [ -d /var/lib/snapd/desktop ] && [[ ":${XDG_DATA_DIRS:-}:" != *:/var/lib/snapd/desktop:* ]]; then
	export XDG_DATA_DIRS=${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/snapd/desktop
fi
case $DISPLAY_MODE in
x11)
	export DISPLAY=:99
	unset WAYLAND_DISPLAY
	bg Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >"$OUT/compositor.log" 2>&1
	x_up() { xdpyinfo >/dev/null 2>&1; }
	wait_for xvfb 20 x_up || abort "Xvfb did not start (see compositor.log)"
	if have openbox; then
		bg openbox >"$OUT/wm.log" 2>&1
		# An EWMH window manager announces itself on the root window.
		wm_up() { xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'; }
		wait_for openbox 20 wm_up || abort "openbox did not start (see wm.log)"
	fi
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
	elif { [ "${XDG_SESSION_TYPE:-}" = x11 ] || has_arg --ozone-platform=x11; } && [ -n "${DISPLAY:-}" ] && have xdotool; then
		WINDOW_BACKEND=xdotool # exact WM_CLASS and can close windows, unlike AT-SPI (also Xwayland clients)
	elif have python3 && python3 "$HERE/gnome_windows.py" >/dev/null 2>&1; then
		WINDOW_BACKEND=gnome # GNOME Shell Introspect (gnome-shell --unsafe-mode): app_id, title, mapped state
	elif [ "${XDG_SESSION_TYPE:-}" = wayland ] && have python3 && python3 "$HERE/toplevel_windows.py" --all >/dev/null 2>&1; then
		WINDOW_BACKEND=toplevel # ext-foreign-toplevel-list (COSMIC, wlroots): app_id of mapped toplevels
	elif have python3 && python3 -c 'import gi; gi.require_version("Atspi", "2.0")' 2>/dev/null; then
		WINDOW_BACKEND=atspi
		APP_FLAGS+=(--force-renderer-accessibility)
		# AT-SPI has no app_id: read it from the Wayland protocol log (xdg_toplevel.set_app_id).
		[ "${XDG_SESSION_TYPE:-}" = wayland ] && ! has_arg --ozone-platform=x11 && export WAYLAND_DEBUG=client
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
[ -n "$APP_ARGS" ] && R APP_ARGS "${APP_ARGS//$HERE/@TESTS@}"

# ----------------------------------------------------------- integration ---
bus_names() {
	dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus.ListNames 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'
}
SNI_STUB=${SNI_STUB:-auto}
if [ "$SNI_STUB" = auto ]; then
	bus_names | grep -qx org.kde.StatusNotifierWatcher && SNI_STUB=no || SNI_STUB=yes
fi
# Every helper must own its bus name before the app starts, or the app misses it.
if [ "$SNI_STUB" = yes ]; then
	SNI_LOG="$OUT/sni.log" bg python3 "$HERE/sni_watcher.py" >/dev/null 2>&1
	wait_for sni-watcher 10 in_log sni.log '^SNI_WATCHER_READY' || abort "the tray watcher stub did not start"
fi
NOTIFY_LOG="$OUT/notify.log" bg python3 "$HERE/notify_probe.py" >"$OUT/notify-probe.log" 2>&1
wait_for notify-probe 10 in_log notify-probe.log '^NOTIFY_(MONITOR|SERVER)_READY' ||
	abort "the notification probe did not start (see notify-probe.log)"
if [ "${FAKE_PORTAL:-0}" = 1 ]; then
	PORTAL_LOG="$OUT/portal.log" bg python3 "$HERE/fake_portal.py" >/dev/null 2>&1
	wait_for portal 10 in_log portal.log '^PORTAL_READY' || abort "the fake portal did not start"
fi
# Headless guests get a null audio sink so playback can start after login.
if [ "$DISPLAY_MODE" != host ] && have pulseaudio && ! pactl info >/dev/null 2>&1; then
	pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=file:/tmp/pulse.log \
		-n -L module-null-sink -L module-native-protocol-unix -L module-always-sink >/dev/null 2>&1
	pulse_up() { pactl info >/dev/null 2>&1; }
	wait_for pulseaudio 10 pulse_up || warn "PulseAudio did not start: playback checks will fail"
fi

# --------------------------------------------------------- session cache ---
# A profile saved by an earlier logged-in run: the app starts logged in, as it
# does for a real user, instead of logging in again through the deep link.
profile_base() {
	case $APP in
	*"flatpak run"*) echo "$HOME/.var/app/dev.aunetx.deezer/config" ;;
	*"snap run"*) ;; # ~/snap/<name>/<revision> only exists after the first start
	*) echo "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
	esac
}
PROFILE_BASE=$(profile_base)
if [ -n "${PROFILE_IN:-}" ] && [ -s "$PROFILE_IN" ] && [ -n "${SESSION_FILE:-}" ] && [ -n "$PROFILE_BASE" ]; then
	mkdir -p "$PROFILE_BASE" && tar -xf "$PROFILE_IN" -C "$PROFILE_BASE" && PROFILE_RESTORED=yes
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
		${WAYLAND_DEBUG:+--setenv=WAYLAND_DEBUG="$WAYLAND_DEBUG"} \
		"${CMD[@]}"
	alive() { systemctl --user is-active --quiet deezer-smoke.service; }
	stop_app() { systemctl --user stop deezer-smoke.service >/dev/null 2>&1; }
else
	"${CMD[@]}" >"$OUT/app.log" 2>&1 &
	APP_PID=$!
	alive() { kill -0 "$APP_PID" 2>/dev/null; }
	stop_app() { # SIGTERM first: Chromium then shuts down cleanly and flushes its cookie store
		kill "$APP_PID" 2>/dev/null
		wait_for app-exit 20 dead || { APP_KILLED=yes; kill -9 "$APP_PID" 2>/dev/null; }
		pkill -f deezer-desktop 2>/dev/null
	}
fi
dead() { ! alive; }

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
	gnome)
		python3 "$HERE/gnome_windows.py" 2>/dev/null | cut -f1-4
		;;
	toplevel)
		python3 "$HERE/toplevel_windows.py" 2>/dev/null
		;;
	atspi)
		local app_id=""
		if [ -n "${WAYLAND_DEBUG:-}" ]; then
			# AT-SPI calls the frame "showing" long before the compositor maps it (on Wayland the app
			# maps its toplevel only after a 10 s fallback): wait for xdg_toplevel.set_app_id.
			app_id=$(grep -m1 -aoE 'xdg_toplevel#[0-9]+\.set_app_id\("[^"]*"\)' "$OUT/app.log" | cut -d'"' -f2)
			[ -n "$app_id" ] || return 0
		fi
		python3 "$HERE/atspi_windows.py" 2>/dev/null |
			awk -F'\t' -v id="$app_id" '$3 == "yes" { print NR "\t" (id != "" ? id : $1) "\t" $2 "\tatspi" }'
		;;
	esac
}

case ${EXPECT_WINDOW:-auto} in
auto) [[ " $APP_ARGS " == *" --start-in-tray "* ]] && EXPECT_WINDOW=no || EXPECT_WINDOW=yes ;;
esac

# The app shows its window on ready-to-show, or after a 10 s fallback (setTimeout 1e4 after
# "Creating Window", main.js). With --start-in-tray, ready-to-show hides it; the window must
# still be hidden once that fallback has passed. WINDOW_GRACE covers the compositor mapping it.
SHOW_FALLBACK=10
WINDOW_GRACE=${WINDOW_GRACE:-3}
window_or_exit() { dead || [ -n "$(windows | head -1)" ]; }
created_or_exit() { dead || in_log app.log 'Creating Window'; }
TWIN=""
if [ "$EXPECT_WINDOW" = yes ]; then
	wait_for window "$WAIT" window_or_exit && alive && TWIN=$(elapsed "$T0")
else
	wait_for window-created "$WAIT" created_or_exit
	holds_for window-stays-hidden $((SHOW_FALLBACK + WINDOW_GRACE)) window_or_exit || { alive && TWIN=$(elapsed "$T0"); }
fi
# The app registers its MPRIS player and tray icon at startup; wait for both before checking them.
mpris_up() { dead || bus_names | grep -q '^org.mpris.MediaPlayer2\.'; }
wait_for mpris 20 mpris_up
tray_up() {
	dead && return 0
	if [ "$SNI_STUB" = yes ]; then in_log sni.log '^SNI_REGISTERED'
	else python3 "$HERE/tray_probe.py" 2>/dev/null | grep -qiE '"(id|title)": "(chrome_status_icon|deezer)'; fi
}
has_arg --disable-systray || wait_for tray 20 tray_up

alive && R ALIVE yes || { R ALIVE no; fail "process exited"; }
R TIME_TO_WINDOW "${TWIN:-none}"
WIN=$(windows | head -1)
[ -n "${WAYLAND_DEBUG:-}" ] && R WAYLAND_APP_ID "$(cut -f2 <<<"$WIN" | grep . || echo none)"
R WINDOW_CLASS "$(cut -f2 <<<"$WIN")"
R WINDOW_TITLE "$(cut -f3 <<<"$WIN")"
R WINDOW_SHELL "$(cut -f4 <<<"$WIN")"
if [ "$WINDOW_BACKEND" = none ]; then
	warn "no window backend (install xdotool, swaymsg or python3-gi + AT-SPI)"
elif [ "$EXPECT_WINDOW" = yes ]; then
	[ -z "$TWIN" ] && fail "no visible window after ${WAIT}s"
	[ -n "$TWIN" ] && awk -v t="$TWIN" -v m="$SLOW_WINDOW_SECONDS" 'BEGIN { exit !(t > m) }' &&
		warn "window took ${TWIN}s to show (> ${SLOW_WINDOW_SECONDS}s)"
	# The class (X11) / app_id (Wayland) is what links the window to its launcher (#c093311).
	# A snap names it after the desktop file snapd installs (patch 17).
	case $APP in *"snap run"*) WANT_CLASS=deezer-desktop_deezer-desktop ;; *) WANT_CLASS=dev.aunetx.deezer ;; esac
	[ -n "$WIN" ] && [ "$(cut -f2 <<<"$WIN")" != "$WANT_CLASS" ] && { [ "$WINDOW_BACKEND" != atspi ] || [ -n "${WAYLAND_DEBUG:-}" ]; } &&
		fail "window class '$(cut -f2 <<<"$WIN")' != '$WANT_CLASS'"
else
	[ -n "$WIN" ] && fail "window is visible although EXPECT_WINDOW=no"
fi

# The MPRIS service drops calls flagged NO_REPLY_EXPECTED (plain dbus-send): always wait for the reply.
mpris_call() { dbus-send --session --print-reply --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 "org.mpris.MediaPlayer2.Player.$1" >/dev/null 2>&1; }
mpris_get() { # $1 = interface, $2 = property
	dbus-send --session --print-reply --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 \
		org.freedesktop.DBus.Properties.Get string:"$1" string:"$2" 2>/dev/null |
		tail -n +2 | grep -o '"[^"]*"' | head -1 | tr -d '"'
}
mpris_title() {
	dbus-send --session --print-reply --dest="$MPRIS_NAME" /org/mpris/MediaPlayer2 \
		org.freedesktop.DBus.Properties.Get string:org.mpris.MediaPlayer2.Player string:Metadata 2>/dev/null |
		grep -A1 '"xesam:title"' | tail -1 | grep -o '"[^"]*"' | tr -d '"'
}
MPRIS_NAME=$(bus_names | grep -m1 '^org.mpris.MediaPlayer2\.')
R MPRIS "${MPRIS_NAME:-none}"
if [ -n "$MPRIS_NAME" ]; then
	R MPRIS_IDENTITY "$(mpris_get org.mpris.MediaPlayer2 Identity)"
	MPRIS_DESKTOP_ENTRY=$(mpris_get org.mpris.MediaPlayer2 DesktopEntry)
	R MPRIS_DESKTOP_ENTRY "$MPRIS_DESKTOP_ENTRY"
	R MPRIS_STATUS "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)"
	# The Flatpak only owns org.mpris.MediaPlayer2.deezer (--own-name in package-append.json).
	[ "$MPRIS_NAME" = org.mpris.MediaPlayer2.deezer ] || fail "MPRIS bus name '$MPRIS_NAME' != org.mpris.MediaPlayer2.deezer"
else
	fail "no MPRIS service on the session bus"
fi

# Tray: registration, then whether a host outside the sandbox can draw the icon.
if [ "$SNI_STUB" = yes ]; then
	SNI=$(grep -c SNI_REGISTERED "$OUT/sni.log" 2>/dev/null)
	R TRAY_ITEMS "${SNI:-0}"
	[ "${SNI:-0}" -eq 0 ] && fail "no tray icon registered"
	[ "${SNI:-0}" -gt 1 ] && warn "$SNI tray icons registered"
else
	R TRAY_ITEMS "host-watcher"
fi
python3 "$HERE/tray_probe.py" >"$OUT/tray.json" 2>>"$OUT/tray.json"
# Chromium's items are "chrome_status_icon_N"; a host watcher also lists other apps.
TRAY=$(grep -m1 -iE '"(id|title)": "(chrome_status_icon|deezer)' "$OUT/tray.json")
if [ -n "$TRAY" ]; then
	TRAY_ICON=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["icon"])' "$TRAY")
	R TRAY_ICON "${TRAY_ICON:-unresolved}"
	# The snap fix (a9aad21): the icon file must be readable outside the app's private /tmp.
	[ -z "$TRAY_ICON" ] && fail "tray icon cannot be resolved by the tray host (placeholder icon), see tray.json"
elif [ "$SNI_STUB" = yes ] || [ "${SNI:-0}" != 0 ]; then
	R TRAY_ICON none
fi

# Patches: the running app.asar must contain every patch (catches a dropped port).
python3 "$HERE/asar_probe.py" "$HERE/patch-markers.txt" >"$OUT/patches.txt" 2>&1
R PATCHES "$(sed -n 's/^PATCHES=//p' "$OUT/patches.txt")"
while read -r reason; do fail "$reason"; done < <(sed -n 's/^FAIL //p' "$OUT/patches.txt")

# ----------------------------------------------------------- in-page checks ---
cdp() { [ -n "${CDP_PORT:-}" ] && timeout 30 python3 "$HERE/cdp.py" "$CDP_PORT" "$@" 2>>"$OUT/cdp.log"; }
CDP_OK=no
cdp url >/dev/null && CDP_OK=yes
R CDP "$CDP_OK"
[ -n "${CDP_PORT:-}" ] && [ "$CDP_OK" = no ] && warn "DevTools port unreachable: in-page checks skipped (see cdp.log)"
page_is_deezer() { [[ $(cdp url) == https://www.deezer.com/* ]]; }

if [ "$CDP_OK" = yes ]; then
	UA=$(cdp eval 'navigator.userAgent' | tr -d '"')
	R USER_AGENT "$UA"
	R ELECTRON "$(grep -oE 'Electron/[0-9.]+' <<<"$UA" | cut -d/ -f2)"
	# Patch 04: the API rejects non-semver kernels (e.g. 6.8.0-45-generic) unless --keep-kernel.
	if ! has_arg --keep-kernel && [[ $UA == *"; linux/"* ]] && ! grep -q '; linux/6\.4\.0;' <<<"$UA"; then
		fail "user agent leaks the kernel version (patch 04): $UA"
	fi

	# Notifications: the app's own path is the page's Notification API -> libnotify.
	: >>"$OUT/notify.log"
	before=$(wc -l <"$OUT/notify.log")
	# With --disable-notifications (patch 10), Chromium removes the Notification API altogether.
	cdp eval '(async () => {
		if (typeof Notification === "undefined") return "none unavailable";
		const icon = (() => { const c = document.createElement("canvas"); c.width = c.height = 64;
			const g = c.getContext("2d"); g.fillStyle = "#a238ff"; g.fillRect(0, 0, 64, 64); return c.toDataURL(); })();
		const n = new Notification("deezer-linux smoke test", { body: "notification check", icon, silent: true });
		// Chromium fires "show" once the desktop took it, "error" when it refused it.
		const event = await new Promise((r) => { n.onshow = () => r("show"); n.onerror = () => r("error");
			n.onclose = () => r("close"); setTimeout(() => r("none"), 10000); });
		return Notification.permission + " " + event; })()' | tr -d '"' >"$OUT/notify-permission.txt"
	NOTIFY_EVENT=$(awk '{ print $2 }' "$OUT/notify-permission.txt")
	R NOTIFY_EVENT "${NOTIFY_EVENT:-none}"
	notified() { [ "$(wc -l <"$OUT/notify.log")" -gt "$before" ]; }
	# "show" comes once the Notify call was answered: the probe has seen it by then, or will in a moment.
	[ "$NOTIFY_EVENT" = show ] && wait_for notification 10 notified
	NOTIFS=$(tail -n +"$((before + 1))" "$OUT/notify.log")
	R NOTIFY_COUNT "$(grep -c . <<<"$NOTIFS")"
	# monitor: watched a real notification server; server: the probe had to be the server itself.
	NOTIFY_PROBE=$(grep -m1 -oE '^NOTIFY_(MONITOR|SERVER)_READY' "$OUT/notify-probe.log" | cut -d_ -f2 | tr '[:upper:]' '[:lower:]')
	R NOTIFY_PROBE "${NOTIFY_PROBE:-none}"
	[ "$DISPLAY_MODE" = host ] && [ "$NOTIFY_PROBE" = server ] &&
		warn "no notification server in this desktop session: the probe answered the app itself"
	if has_arg --disable-notifications; then
		{ [ -n "$NOTIFS" ] || [ "$NOTIFY_EVENT" != unavailable ]; } &&
			fail "the page can still send notifications although --disable-notifications is set (patch 10): ${NOTIFY_EVENT:-no answer}"
	elif [ -z "$NOTIFS" ]; then
		fail "no notification reached org.freedesktop.Notifications (permission: $(cat "$OUT/notify-permission.txt"))"
	else
		N=$(head -1 <<<"$NOTIFS")
		nget() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$N" "$1"; }
		R NOTIFY_APP_NAME "$(nget app_name)"
		NOTIFY_DESKTOP_ENTRY=$(nget desktop_entry)
		R NOTIFY_DESKTOP_ENTRY "$NOTIFY_DESKTOP_ENTRY"
		R NOTIFY_IMAGE "$(nget image)"
		NOTIFY_OWN_ICON="$(nget image)$(nget app_icon)"
		[ -z "$NOTIFY_DESKTOP_ENTRY" ] && warn "notifications carry no desktop-entry hint: shells cannot show the app icon"
	fi

	if [ "${FAKE_PORTAL:-0}" = 1 ] && has_arg --sync-theme; then
		# #238: the main process follows the portal color-scheme (dark at start, then light).
		dark() { cdp eval 'matchMedia("(prefers-color-scheme: dark)").matches'; }
		R THEME_DARK_AT_START "$(dark)"
		[ "$(dark)" = true ] || fail "--sync-theme: the page is not dark although the portal says dark"
	fi
fi

if [ "${FAKE_PORTAL:-0}" = 1 ]; then
	pkill -USR1 -f fake_portal.py
	wait_for portal-flip 10 in_log portal.log '^PORTAL_FLIP' || fail "the fake portal did not switch to light"
	R PORTAL_READS "$(grep -c 'PORTAL_Read' "$OUT/portal.log" 2>/dev/null)"
	if [ "$CDP_OK" = yes ] && has_arg --sync-theme; then
		light() { [ "$(dark)" = false ]; }
		wait_for theme-follows-portal 10 light
		R THEME_DARK_AFTER_FLIP "$(dark)"
		[ "$(dark)" = false ] || fail "--sync-theme: the page did not follow the portal switching to light"
	fi
fi

# Taskbar, media controls and notifications must all point at the installed launcher.
probe_args=(--mpris-entry "${MPRIS_DESKTOP_ENTRY:-}" --notify-entry "${NOTIFY_DESKTOP_ENTRY:-}")
{ [ "$WINDOW_BACKEND" != atspi ] || [ -n "${WAYLAND_DEBUG:-}" ]; } && [ -n "$WIN" ] && probe_args+=(--class "$(cut -f2 <<<"$WIN")")
python3 "$HERE/desktop_probe.py" "${probe_args[@]}" >"$OUT/desktop.txt" 2>&1
while IFS='=' read -r k v; do
	case $k in DESKTOP_ID | DESKTOP_ICON_FILE | TASKBAR_LINK | TASKBAR_LINK_BY | MPRIS_LINK | NOTIFY_LINK | NOTIFY_ICON_FILE | DEEPLINK_HANDLER) R "$k" "$v" ;; esac
	[ "$k" = NOTIFY_ICON_FILE ] && [ "$v" != none ] && NOTIFY_OWN_ICON+=$v
done < <(grep -E '^[A-Z_]+=' "$OUT/desktop.txt")
# The notification icon: an image, an app_icon, or the icon of the entry its desktop-entry hint names.
[ -n "${NOTIFY_DESKTOP_ENTRY:-}" ] && [ -z "${NOTIFY_OWN_ICON:-}" ] && ! grep -q '^NOTIFY_LINK=none' "$OUT/desktop.txt" &&
	fail "notifications have no icon: no image, no app_icon, and desktop-entry '$NOTIFY_DESKTOP_ENTRY' resolves to no icon"
while read -r reason; do fail "$reason"; done < <(sed -n 's/^FAIL //p' "$OUT/desktop.txt")
while read -r reason; do warn "$reason"; done < <(sed -n 's/^WARN //p' "$OUT/desktop.txt")

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

# Checks that need the web app (https://www.deezer.com), so a logged-in session.
page_title() {
	cdp eval 'window.dzPlayer?.getCurrentSong?.()?.SNG_TITLE || navigator.mediaSession?.metadata?.title || ""' |
		python3 -c 'import json, sys; print(json.load(sys.stdin) or "")' 2>/dev/null
}
mpris_sync() { # $1 = label: MPRIS metadata must match the page's current song (#250)
	local page mpris
	# Patch 05 polls the page every 250 ms: MPRIS catches up within a few polls, or never.
	in_sync() { page=$(page_title); mpris=$(mpris_title); [ -n "$page" ] && [ "$page" = "$mpris" ]; }
	wait_for "mpris-sync-$1" 10 in_sync
	R "MPRIS_SYNC_$1" "$([ "$page" = "$mpris" ] && echo yes || echo "no (page '$page', mpris '$mpris')")"
	[ "$page" = "$mpris" ] || fail "MPRIS metadata out of sync with the page $1 (#250): page '$page', MPRIS '$mpris'"
}
css_check() { # $1 = flag, $2 = JS returning true when the injected CSS is active
	has_arg "$1" || return 0
	local ok
	ok=$(cdp eval "$2")
	R "CHECK_${1#--}" "$ok"
	[ "$ok" = true ] || fail "$1 has no effect on the page"
}
logged_in_checks() {
	[ "$CDP_OK" = yes ] || return 0
	if ! page_is_deezer; then
		warn "logged in, but the page is $(cdp url): in-page checks skipped"
		return 0
	fi
	[ -n "$MPRIS_NAME" ] && mpris_sync AT_LOAD
	# Patches 07-09 and 16 inject CSS on did-finish-load; probe each with a throwaway element.
	css_check --hide-offline-banner '(() => { const w = document.createElement("div"); w.className = "alert-wrapper";
		w.innerHTML = "<div data-testid=\"alert-AppOffline\"></div>"; document.body.append(w);
		const hidden = getComputedStyle(w).display === "none"; w.remove(); return hidden; })()'
	css_check --disable-animations '(() => { const d = document.createElement("div"); d.style.transition = "opacity 3s";
		document.body.append(d); const off = getComputedStyle(d).transitionDuration === "0s"; d.remove(); return off; })()'
	css_check --custom-theme '!!document.getElementById("dz-custom-theme")'
	if [ "${PLAY:-0}" = 1 ] && [ -n "$MPRIS_NAME" ]; then
		local status
		playing() { [ "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)" = Playing ]; }
		audio_up() { pactl list sink-inputs 2>/dev/null | grep -q 'application.name'; }
		mpris_call Play
		wait_for playing "${PLAY_WAIT:-20}" playing
		status=$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)
		have pactl && [ "$status" = Playing ] && wait_for audio-stream 15 audio_up
		R PLAY_STATUS "$(mpris_get org.mpris.MediaPlayer2.Player PlaybackStatus)"
		R PLAY_TITLE "$(mpris_title)"
		have pactl && R AUDIO_STREAM "$(pactl list sink-inputs 2>/dev/null | grep -m1 'application.name' | cut -d'"' -f2)"
		[ "$status" = Playing ] || warn "playback did not start"
		mpris_sync PLAYING
		mpris_call Pause
	fi
}

# ----------------------------------------------------------------- login ---
read_arl() { grep -E '^[[:space:]]*DEEZER_ARL=' "$1" | tail -1 | cut -d= -f2- | tr -d "\"' \r"; }
startup_login() { # the app's own check at start: yes | no | "" (still running)
	grep -q 'User autolog succeeded, loading' "$OUT/app.log" && { echo yes; return; }
	grep -qE 'User autolog failed|must re-authenticate|loading login page' "$OUT/app.log" && echo no
}
ARL=""
[ -n "${SESSION_FILE:-}" ] && [ -r "$SESSION_FILE" ] && ARL=$(read_arl "$SESSION_FILE")
if [ -n "${SESSION_FILE:-}" ]; then
	R PROFILE_CACHE "${PROFILE_RESTORED:-no}"
	startup_decided() { dead || [ -n "$(startup_login)" ]; }
	wait_for startup-login 30 startup_decided
	if [ "$(startup_login)" = yes ]; then
		LOGGED=yes
		R LOGIN_SOURCE cache
	elif [ -z "$ARL" ]; then
		LOGGED=no
		fail "SESSION_FILE has no DEEZER_ARL"
	elif ! alive; then
		LOGGED=no
	else
		R LOGIN_SOURCE deep-link
		ok_before=$(grep -c 'User autolog succeeded, loading' "$OUT/app.log")
		lines_before=$(wc -l <"$OUT/app.log")
		# A second instance hands the deep link to the running one, like a browser would.
		"${CMD[@]}" "deezer://$DEEP_LINK_HOST/autolog/$ARL" >"$OUT/second-instance.log" 2>&1
		LOGGED=""
		login_decided() {
			[ "$(grep -c 'User autolog succeeded, loading' "$OUT/app.log")" -gt "$ok_before" ] && { LOGGED=yes; return 0; }
			tail -n +"$((lines_before + 1))" "$OUT/app.log" |
				grep -qE 'User autolog failed|must re-authenticate|Arl token is not found' && { LOGGED=no; return 0; }
			dead
		}
		wait_for deep-link-login "${LOGIN_WAIT:-45}" login_decided
	fi
	R LOGGED_IN "${LOGGED:-timeout}"
	[ "$LOGGED" = yes ] || fail "login with the shared session failed (${LOGGED:-timeout})"
	if [ "$LOGGED" = yes ]; then
		# "Page loaded" is did-finish-load, where patches 07-09 and 16 inject their CSS. The player
		# is ready once it has a current track (restored from the account's queue).
		wait_for page-loaded 60 in_log app.log 'Page loaded https://' || fail "the web app did not finish loading"
		player_ready() { [ -n "$(page_title)" ]; }
		wait_for player-ready 30 player_ready || warn "the web player has no current track: the track checks will fail"
		screenshot "$OUT/screenshot-logged-in.png"
		logged_in_checks
	fi
fi
# ----------------------------------------------------------------- close ---
# Closing the window hides it to the tray, or quits with --disable-systray.
[[ " $APP_ARGS " == *" --disable-systray "* ]] && CLOSE=1
if [ "${CLOSE:-0}" = 1 ] && [ -n "$WIN" ] && alive; then
	case $WINDOW_BACKEND in
	xdotool) xdotool windowactivate --sync "$(cut -f1 <<<"$WIN")" key --clearmodifiers alt+F4 ;;
	sway) swaymsg "[con_id=$(cut -f1 <<<"$WIN")] kill" ;;
	gnome) gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval \
		"global.get_window_actors().map((a) => a.meta_window).find((w) => w.get_id() == $(cut -f1 <<<"$WIN"))?.delete(global.get_current_time())" ;;
	*) WIN="" ;;
	esac >/dev/null 2>&1
	if [ -z "$WIN" ]; then
		warn "closing the window is not supported with the $WINDOW_BACKEND backend"
	else
		no_window() { [ -z "$(windows | head -1)" ]; }
		wait_for window-closed 10 no_window || fail "the window is still visible 10 s after closing it"
		if [[ " $APP_ARGS " == *" --disable-systray "* ]]; then
			wait_for app-quits 20 dead
		fi
		# The close handler runs before the window goes away: by now the app either hid the window
		# (nothing logged) or started quitting ("Window All Closed", "App on before quit").
		quitting() { dead || in_log app.log 'Window All Closed|App on before quit'; }
		quitting && R ALIVE_AFTER_CLOSE no || R ALIVE_AFTER_CLOSE yes
		if [[ " $APP_ARGS " == *" --disable-systray "* ]]; then
			alive && fail "app still running after closing its window with --disable-systray"
		else
			quitting && fail "app quit when its window was closed (expected: hide to tray)"
		fi
	fi
fi

# ------------------------------------------------------------------ logs ---
# Drop the Wayland protocol trace (WAYLAND_DEBUG) once the app_id has been read.
[ -n "${WAYLAND_DEBUG:-}" ] && sed -i -E '/^\[ *[0-9]+\.[0-9]+\] /d' "$OUT/app.log"
FATAL_RE='Cannot find module|FATAL:|Failed to connect to Wayland display|Segmentation fault|Zygote process exited|Uncaught Exception|Missing X server'
grep -E "$FATAL_RE" "$OUT/app.log" >"$OUT/fatal.txt" 2>/dev/null
R LOG_FATAL "$(wc -l <"$OUT/fatal.txt")"
[ -s "$OUT/fatal.txt" ] && fail "fatal lines in app.log (see fatal.txt)"

# ---------------------------------------------------------------- verdict ---
R WARNINGS "$(IFS=';'; echo "${WARNINGS[*]}")"
R KNOWN_ISSUES "$(IFS=';'; echo "${KNOWN[*]}")"
R FAILURES "$(IFS=';'; echo "${FAILURES[*]}")"
if [ ${#FAILURES[@]} -gt 0 ]; then R RESULT fail
elif [ ${#KNOWN[@]} -gt 0 ]; then R RESULT known # not working, but already tracked
else R RESULT pass; fi

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
# Save the logged-in profile for the next run (cookies only, no caches). It holds
# the session: it goes to PROFILE_OUT, never to $OUT. A killed app may not have
# flushed its cookie store: keep the previous cache then.
[ "${APP_KILLED:-}" = yes ] && echo "--- the app ignored SIGTERM for 20 s and was killed: session not cached"
if [ "${LOGGED:-}" = yes ] && [ -n "${PROFILE_OUT:-}" ] && [ -n "$PROFILE_BASE" ] && [ "${APP_KILLED:-}" != yes ]; then
	for name in deezer-desktop Deezer; do
		[ -f "$PROFILE_BASE/$name/Cookies" ] || continue
		(umask 077 && tar -cf "$PROFILE_OUT" -C "$PROFILE_BASE" --exclude=Cache --exclude='Code Cache' \
			--exclude=GPUCache --exclude='Service Worker' --exclude=DawnGraphiteCache --exclude=DawnWebGPUCache \
			--exclude='*.log' --exclude=logs "$name") && echo "--- session cached for the next run"
		break
	done
fi
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
have pulseaudio && pulseaudio --kill >/dev/null 2>&1
[ ${#FAILURES[@]} -eq 0 ]

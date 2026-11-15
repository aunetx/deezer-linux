#!/usr/bin/env bash
# Waits until the autologin desktop session is ready, from an ssh login in the
# guest: the session bus and display socket exist, the logind session of the
# expected type is active (unless "any"), and every given bus name has an owner.
# Exits 1 after <max> seconds, listing what is still missing.
# usage: desktop-ready.sh <max-seconds> <wayland|x11|any> [bus name...]
set -u
max=$1 type=$2
shift 2
rt=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus

session_active() { # a graphical session of this user, of the expected type, in the foreground
	local s
	for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'); do
		[ "$(loginctl show-session "$s" -p Name --value)" = "$USER" ] &&
			[ "$(loginctl show-session "$s" -p Type --value)" = "$type" ] &&
			[ "$(loginctl show-session "$s" -p State --value)" = active ] && return 0
	done
	return 1
}
owned() {
	dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus.NameHasOwner string:"$1" 2>/dev/null | grep -q 'boolean true'
}
check() {
	missing=()
	[ -S "$rt/bus" ] || missing+=("session bus")
	case $type in
	wayland) ls "$rt"/wayland-? >/dev/null 2>&1 || missing+=("Wayland socket") ;;
	x11) ls /tmp/.X11-unix/X? >/dev/null 2>&1 || missing+=("X socket") ;;
	any) { ls "$rt"/wayland-? || ls /tmp/.X11-unix/X?; } >/dev/null 2>&1 || missing+=("display socket") ;;
	esac
	[ "$type" = any ] || session_active || missing+=("active $type logind session")
	local n
	for n in "$@"; do owned "$n" || missing+=("$n"); done
	[ ${#missing[@]} -eq 0 ]
}

end=$((SECONDS + max))
until check "$@"; do
	if [ "$SECONDS" -ge "$end" ]; then
		echo "desktop not ready after ${max}s, missing: ${missing[*]}" >&2
		exit 1
	fi
	sleep 1 # poll interval
done
echo "desktop ready after ${SECONDS}s" >&2

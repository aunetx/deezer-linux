#!/usr/bin/env bash
# Container entrypoint (runs as root): install the package, then run the smoke
# test as an unprivileged user on a private display and session bus.
# usage: container-entry.sh <pkg-type> <path>
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TYPE=$1 PKG=$2
export OUT=/out

T0=$(date +%s)
if ! APP=$(APPIMAGE_EXTRACT=1 "$HERE/install.sh" "$TYPE" "$PKG" 2>"$OUT/install.log" | tail -1) || [ -z "$APP" ]; then
	tail -20 "$OUT/install.log" >&2
	printf 'RESULT=fail\nFAILURES=package install failed (see install.log)\n' >"$OUT/result.env"
	exit 1
fi
echo "INSTALL_SECONDS=$(($(date +%s) - T0))" >"$OUT/install.env"

# Unresolved shared libraries = dependencies the package forgot to declare.
BIN=$(readlink -f "$(command -v "${APP%% *}" || echo "${APP%% *}")")
if [ -f "$BIN" ] && file_type=$(head -c 4 "$BIN") && [ "$file_type" = $'\x7fELF' ]; then
	ldd "$BIN" 2>/dev/null | grep 'not found' >"$OUT/missing-libs.txt"
fi

RUN_AS=()
if id tester >/dev/null 2>&1; then
	chown -R tester "$OUT"
	RUN_AS=(runuser -u tester --)
fi
if [ -r /run/secrets/deezer-session.env ]; then
	install -m 600 ${RUN_AS:+-o tester} /run/secrets/deezer-session.env /tmp/session.env
	export SESSION_FILE=/tmp/session.env
fi
# Session cache (host: ~/.cache/deezer-linux-tests/session): a logged-in app profile.
CACHE=/run/secrets/profile-cache
if [ -n "${SESSION_FILE:-}" ] && [ -d "$CACHE" ]; then
	[ -s "$CACHE/profile.tar" ] && install -m 600 ${RUN_AS:+-o tester} "$CACHE/profile.tar" /tmp/profile-in.tar &&
		export PROFILE_IN=/tmp/profile-in.tar
	export PROFILE_OUT=/tmp/profile-out.tar
fi

"${RUN_AS[@]}" env APP="$APP" OUT="$OUT" PROFILE_IN="${PROFILE_IN:-}" PROFILE_OUT="${PROFILE_OUT:-}" "$HERE/smoke.sh"
status=$?
grep -q '^RESULT=' "$OUT/result.env" 2>/dev/null ||
	printf 'RESULT=fail\nFAILURES=smoke test did not run (see run.log)\n' >>"$OUT/result.env"

if [ -s "$OUT/missing-libs.txt" ]; then
	sed -i 's/^RESULT=\(pass\|known\)$/RESULT=fail/' "$OUT/result.env"
	sed -i "s/^FAILURES=\(.*\)$/FAILURES=\1;unresolved libraries: $(awk '{print $1}' "$OUT/missing-libs.txt" | paste -sd,)/" "$OUT/result.env"
	sed -i 's/^FAILURES=;/FAILURES=/' "$OUT/result.env"
	status=1
fi
cat "$OUT/install.env" >>"$OUT/result.env"
if [ -s /tmp/profile-out.tar ] && [ -d "$CACHE" ]; then
	install -m 600 -o "$(stat -c %u "$CACHE")" -g "$(stat -c %g "$CACHE")" /tmp/profile-out.tar "$CACHE/profile.tar"
fi
rm -f /tmp/session.env /tmp/profile-in.tar /tmp/profile-out.tar
exit $status

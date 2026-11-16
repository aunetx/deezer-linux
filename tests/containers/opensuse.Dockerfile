# openSUSE guest. BASE: opensuse/tumbleweed, opensuse/leap...
ARG BASE=opensuse/tumbleweed
FROM ${BASE}
ARG RUNTIME_DEPS=0
RUN zypper --non-interactive install --no-recommends \
      xvfb-run xorg-x11-server-Xvfb openbox xdpyinfo xwininfo xprop xdotool ImageMagick x11vnc \
      sway grim wayvnc xwayland \
      dbus-1 dbus-1-daemon dbus-1-tools python3 python3-gobject \
      pulseaudio pulseaudio-utils procps util-linux xz shadow gawk \
 && zypper clean -a
RUN if [ "$RUNTIME_DEPS" = 1 ]; then zypper --non-interactive install --no-recommends \
      gtk3-tools libgtk-3-0 mozilla-nss libasound2 libgbm1 libXss1 libXtst6 libnotify4 libsecret-1-0 \
      at-spi2-core libdrm2 libxkbcommon0 libcups2 libuuid1 xdg-utils && zypper clean -a; fi
# sway ships with file capabilities (cap_sys_nice) that a container user cannot exec: drop them.
RUN f=$(command -v sway) && cp "$f" /tmp/sway && mv /tmp/sway "$f"
RUN useradd -m tester

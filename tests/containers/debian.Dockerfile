# Ubuntu / Debian guest. BASE: ubuntu:24.04, ubuntu:26.04, debian:12, debian:13...
ARG BASE=ubuntu:24.04
FROM ${BASE}
ARG RUNTIME_DEPS=0
ENV DEBIAN_FRONTEND=noninteractive
# Test tooling only: X11 (Xvfb + openbox), Wayland (headless sway), D-Bus, audio, VNC.
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb openbox x11-utils xdotool imagemagick x11vnc \
      sway grim wayvnc xwayland \
      dbus dbus-x11 python3 python3-gi gir1.2-glib-2.0 \
      pulseaudio pulseaudio-utils procps xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# deb packages pull their own dependencies (that is what we test). Other formats
# (AppImage, tar.xz, unpacked) need the Electron runtime libraries preinstalled.
RUN if [ "$RUNTIME_DEPS" = 1 ]; then apt-get update && apt-get install -y --no-install-recommends \
      libgtk-3-0t64 libnss3 libasound2t64 libgbm1 libxss1 libxtst6 libnotify4 libsecret-1-0 \
      libatspi2.0-0t64 libdrm2 libxkbcommon0 libcups2t64 libuuid1 xdg-utils \
    || apt-get install -y --no-install-recommends \
      libgtk-3-0 libnss3 libasound2 libgbm1 libxss1 libxtst6 libnotify4 libsecret-1-0 \
      libatspi2.0-0 libdrm2 libxkbcommon0 libcups2 libuuid1 xdg-utils; \
    rm -rf /var/lib/apt/lists/*; fi
# sway ships with file capabilities (cap_sys_nice) that a container user cannot exec: drop them.
RUN f=$(command -v sway) && cp "$f" /tmp/sway && mv /tmp/sway "$f"
RUN useradd -m tester

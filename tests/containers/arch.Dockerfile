# Arch Linux guest (x86_64 only). Packages: AppImage, tar.xz, unpacked.
ARG BASE=archlinux:latest
FROM ${BASE}
ARG RUNTIME_DEPS=1
RUN pacman -Syu --noconfirm --needed \
      xorg-server-xvfb openbox xorg-xdpyinfo xorg-xwininfo xorg-xprop xdotool imagemagick x11vnc \
      sway grim wayvnc xorg-xwayland \
      dbus python python-gobject \
      pulseaudio procps-ng xz \
      gtk3 nss alsa-lib libxss libxtst libnotify libsecret at-spi2-core libdrm libxkbcommon libcups xdg-utils \
 && pacman -Scc --noconfirm
# sway ships with file capabilities (cap_sys_nice) that a container user cannot exec: drop them.
RUN f=$(command -v sway) && cp "$f" /tmp/sway && mv /tmp/sway "$f"
RUN useradd -m tester

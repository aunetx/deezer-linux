# Fedora guest. BASE: fedora:latest, fedora:rawhide...
ARG BASE=fedora:latest
FROM ${BASE}
ARG RUNTIME_DEPS=0
RUN dnf -y install --setopt=install_weak_deps=False \
      xorg-x11-server-Xvfb openbox xdpyinfo xwininfo xprop xdotool ImageMagick x11vnc \
      sway grim wayvnc xorg-x11-server-Xwayland \
      dbus-daemon dbus-tools python3 python3-gobject-base \
      pulseaudio pulseaudio-utils procps-ng util-linux xz \
 && dnf clean all
RUN if [ "$RUNTIME_DEPS" = 1 ]; then dnf -y install --setopt=install_weak_deps=False \
      gtk3 nss alsa-lib mesa-libgbm libXScrnSaver libXtst libnotify libsecret at-spi2-core \
      libdrm libxkbcommon cups-libs libuuid xdg-utils && dnf clean all; fi
# sway ships with file capabilities (cap_sys_nice) that a container user cannot exec: drop them.
RUN f=$(command -v sway) && cp "$f" /tmp/sway && mv /tmp/sway "$f"
RUN useradd -m tester

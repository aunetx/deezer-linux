# Nix guest: builds the repo's default.nix (nixpkgs electron wrapping
# artifacts/<arch>/linux*-unpacked) and runs it. Runs as root, with --no-sandbox.
ARG BASE=nixos/nix:latest
FROM ${BASE}
# One environment for the test tooling: xvfb and xwayland both ship lib/xorg/protocol.txt.
COPY <<'NIX' /etc/deezer-test-tools.nix
let p = import <nixpkgs> { }; in
p.buildEnv {
  name = "deezer-test-tools";
  ignoreCollisions = true;
  meta.priority = 4; # win over the base image (procps vs coreutils: uptime)
  paths = with p; [
    xorg.xvfb openbox xorg.xdpyinfo xorg.xwininfo xorg.xprop xdotool imagemagick x11vnc
    sway grim wayvnc xwayland
    dbus procps gnugrep gawk which file pulseaudio
    glib gobject-introspection (python3.withPackages (ps: [ ps.pygobject3 ]))
  ];
}
NIX
RUN nix-channel --update && nix-env -if /etc/deezer-test-tools.nix && nix-collect-garbage -d \
 && mkdir -p /etc/dbus-1 && grep -v /etc/dbus-1/session.conf /root/.nix-profile/share/dbus-1/session.conf >/etc/dbus-1/session.conf && dbus-uuidgen >/etc/machine-id && mkdir -p /tmp
# Typelibs for python3-gi (Gio/GLib), used by the D-Bus stubs.
ENV GI_TYPELIB_PATH=/root/.nix-profile/lib/girepository-1.0 NIXPKGS_ALLOW_UNFREE=1

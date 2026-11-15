# shellcheck shell=bash
# shellcheck disable=SC2054 # QEMU options are comma-separated on purpose
# VM tier: throwaway QEMU VMs (cloud image + cloud-init), with or without a real
# desktop session. Sourced by tests/run.sh, which sets the option variables.

VM_PROFILES="ubuntu-headless ubuntu26-headless fedora-headless ubuntu-gnome ubuntu26-gnome fedora-gnome fedora-kde ubuntu-sway debian-xfce popos-cosmic"
FEDORA_VERSION=${FEDORA_VERSION:-45}

# profile -> "image display-mode native-package memory-MiB sessions [seed]"
# display-mode: x11 = Xvfb inside the VM, host = the VM's own desktop session.
# seed: tests/vm/seeds/<seed>.yaml (default: the profile name).
vm_profile_info() {
	case $1 in
	ubuntu-headless) echo "ubuntu-24.04 x11 deb 3072 x11" ;;
	ubuntu26-headless) echo "ubuntu-26.04 x11 deb 3072 x11 ubuntu-headless" ;;
	fedora-headless) echo "fedora x11 rpm 3072 x11" ;;
	ubuntu-gnome) echo "ubuntu-24.04 host deb 4096 wayland,xwayland,x11" ;;
	ubuntu26-gnome) echo "ubuntu-26.04 host deb 4096 wayland,xwayland ubuntu-gnome" ;; # GNOME 50: no Xorg session
	fedora-gnome) echo "fedora host rpm 4096 wayland,xwayland" ;;
	fedora-kde) echo "fedora host rpm 6144 wayland,xwayland" ;;
	ubuntu-sway) echo "ubuntu-24.04 host deb 3072 wayland,xwayland" ;;
	debian-xfce) echo "debian-13 host deb 3072 x11" ;;
	popos-cosmic) echo "ubuntu-24.04 host deb 4096 wayland,xwayland" ;; # Pop!_OS 24.04 repos on Ubuntu 24.04
	*) return 1 ;;
	esac
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

vm_key() {
	local key=$CACHE_DIR/id_ed25519
	[ -f "$key" ] || { mkdir -p "$CACHE_DIR"; ssh-keygen -q -t ed25519 -N '' -C deezer-linux-tests -f "$key"; }
	echo "$key"
}

# Downloads (once) the newest cloud image matching images.conf.
vm_image() { # $1 = image name, $2 = arch
	local url regex file dest f
	read -r _ _ url regex < <(awk -v n="$1" -v a="$2" '$1 == n && $2 == a' "$TESTS_DIR/vm/images.conf")
	[ -n "${url:-}" ] || die "no $1 image for $2 in tests/vm/images.conf"
	url=${url//@FEDORA@/$FEDORA_VERSION}
	mkdir -p "$CACHE_DIR/images"
	dest=""
	for f in "$CACHE_DIR/images/"*; do [[ ${f##*/} =~ ^$regex$ ]] && dest=${f##*/}; done
	if [ -z "$dest" ]; then
		file=$(curl -fsSL "$url" | grep -oE "$regex" | sort -Vu | tail -1)
		[ -n "$file" ] || die "no file matching '$regex' at $url"
		log "downloading $file (once, cached in $CACHE_DIR/images)"
		local progress=-sS
		[ -t 2 ] && progress=--progress-bar
		curl -fL "$progress" -o "$CACHE_DIR/images/$file.part" "$url$file"
		mv "$CACHE_DIR/images/$file.part" "$CACHE_DIR/images/$file"
		dest=$file
	fi
	echo "$CACHE_DIR/images/$dest"
}

# Boots a disk image in the background. Sets VM_SSH_PORT, VM_QMP, VM_VNC, VM_DIR.
vm_boot() { # $1 = backing image, $2 = seed iso, $3 = memory MiB, $4 = run dir
	local base=$1 seed=$2 mem=$3 fmt
	VM_DIR=$4
	mkdir -p "$VM_DIR"
	fmt=$(qemu-img info --output=json "$base" | python3 -c 'import json, sys; print(json.load(sys.stdin)["format"])')
	qemu-img create -q -f qcow2 -F "$fmt" -b "$base" "$VM_DIR/disk.qcow2" 30G
	VM_SSH_PORT=$(free_port)
	VM_QMP=$VM_DIR/qmp.sock
	VM_VNC=""
	local vnc=(-display none) machine
	if [ "$VNC" = 1 ] || [ "$HOLD" != 0 ]; then
		VM_VNC=$(($(free_port) % 90 + 10))
		vnc=(-display none -vnc "127.0.0.1:$VM_VNC")
	fi
	local common=(-smp "${VM_CPUS:-4}" -m "$mem"
		-drive "file=$VM_DIR/disk.qcow2,if=virtio,discard=unmap"
		-drive "file=$seed,if=virtio,format=raw,readonly=on"
		-nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22"
		-device qemu-xhci -device usb-kbd -device usb-tablet
		-qmp "unix:$VM_QMP,server=on,wait=off" -serial "file:$VM_DIR/serial.log"
		-pidfile "$VM_DIR/qemu.pid" -daemonize "${vnc[@]}")
	if [ "$ARCH" = x64 ]; then
		need qemu-system-x86_64
		if [ -w /dev/kvm ] && [ "$(host_arch)" = x64 ]; then machine=(-machine q35,accel=kvm -cpu host); else
			warn "no KVM: the VM will be very slow"
			machine=(-machine q35,accel=tcg -cpu max)
		fi
		qemu-system-x86_64 "${machine[@]}" -device virtio-vga "${common[@]}"
	else
		need qemu-system-aarch64
		local fw
		for fw in /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd /usr/share/AAVMF/AAVMF_CODE.fd \
			/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw /usr/share/qemu/edk2-aarch64-code.fd; do
			[ -f "$fw" ] && break
		done
		[ -f "$fw" ] || die "no aarch64 UEFI firmware (install qemu-efi-aarch64 / edk2-aarch64)"
		truncate -s 64M "$VM_DIR/vars.fd"
		if [ -w /dev/kvm ] && [ "$(host_arch)" = arm64 ]; then machine=(-machine virt,accel=kvm -cpu host); else
			warn "emulating arm64 without KVM (TCG): expect 10+ minutes per run"
			machine=(-machine virt,accel=tcg,gic-version=3 -cpu cortex-a72)
		fi
		qemu-system-aarch64 "${machine[@]}" -device virtio-gpu-pci \
			-drive "if=pflash,format=raw,readonly=on,file=$fw" -drive "if=pflash,format=raw,file=$VM_DIR/vars.fd" \
			"${common[@]}"
	fi
}

VM_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	-o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=5 -o BatchMode=yes)
vm_ssh() { ssh "${VM_SSH_OPTS[@]}" -i "$(vm_key)" -p "$VM_SSH_PORT" tester@127.0.0.1 "$@"; }
vm_scp_to() { scp -q -r "${VM_SSH_OPTS[@]}" -i "$(vm_key)" -P "$VM_SSH_PORT" "$1" "tester@127.0.0.1:$2"; }
vm_scp_from() { scp -q -r "${VM_SSH_OPTS[@]}" -i "$(vm_key)" -P "$VM_SSH_PORT" "tester@127.0.0.1:$1" "$2"; }
vm_qmp() { python3 -I "$TESTS_DIR/lib/qmp.py" "$VM_QMP" "$@"; }

vm_wait_ssh() {
	local _i
	for _i in $(seq "${1:-300}"); do
		vm_ssh true 2>/dev/null && return 0
		kill -0 "$(cat "$VM_DIR/qemu.pid" 2>/dev/null)" 2>/dev/null || die "QEMU exited (see $VM_DIR/serial.log)"
		sleep 2
	done
	die "no SSH after $((${1:-300} * 2))s (see $VM_DIR/serial.log)"
}

vm_stop() {
	[ -n "${VM_QMP:-}" ] && [ -S "$VM_QMP" ] && vm_qmp quit 2>/dev/null
	sleep 1
	return 0
}

# Provisions a profile once (cloud-init: packages, desktop, autologin) and keeps
# the result as a cached disk image, so later runs boot straight to the desktop.
vm_profile_image() { # $1 = profile, $2 = image name, $3 = memory, $4 = seed
	local golden=$CACHE_DIR/profiles/$1-$ARCH.qcow2 seed=$CACHE_DIR/profiles/$1-$ARCH-seed.iso
	if [ -f "$golden" ] && [ "${VM_FRESH:-0}" != 1 ]; then echo "$golden"; return; fi
	need qemu-img ssh scp
	local base tmp
	base=$(vm_image "$2" "$ARCH")
	tmp=$(mktemp -d "$CACHE_DIR/provision.XXXX")
	mkdir -p "$CACHE_DIR/profiles"
	{
		cat <<EOF
#cloud-config
users:
  - name: tester
    groups: [sudo, wheel, video, audio, input]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: tester
    ssh_authorized_keys: ["$(cat "$(vm_key).pub")"]
ssh_pwauth: false
EOF
		cat "$TESTS_DIR/vm/seeds/${4:-$1}.yaml"
	} >"$tmp/user-data"
	printf 'instance-id: %s\nlocal-hostname: %s\n' "deezer-$1" "deezer-$1" >"$tmp/meta-data"
	local iso
	for iso in genisoimage mkisofs xorrisofs; do have "$iso" && break; done
	have "$iso" || die "genisoimage, mkisofs or xorriso is required to build the cloud-init seed"
	"$iso" -quiet -output "$seed" -volid cidata -joliet -rock "$tmp/user-data" "$tmp/meta-data"
	log "provisioning $1 ($ARCH), first run only: a few minutes"
	trap 'vm_stop; rm -rf "$tmp"' EXIT
	vm_boot "$base" "$seed" "$3" "$tmp/vm"
	vm_wait_ssh 300
	vm_ssh 'sudo cloud-init status --wait >/dev/null; sudo cloud-init status --long' | tail -3 >&2
	vm_ssh 'sudo poweroff' 2>/dev/null || true
	local _i
	for _i in $(seq 60); do kill -0 "$(cat "$tmp/vm/qemu.pid" 2>/dev/null)" 2>/dev/null || break; sleep 1; done
	qemu-img convert -O qcow2 "$tmp/vm/disk.qcow2" "$golden.part" && mv "$golden.part" "$golden"
	rm -rf "$tmp"
	trap - EXIT
	echo "$golden"
}

# Waits until the autologin session is up (session bus + Wayland or X socket).
vm_wait_desktop() {
	local _i
	for _i in $(seq 90); do
		vm_ssh 'r=/run/user/$(id -u); [ -S $r/bus ] && { ls $r/wayland-? || ls /tmp/.X11-unix/X?; } >/dev/null 2>&1' && {
			sleep "${DESKTOP_SETTLE:-10}"
			return 0
		}
		sleep 2
	done
	vm_qmp screendump "$OUT/no-desktop.png"
	die "the desktop session did not start (screenshot: $OUT/no-desktop.png)"
}

vm_main() {
	local image display native mem sessions seed
	read -r image display native mem sessions seed <<<"$(vm_profile_info "$PROFILE")" ||
		die "unknown profile '$PROFILE' (one of: $VM_PROFILES)"
	PKG=${PKG:-$native}
	SESSION=${SESSION:-$([ "$display" = x11 ] || [ "$sessions" = x11 ] && echo x11 || echo wayland)}
	[[ ",$sessions," == *",$SESSION,"* ]] || die "$PROFILE supports sessions: $sessions"
	resolve_pkg_file
	need qemu-img ssh scp python3 curl
	[ "$LOGIN" = 1 ] && SESSION_SRC=$(resolve_session)

	local golden
	golden=$(vm_profile_image "$PROFILE" "$image" "$mem" "$seed")
	OUT=${OUT:-$(new_out_dir vm "$PROFILE" "$PKG" "$SESSION")}
	log "vm: $PROFILE ($ARCH) / $PKG / $SESSION ($(basename "$FILE")) -> $OUT"
	vm_boot "$golden" "$CACHE_DIR/profiles/$PROFILE-$ARCH-seed.iso" "$mem" "$(mktemp -d "$CACHE_DIR/run.XXXX")"
	# shellcheck disable=SC2064 # expand now: these are this run's paths
	trap "vm_stop; rm -rf '$VM_DIR'; cleanup_session" EXIT
	vm_wait_ssh 150

	# Session flavour, decided at run time on top of the cached image.
	local app_args=$APP_ARGS
	case $PROFILE/$SESSION in
	ubuntu-gnome/x11) vm_ssh 'sudo sed -i "s/^WaylandEnable=.*/WaylandEnable=false/" /etc/gdm3/custom.conf && sudo systemctl restart gdm3' ;;
	*/xwayland) app_args="--ozone-platform=x11 $app_args" ;;
	*/wayland) [ "$display" = host ] && app_args="--ozone-platform=wayland $app_args" ;;
	esac
	[ "$display" = host ] && vm_wait_desktop

	log "installing $(basename "$FILE")"
	vm_ssh 'rm -rf /tmp/dz && mkdir -p /tmp/dz/out'
	vm_scp_to "$GUEST_DIR" /tmp/dz/tests
	if [ "$PKG" = unpacked ]; then vm_scp_to "$FILE" /tmp/dz/pkg; else vm_scp_to "$FILE" "/tmp/dz/$(basename "$FILE")"; fi
	local guest_pkg
	guest_pkg=/tmp/dz/$(basename "$FILE")
	[ "$PKG" = unpacked ] && guest_pkg=/tmp/dz/pkg
	local app
	app=$(vm_ssh "SUDO=sudo /tmp/dz/tests/install.sh $PKG '$guest_pkg' 2>/tmp/dz/out/install.log | tail -1") || {
		vm_scp_from /tmp/dz/out/install.log "$OUT/" || true
		die "install failed, see $OUT/install.log"
	}
	local smoke_env="APP='$app' OUT=/tmp/dz/out DISPLAY_MODE=$display APP_ARGS='$app_args' WAIT=$WAIT HOLD=0 PLAY=$PLAY FAKE_PORTAL=$PORTAL CLOSE=$CLOSE"
	[ "$display" = host ] && smoke_env+=" LAUNCHER=systemd"
	if [ "$LOGIN" = 1 ]; then
		vm_scp_to "$SESSION_SRC" /tmp/dz/session.env
		vm_ssh 'chmod 600 /tmp/dz/session.env'
		smoke_env+=" SESSION_FILE=/tmp/dz/session.env PROFILE_OUT=/tmp/dz/profile-out.tar"
		local cache
		cache=$(session_cache_dir)
		if [ -s "$cache/profile.tar" ]; then
			vm_scp_to "$cache/profile.tar" /tmp/dz/profile-in.tar
			smoke_env+=" PROFILE_IN=/tmp/dz/profile-in.tar"
		fi
	fi

	log "running the smoke test"
	vm_ssh "$smoke_env /tmp/dz/tests/smoke.sh" >"$OUT/run.log" 2>&1 || true
	vm_qmp screendump "$OUT/vm-screen.png" || true
	if [ "$LOGIN" = 1 ] && vm_ssh 'test -s /tmp/dz/profile-out.tar'; then
		(umask 077 && vm_scp_from /tmp/dz/profile-out.tar "$(session_cache_dir)/profile.tar") || true
	fi
	vm_ssh 'rm -f /tmp/dz/session.env /tmp/dz/profile-in.tar /tmp/dz/profile-out.tar'
	vm_scp_from '/tmp/dz/out/*' "$OUT/" || true
	scrub_out "$OUT" "$SESSION_SRC"

	if [ "$HOLD" != 0 ]; then
		log "VM kept running. Ctrl+C (or 'exit' in the shell) destroys it."
		echo "  ssh:  ssh -i $(vm_key) -p $VM_SSH_PORT -o StrictHostKeyChecking=no tester@127.0.0.1   (password: tester)" >&2
		echo "  vnc:  vncviewer 127.0.0.1:$VM_VNC" >&2
		echo "  app:  $smoke_env /tmp/dz/tests/smoke.sh" | sed 's/SESSION_FILE=[^ ]*//; s/PROFILE_[A-Z]*=[^ ]*//g' >&2
		if [ "$HOLD" = shell ]; then
			ssh -t "${VM_SSH_OPTS[@]}" -i "$(vm_key)" -p "$VM_SSH_PORT" tester@127.0.0.1 || true
		else
			sleep infinity || true
		fi
	fi
	verdict "$OUT"
}

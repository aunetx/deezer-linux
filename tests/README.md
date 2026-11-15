# Cross-environment tests

`tests/run.sh` installs a deezer-linux package in a throwaway environment, launches it, checks that it behaves, and writes logs, screenshots and a verdict. One command covers distros (Ubuntu, Debian, Fedora, openSUSE, Arch, Nix), sessions (X11, Wayland, Xwayland), desktops (GNOME, KDE, Sway, XFCE), package formats and both architectures.

| Tier          | Where the app runs                                              | Good for                                                    | Speed          |
| ------------- | --------------------------------------------------------------- | ----------------------------------------------------------- | -------------- |
| `container`   | Docker/Podman, headless Xvfb or sway                            | deb, rpm, AppImage, tar.xz, unpacked, nix; X11/Wayland/Xwayland | ~30 s per run   |
| `vm`          | QEMU VM from a cloud image, headless or with a real desktop     | snap, flatpak, GNOME/KDE/Sway/XFCE/COSMIC sessions, real tray | ~1–2 min (first run of a profile: +5–15 min) |
| `host`        | this machine, in your current session                           | Raspberry Pi, NixOS, your own desktop                        | ~20 s           |
| `unit`        | the host, no app needed                                         | packaging metadata, patches, documented fixes, the tooling   | ~1 s            |

Ubuntu 24.04 and 26.04 run in every tier: containers (`-d ubuntu-24.04|ubuntu-26.04`, any session), VMs (`ubuntu-headless`, `ubuntu-gnome`, `ubuntu26-headless`, `ubuntu26-gnome`) and the host. `popos-cosmic` is Ubuntu 24.04 with the COSMIC desktop from the Pop!_OS repository (#156).

## What gets checked

Each run produces a `result.env` with:

- **Process**: the app starts and stays alive, with no fatal log lines (missing modules, Wayland connection failures, segfaults, zygote crashes).
- **Window**: it appears, how long that takes (a warning above 5 s), and its X11 class or Wayland `app_id`, which must be `dev.aunetx.deezer` (c093311). On GNOME/KDE Wayland, where AT-SPI has no `app_id`, it is read from the Wayland protocol (`WAYLAND_DEBUG`).
- **Taskbar / dock linking** (#156, #229): an installed desktop entry must match the window, by file name (`<app_id>.desktop`) or `StartupWMClass`. Its `Icon` must resolve in an icon theme, and it must handle `deezer://` links.
- **MPRIS**: the bus name is `org.mpris.MediaPlayer2.deezer`, with the right `Identity` and a `DesktopEntry` that names an installed desktop file. Without that file, GNOME's media controls show a generic icon (#189).
- **Tray**: the app registers a StatusNotifierItem, and its icon resolves for a host outside the sandbox: a pixmap, or a file the host can read (a9aad21, snap). A stub watcher stands in when there is no panel.
- **Notifications**: a test notification is sent from the page and captured on the bus, through a stub server, or a monitor when a real one runs. It must carry an icon: an image, an `app_icon`, or a `desktop-entry` hint naming an installed entry whose icon resolves (#189). With `--disable-notifications`, nothing may be sent.
- **Patches**: each of the 16 patches leaves a marker (`lib/guest/patch-markers.txt`) in the `app.asar` that the running process opened.
- **Page** (over the DevTools protocol): the user agent hides the kernel version, `linux/6.4.0`, unless `--keep-kernel` is set. With `--sync-theme --portal`, `prefers-color-scheme` follows the portal, including a live dark → light switch (#238).
- **Packaging**: no unresolved libraries in `ldd`, and how long the install took.
- **Patched features**:
  - `--start-in-tray`: no window appears.
  - `--disable-systray`, or `--close`: closing the window quits the app, or hides it to the tray.
- **Logged in**, with `--login` and `--play`:
  - Autologin succeeds.
  - The page's current track matches the MPRIS title at load and while playing (#250).
  - MPRIS `Play` starts playback and an audio stream.
  - `--hide-offline-banner`, `--disable-animations` and `--custom-theme` take effect in the page. `--args "--custom-theme=@TESTS@/test-theme.css"` uses the theme shipped with the tests, because `@TESTS@` expands to the guest's test directory.

`tests/run.sh unit` runs fast checks on the repository itself, with no package or app needed:

- the desktop identity (`appId`, `desktopName`, `StartupWMClass`, scheme handler);
- the Flatpak permissions (#271);
- the snap and Flatpak `TMPDIR`;
- the Electron version;
- every patch adds its marker;
- the documented fixes are still present (#250 polling, #238 portal, log level, scoped CSS, isolated custom theme);
- patch 04's kernel-version logic, executed with node;
- redaction of the lines the app really logs;
- the desktop-linking rules;
- every matrix line names a known distro, profile and session.

## Host requirements

Install only the tiers you use. `tests/run.sh doctor` shows what is missing.

| Tier                        | Debian / Ubuntu                                                         | Fedora                                                       |
| --------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------ |
| all                         | `bash python3 curl`                                                     | `bash python3 curl`                                          |
| `container`                 | `docker.io` (or `podman`)                                               | `podman` (or `moby-engine`)                                  |
| `container -a arm64` on x64 | `qemu-user-binfmt`                                                      | `qemu-user-static`                                           |
| `vm`                        | `qemu-system-x86 qemu-utils genisoimage openssh-client`, and be in the `kvm` group | `qemu-kvm qemu-img genisoimage openssh-clients`, and be in the `kvm` group |
| `vm -a arm64`               | `qemu-system-arm qemu-efi-aarch64`                                      | `qemu-system-aarch64 edk2-aarch64`                           |
| `host`                      | `python3-gi dbus xdotool imagemagick` (X11), or `grim` (wlroots), or `gir1.2-atspi-2.0` (GNOME/KDE Wayland) | `python3-gobject xdotool ImageMagick`, `grim`, `at-spi2-core` |

The VM tier caches cloud images, an SSH key and provisioned profile disks in `~/.cache/deezer-linux-tests`. Override the location with `DEEZER_TEST_CACHE`. It needs about 3 GB per desktop profile.

## Quick start

```sh
tests/run.sh fetch                                # latest release packages → artifacts/<arch>/ (or build them)
tests/run.sh container                            # Ubuntu 24.04, .deb, X11
tests/run.sh container -d fedora -s wayland       # Fedora, .rpm, headless sway
tests/run.sh container -d arch -p appimage -s xwayland
tests/run.sh vm -P ubuntu-gnome -s wayland        # real GNOME session, AppIndicator tray
tests/run.sh vm -P ubuntu-headless -p snap
tests/run.sh host                                 # the installed app, in your session
tests/run.sh matrix                               # everything in tests/matrix.txt, then a report
tests/run.sh report                               # Markdown table of tests/out/, ready to paste into an issue
```

`tests/run.sh help` lists every option, and `tests/run.sh list` lists the distros, VM profiles and sessions. By default each run tests the newest matching package in `artifacts/<arch>/`. Pass `-f path/to/package` to test a different file.

The command exits non-zero on failure. Results go in `tests/out/<timestamp>-<environment>/`:

| File                                   | Content                                                    |
| -------------------------------------- | ---------------------------------------------------------- |
| `result.env`                           | every check, plus `RESULT`, `FAILURES` and `WARNINGS`      |
| `app.log`, `fatal.txt`                 | app output, at `--log-level=debug`                         |
| `screenshot.png`, `vm-screen.png`      | the display at the end of the run                          |
| `env.txt`, `install.log`, `missing-libs.txt` | guest environment, install output, unresolved libraries |
| `compositor.log`, `wm.log`, `sni.log`, `run.log` | display server, tray stub and runner output        |

## Logged-in tests

All guests share a single session provided by the host: the `arl` cookie of a Deezer account.

1. **Use a dedicated test account.** The cookie gives full access to that account.
2. Put the cookie in `tests/session.env` with mode 600. Two ways to do it:
   - `tests/run.sh session import-firefox` copies the cookie from a Firefox profile where you are logged in to deezer.com.
   - Or do it by hand: `cp tests/session.env.example tests/session.env && chmod 600 tests/session.env`, then paste the cookie. In the browser devtools, open Storage (or Application), then Cookies, then `https://www.deezer.com`, then `arl`.
3. Check the session with `tests/run.sh session check`. It prints the account id and offer.
4. Run with `--login`, or with `--play` to also check playback:

   ```sh
   tests/run.sh container -d fedora --login
   ```

How the session is handled:

- The session file can live in `tests/session.env`, in `~/.config/deezer-linux-tests/session.env`, or wherever `DEEZER_SESSION_FILE` points. In CI, set the `DEEZER_ARL` secret instead.
- The file is mounted read-only into containers, or copied over SSH into VMs and deleted after the run. It is never passed as a command-line argument or an environment variable.
- The guest logs in through the app's own deep link, `deezer://…/autolog/<arl>`.
- Before you see the output, the `arl` and anything that looks like a token (JWTs, `sid`, `autolog/…`) are redacted. The run fails if the literal value is still present anywhere under `tests/out/`.
- `tests/session.env` and `tests/out/` are git-ignored. Even so, read a log before you attach it to a public issue.

### Logging in as rarely as possible

Logging in again on every run looks like abuse to Deezer, so a run logs in through the deep link only once. After that, runs reuse the profile:

- After a successful logged-in run, the app's profile is saved without caches or logs to `~/.cache/deezer-linux-tests/session/profile.tar` (directory mode 700, file mode 600). It never goes under `tests/out/`.
- The next `--login` run restores that profile before starting the app, in containers and VMs alike. The app then logs in by itself from its cookies, like a desktop app that was already logged in. `result.env` records `LOGIN_SOURCE=cache` in that case, and `deep-link` when the deep link had to be used.
- Runs use `--password-store=basic`, so the cookies can be decrypted in another guest.
- `tests/run.sh session forget` deletes the cached profile. Do this after changing account. Snap is not supported: it always uses the deep link.

## Debugging

| Option     | Effect                                                                                       |
| ---------- | -------------------------------------------------------------------------------------------- |
| `--keep`   | Keep the app, display or VM running after the checks. Press Ctrl+C to tear down.            |
| `--shell`  | Same as `--keep`, but opens a shell inside the container or VM instead.                      |
| `--vnc`    | Watch the display. Containers use `vncviewer 127.0.0.1:5900`. VMs print their port.          |
| `--wait N` | Wait longer for the window, which helps on slow emulated arm64.                              |

For VMs, `--keep` also prints the SSH command (user and password `tester`) and the exact smoke-test command line, so you can re-run it by hand inside the VM. To re-provision a VM profile from scratch, set `VM_FRESH=1`.

## Raspberry Pi and arm64

There are three options:

- **On the Pi itself.** This is the most realistic: labwc, Wayfire or X11, real GPU, see #278. Install a package, then run `tests/run.sh host`. Host mode uses the real profile, so close the app first and do not use `--login` with your personal account. You can also test a single package with `tests/run.sh host -p appimage -f ./deezer-desktop-*-arm64.AppImage`.
- **On an arm64 machine.** Containers and VMs run natively: `tests/run.sh container -d debian-13 -s wayland`.
- **On x64.** Emulation works but is slow: `tests/run.sh container -a arm64 …` uses qemu-user, and `vm -a arm64` uses TCG. Expect minutes per run, and pass `--wait 120`.

## Nix

`tests/run.sh container -d nix` builds the repo's `default.nix`, which runs nixpkgs' electron with `artifacts/<arch>/linux*-unpacked`, and tests the result. The unpacked build must exist first: any `make build_*_<arch>` target leaves it in `artifacts/<arch>/`. On NixOS, install the app (or `nix-build -A deezer-desktop`, then put `result/bin` in `PATH`) and run `tests/run.sh host`.

## Layout

```
tests/
  run.sh                 CLI (host side)
  matrix.txt             default matrix
  session.env.example    shared session template
  containers/*.Dockerfile  per distro family: test tooling, plus runtime deps for portable formats
  vm/images.conf         cloud images for the VM tier
  vm/seeds/*.yaml        cloud-init per VM profile (desktop, autologin, tools)
  lib/common.sh          shared shell helpers: artifacts, session, verdict, redaction
  lib/vm.sh              QEMU orchestration (cloud-init seed, SSH, QMP)
  lib/session.py         session check, and import from Firefox
  lib/qmp.py             QMP client (screendump, keys)
  lib/guest/             runs inside the guest:
    install.sh           installs one package, prints the launch command
    smoke.sh             starts display, bus and app, runs every check, writes result.env
    container-entry.sh   container entrypoint (install, then smoke test as an unprivileged user)
    cdp.py               evaluates JavaScript in the page (DevTools protocol, stdlib only)
    notify_probe.py      notification server or bus monitor that records Notify calls
    tray_probe.py        reads registered tray items and resolves their icons
    desktop_probe.py     desktop entry / taskbar / MPRIS / notification linking
    asar_probe.py        patch markers in the running app.asar
    patch-markers.txt    one marker per patch
    test-theme.css       theme for --custom-theme=@TESTS@/test-theme.css
    *.py                 sway and AT-SPI window probes, fake portal, redaction
  unit/                  `tests/run.sh unit` (python unittest)
```

When a patch is added, add its marker to `lib/guest/patch-markers.txt`. `tests/run.sh unit` fails until you do. To add a distro, add a line to `distro_info` in `lib/common.sh` (with a Dockerfile if it is a new family). To add a desktop, add a seed under `vm/seeds/` and a line to `vm_profile_info` in `lib/vm.sh`.

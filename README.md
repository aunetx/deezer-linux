# Deezer for linux

[![Build](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml/badge.svg)](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/aunetx/deezer-linux)](https://github.com/aunetx/deezer-linux/releases/latest)

This repo is an UNOFFICIAL linux port ([legal notice](#legal-disclaimer)) of the official windows-only Deezer app. Being based on the native Windows app, it allows downloading your songs to listen to them offline!

It packages the app in a number of formats:

- Flatpak, [available on flathub](https://flathub.org/apps/dev.aunetx.deezer)
- AppImage
- Snapcraft
- `rpm` (Fedora, Red Hat, CentOS, openSUSE, ...)
- `deb` (Debian, Ubuntu, Pop!\_OS, elementary OS, ...)
- `tar.xz` to install anywhere else

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=aunetx/deezer-linux&type=date&legend=top-left)](https://www.star-history.com/#aunetx/deezer-linux&type=date&legend=top-left)

Special thanks to [SibrenVasse](https://github.com/SibrenVasse) who made the [original AUR package](https://github.com/SibrenVasse/deezer) for this app!

## Installation

You can find all of the packages on [the release page](https://github.com/aunetx/deezer-linux/releases/latest).

To install the flatpak version, you can simply go to https://flathub.org/apps/dev.aunetx.deezer (or use your favorite flatpak package manager).

Other packages can be installed from your package manager, either by clicking on them or from the command-line.

## Usage

| Option                                                                               | Description                                                                                                                                 |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `--start-in-tray`                                                                    | Start the app in the tray (see [patch](./patches/01-start-in-tray.patch))                                                                   |
| `--disable-systray`                                                                  | Quit the app when the window is closed (see [patch](./patches/02-start-without-tray.patch))                                                 |
| `--keep-kernel`                                                                      | Use the exact kernel version (see [patch](./patches/04-remove-os-information.patch)) <br/> _This feature impacts privacy._                  |
| `--disable-features`                                                                 | Disable some features (see [patch](./patches/05-provide-metadata-mpris.patch))                                                              |
| `--hide-offline-banner`                                                              | Hide the "Application is offline" banner that appears when using a VPN or DNS blocker (see [patch](./patches/08-hide-offline-banner.patch)) |
| `--disable-animations`                                                               | Disable animations (see [patch](./patches/09-disable-animations.patch))                                                                     |
| `--disable-notifications`                                                            | Disable notifications (see [patch](./patches/10-disable-notifications.patch))                                                               |
| `--log-level`                                                                        | Set the log level (`silly`,`debug`,`verbose`,`info`,`warn`,`error`) (see [patch](./patches/06-control-log-level.patch))                     |
| `--enable-wayland-ime` `--ozone-platform-hint=auto` `--wayland-text-input-version=3` | Enable IME keyboard support on Wayland                                                                                                      |

| Environment variable       | Options                                         | Description                                                                                    |
| -------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `DZ_START_IN_TRAY`         | `yes`,`no`                                      | Start the app in the tray (see [patch](./patches/01-start-in-tray.patch))                      |
| `DZ_DISABLE_SYSTRAY`       | `yes`,`no`                                      | Quit the app when the window is closed (see [patch](./patches/02-start-without-tray.patch))    |
| `DZ_KEEP_KERNEL`           | `yes`,`no`                                      | Use the exact kernel version (see [patch](./patches/04-remove-os-information.patch))           |
| `DZ_LOG_LEVEL`             | `silly`,`debug`,`verbose`,`info`,`warn`,`error` | Set the log level (see [patch](./patches/06-control-log-level.patch))                          |
| `DZ_HIDE_OFFLINE_BANNER`   | `yes`,`no`                                      | Hide the "Application is offline" banner (see [patch](./patches/08-hide-offline-banner.patch)) |
| `DZ_DISABLE_ANIMATIONS`    | `yes`,`no`                                      | Disable animations (see [patch](./patches/09-disable-animations.patch))                        |
| `DZ_DISABLE_NOTIFICATIONS` | `yes`,`no`                                      | Disable notifications (see [patch](./patches/10-disable-notifications.patch))                  |
| `DZ_DEVTOOLS`              | `yes`,`no`                                      | Enable the developer console (ctrl+shift+i)                                                    |

## Building from source

### Available targets

| Target   | arm64 | x64 |
| -------- | ----- | --- |
| appimage | ⚠️    | ✅  |
| deb      | ⚠️    | ✅  |
| rpm      | ⚠️    | ✅  |
| tar.xz   | ⚠️    | ✅  |
| snap     | ⚠️    | ✅  |
| flatpak  | ⚠️    | ✅  |

✅ Available ; ⚠️ Not tested ; ❌ Not available ; ⛔ Not planned

> [!NOTE]
> Please open an issue if you want a specific target to be tested or added.

### Requirements

- Node.js (22+ recommended)
- npm (or yarn, see [FAQ](#i-want-to-use-yarn-instead-of-npm-is-it-possible))
- 7z (try installing `p7zip` and `p7zip-full`)
- make
- wget

### Setup

To build the project, you need to install the dependencies first:

```sh
make install_deps
```

> [!NOTE]
> You don't need to use `make install_deps` everytime you start a build, however you need to call it at least once. Everything should be generated in `artifacts/{arch}`.

### AppImage

To build the AppImage x64 image, you can use:

```sh
make build_appimage_x64
```

Artifacts will be generated in `artifacts/x64`.

> [!WARNING]
> You _may_ encounter a problem with the AppImage, where you are not able to login. This is a known issue, and is due to the way AppImage works. In this case, you can copy the link shown in `https://www.deezer.com/desktop/login/electron/callback`.
>
> In the same directory as the AppImage file, use:
>
> ```sh
> deezer-desktop-*.AppImage deezer://autolog/...
> ```
>
> You should now be logged in.
>
> For more information, see [issue #29](https://github.com/aunetx/deezer-linux/issues/29)

> [!Caution]
> If you want to open an issue about this, please do not share your own `deezer://autolog/...` link, as it would allow anyone to log into your account without your consent.

### rpm / deb / tar.xz

To generate the `rpm`/`deb`/`tar.xz` packages, you can use:

```sh
make build_{target}_{arch}
```

Example:

```sh
make build_rpm_arm64
```

Artifacts will be generated in `artifacts/{arch}`.

> [!WARNING]
> Building can take a long time. Be patient.

If you generate the `tar.xz` package, you can run it directly by extracting to a directory, and calling `./deezer-desktop` from there.

### snap

To build the `snap` package, you can use:

```sh
make build_snap_{arch}
```

Then, you can install the package using:

```sh
sudo snap install ./artifacts/{arch}/deezer_desktop_{version}_{arch}.snap --dangerous --classic
```

> [!NOTE]
> Snap packages require classic mode because of electron.
> Because of this, it is not able to use your usual browser.
> It will launch a clean instance of the browser, without extensions, settings, history, etc.

### flatpak

To build the `flatpak` package locally, you need to install `flatpak-builder` first.

```sh
sudo apt install flatpak-builder # Debian/Ubuntu
```

> [!NOTE]
> If you want to build the `arm64` version on an `x64` machine, you also need to install `qemu-user-static` and `binfmt-support` to enable cross-compilation.

Then, you can use:

```sh
make build_flatpak_{arch}
```

To install the generated flatpak, you can use:

```sh
flatpak install --user --reinstall ./artifacts/{arch}/deezer-desktop-{version}-{arch}.flatpak
```

To run it, you can use:

```sh
flatpak run dev.aunetx.deezer
```

## Development

If you want to contribute to this project, please read the [contribution guidelines](CONTRIBUTING.md) file.

## FAQ

### Why does this project exist?

Deezer can be used on Linux through the web interface, but it does not allow downloading songs for offline listening. This project allows you to use the official Deezer app on Linux, with the same features as on Windows (plus some Linux-specific features).

### Why are the patches published but not the app's source code? patches?

The source code of the Deezer app is not open-source. Reverse-engineering the app would be illegal and would violate the Deezer EULA. This project is a port of the official Windows app, and does not contain any reverse-engineered code, rather it bundles the official Windows app with a compatibility layer.

### I want to use yarn instead of npm, is it possible?

Yes, you can use yarn instead of npm. Execute the following command before building the project:

```sh
export PACKAGE_MANAGER=yarn
export PACKAGE_MANAGER_SUBDIR_ARG=--cwd
export PACKAGE_MANAGER_ADD_CMD=add
export PACKAGE_MANAGER_INSTALL_CMD=install
```

### How can I use my IME/virtual keyboard on Deezer under Wayland?

_IME: Input Method Editor. Usually used for languages like Chinese, Japanese, Korean, etc._

You should launch the app with the following arguments:

```sh
--enable-wayland-ime --ozone-platform-hint=auto --wayland-text-input-version=3
```

## **LEGAL DISCLAIMER**

This work is UNOFFICIAL. Deezer does not officially support Linux and cannot be held responsible for any misuse of this port.

The installation and use of this software is outside the scope of the Deezer EULA. No author or contributor to this project can be held responsible for the use you make of it.

> [!NOTE]
> Deezer was contacted to ask for permission to upload this on Flathub, but no answer was given. This work remains unofficial and is not supported by Deezer. See [this thread (FR)](https://fr.deezercommunity.com/application-ordinateur-et-site-web-58/mettre-en-ligne-l-application-deezer-sur-flathub-pour-linux-40620)

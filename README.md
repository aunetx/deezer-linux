# Deezer for linux

[![Build](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml/badge.svg)](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/aunetx/deezer-linux)](https://github.com/aunetx/deezer-linux/releases/latest)

This repo is an UNOFFICIAL linux port ([legal notice](#legal-disclaimer)) of the official windows-only Deezer app. Being based on the native Windows app, it allows downloading your songs to listen to them offline!

It packages the app in a number of formats:

- Flatpak, [available on flathub](https://flathub.org/apps/dev.aunetx.deezer)
- AppImage
- `rpm` (Fedora, Red Hat, CentOS, openSUSE, ...)
- `deb` (Debian, Ubuntu, Pop!\_OS, elementary OS, ...)
- `tar.xz` to install anywhere else

Special thanks to [SibrenVasse](https://github.com/SibrenVasse) who made the [original AUR package](https://github.com/SibrenVasse/deezer) for this app!

## Installation

You can find all of the packages on [the release page](https://github.com/aunetx/deezer-linux/releases/latest).

To install the flatpak version, you can simply go to https://flathub.org/apps/dev.aunetx.deezer (or use your favorite flatpak package manager).

> [!Important]
> Old flatpak users must migrate to the flathub repository as soon as possible, as the flatpak repository was deleted from this repo (it weighed more that 2GB). In order to do so, you can use the following commands:
>
> ```sh
> flatpak uninstall dev.aunetx.deezer
> flatpak remote-delete deezer-linux
> flatpak install flathub dev.aunetx.deezer
> ```
>
> You _should_ not lose any data by doing this.

Other packages can be installed from you package manager, either by clicking on them or from the command-line.

## Usage

| Option                  | Description                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| `--start-in-tray`       | Start the app in the tray (see [patch](./patches/01-start-hidden-in-tray.patch))                |
| `--disable-systray`     | Quit the app when the window is closed (see [patch](./patches/03-quit.patch))                   |
| `--disable-features`    | Disable some features (see [patch](./patches/06-better-management-of-MPRIS.patch))              |
| `--disable-discord-rpc` | Disable Discord RPC integration (see [patch](./patches/08-discord-rich-presence-disable.patch)) |

| Environment variable | Options                                            | Description                                                                        |
| -------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `LOG_LEVEL`          | `silly`,`debug`,`verbose`,`info`,`warning`,`error` | Set the log level (see [patch](./patches/09-log-level-environment-variable.patch)) |
| `DZ_DEVTOOLS`        | `yes`,`no`                                         | Enable the developer console (ctrl+shift+i)                                        |

## Building from source

### Available targets

| Target   | arm64 | x64 |
| -------- | ----- | --- |
| appimage | ⚠️    | ✅  |
| deb      | ⚠️    | ✅  |
| rpm      | ⚠️    | ✅  |
| tar.xz   | ⚠️    | ✅  |
| snap     | ⛔    | ⛔  |

✅ Available ; ⚠️ Not tested ; ❌ Not available ; ⛔ Not planned (see [FAQ](#faq))

> [!NOTE]
> Please open an issue if you want a specific target to be added.

### Requirements

- Node.js (20 recommended)
- npm
- yarn
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

## Development

If you want to contribute to this project, please read the [contribution guidelines](CONTRIBUTING.md) file.

## FAQ

### Why does this project exist?

Deezer can be used on Linux through the web interface, but it does not allow downloading songs for offline listening. This project allows you to use the official Deezer app on Linux, with the same features as on Windows (plus some Linux-specific features).

### Why can't I get the snap package?

Please see [this issue](https://github.com/babluboy/bookworm/issues/178) or [this issue](https://github.com/babluboy/nutty/issues/68). Prefer using Flatpak or AppImage.

### Why not publishing the source code and not patches?

The source code of the Deezer app is not open-source. Reverse-engineering the app would be illegal and would violate the Deezer EULA. This project is a port of the official Windows app, and does not contain any reverse-engineered code, rather it bundles the official Windows app with a compatibility layer.

## Why do I need npm _and_ yarn?

That is a good question. Some kind of legacy choice, I guess.

## **LEGAL DISCLAIMER**

This work is UNOFFICIAL. Deezer does not officially support Linux and cannot be held responsible for any misuse of this port.

The installation and use of this software is outside the scope of the Deezer EULA. No author or contributor to this project can be held responsible for the use you make of it.

> [!NOTE]
> Deezer was contacted to ask for permission to upload this on Flathub, but no answer was given. This work remains unofficial and is not supported by Deezer. See [this thread (FR)](https://fr.deezercommunity.com/application-ordinateur-et-site-web-58/mettre-en-ligne-l-application-deezer-sur-flathub-pour-linux-40620)

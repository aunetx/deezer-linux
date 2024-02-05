# Deezer for linux

**NOTICE:** existing flatpak users NEED to migrate the the flathub repository as soon as possible, as I deleted the flatpak repository from here (it was more than 2Gb in size). In order to do so (normally without losing any data), simply:

```sh
flatpak uninstall dev.aunetx.deezer
flatpak remote-delete deezer-linux
flatpak install flathub dev.aunetx.deezer
```

---

[![Build](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml/badge.svg)](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/aunetx/deezer-linux)](https://github.com/aunetx/deezer-linux/releases/latest)

This repo is an UNOFFICIAL linux port of the official windows-only Deezer app. Being based on the native Windows app, it allows downloading your songs to listen to them offline!

It packages the app in a number of formats:

- Flatpak, [available on flathub](https://flathub.org/apps/dev.aunetx.deezer)
- Snap (not tested yet)
- AppImage (can't automatically login without desktop integration)
- `rpm` (Fedora, Red Hat, CentOS, openSUSE, ...)
- `deb` (Debian, Ubuntu, Pop!_OS, elementary OS, ...)
- `7z` to install anywhere else

It was done thanks to the hard work of [SibrenVasse](https://github.com/SibrenVasse), who [packaged the app for the AUR](https://github.com/SibrenVasse/deezer).

## Installation

You can find all of the packages on [the release page](https://github.com/aunetx/deezer-linux/releases/latest).

To install the flatpak version, you can simply go to https://flathub.org/apps/dev.aunetx.deezer (or use your favorite flatpak package manager). **Old users using this repo as a flatpak repository should migrate as soon as they can toward Flathub.**

Other packages can be installed from you package manager, either by clicking on them or from the command-line.

Please note that even though it is automatically generated, the snapcraft package has never been tested; Please tell me if there is any issue with it!

## From source

You will probably need to install some things in order to generate the packages from source:

- nodejs
- npm
- yarn
- 7z by installing `p7zip` and `p7zip-full`
- make
- wget

### AppImage

To build the AppImage image from source, use:

```sh
make install_deps
make build_appimage
```

And the image should be in the `artifacts/x64` folder.

Because of the way AppImage works, except if you use `appimaged`, you will not be able to login from the browser; then you are not redirected to the application.
To make it work, you must first open a instance of the app, and copy the link shown in `https://www.deezer.com/desktop/login/electron/callback`. In a terminal
(where the .AppImage file is), use:

```sh
deezer-desktop-*.AppImage deezer://autolog/...
```

And you should be automatically logged in.

**IMPORTANT:** If you want to open an issue about this, please do NOT share your own `deezer://autolog/...` link, as it would permit anybody to log into your account without the need for a password!

See [this issue](https://github.com/aunetx/deezer-linux/issues/29) for more informations about login in AppImage.

## rpm / deb / snap / 7z

To generate the `rpm`/`deb`/`snap`/`7z` packages, you can use:

```sh
# prepare the build
make install_deps

# and then

make build_deb_x64
# or
make build_rpm_x64
# or
make build_snap_x64
# or
make build_tar.xz_x64
```

Note that you don't need to use `make install_deps` everytime you start a build, but you need to call it at least once. Everything should be generated in `artifacts/x64`.

If you generate the 7z package, you can run it directly by extracting to a directory, and calling `./deezer-desktop` from there.

## **IMPORTANT NOTICE**

This work is UNOFFICIAL, and Deezer does not officially support Linux yet.

Installing/using this is consequently probably outside of the scope of the Deezer EULA, and I am not responsible for your usage of this.

I ***tried*** to talk to Deezer to ask them if I am authorized to upload this on Flathub, but when they answer, even if they say yes, this work is still unofficial.

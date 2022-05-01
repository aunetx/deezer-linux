# Deezer for linux

[![Build](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml/badge.svg)](https://github.com/aunetx/deezer-linux/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/aunetx/deezer-linux)](https://github.com/aunetx/deezer-linux/releases/latest)

This repo is an UNOFFICIAL linux port of the official windows-only Deezer app. Being based on the windows app, it allows downloading your songs to listen to them offline!

It packages the app in a number of formats:

- Flatpak
- Snap (not tested yet)
- AppImage (can't automatically login without desktop integration)
- `rpm` (Fedora, Red Hat, CentOS, openSUSE, ...)
- `deb` (Debian, Ubuntu, Pop!_OS, elementary OS, ...)
- `7z` to install anywhere else

It was done thanks to the hard work of [SibrenVasse](https://github.com/SibrenVasse), who [packaged the app for the AUR](https://github.com/SibrenVasse/deezer).


## Installation

You can find all of the installation medium in [the release pages](https://github.com/aunetx/deezer-linux/releases/latest).

[The flatpak file,`deezer.flatpakref`](https://github.com/aunetx/deezer-linux/releases/download/v5.30.100-1/deezer.flatpakref), can be installed directly by clicking on it; your package manager's GUI should prompt you to install it.

Other packages can be installed from you package manager, either by clicking on them or from command-line.

Please note that eventhough it is automatically generated, the snapcraft package has never been tested; please tell me if there is any issue with it!

## From source

You will probably need to install some things in order to generate the packages from source: `nodejs` and `npm`, and `yarn` at least; and `flatpak-builder` to build the flatpak version.

### Flatpak

To build it and install it:

```sh
make install_flatpak
```

And when it is installed, you can run it with `flatpak run dev.aunetx.deezer`, or from the desktop icon.

To just build it, but do nothing with it (testing):

```sh
make build_flatpak
```

To build it and install it in the local repo (which you can import later):

```sh
make export_flatpak
```

To build it and create a bundle, which is then installable offline:

```sh
make bundle_flatpak
```

Please not that in order to export the built flatpak image to your local repo or create a bundle, you will need to change `$(GPG_KEY_ID)` in the `Makefile` to use your gpg key.

### AppImage

To build the AppImage image from source, call:

```sh
make install_deps
make build_appimage
```

And the image should be in the `artifacts/x64` folder.

Because of the way AppImage work, excepted if you use `appimaged`, you will not be able to login from the browser: the you are not redirected to the application.
To make it work, you must open a first instance of the app, and copy the link shown in `https://www.deezer.com/desktop/login/electron/callback`. In a terminal
(where the `.AppImage file is), call:

```sh
deezer-desktop-*.AppImage deezer://autolog/...
```

And you should be automatically logged in.

## rpm / deb / snap / 7z

To generate the `rpm`/`deb`/`snap`/`7z` packages, you can call:

```sh
# prepare the build
make install_deps

# and then

make build_deb
# or
make build_rpm
# or
make build_snap
# or
make build_7z
```

Note that you don't need to call `make install_deps` everytime you start a build, but you need to call it at least once. Everything should be generated in `artifacts/x64`.

If you generate the 7z package, you can run it directly by extracting to a directory, and calling `./deezer-desktop` from there.

## **IMPORTANT NOTICE**

This work is UNOFFICIAL, and Deezer does not officially support linux yet.

Installing/using this is consequently outside of the scope of the Deezer EULA, and I am not responsible for your usage of this.

I will try to talk to Deezer to ask them if I can upload this on Flathub, but even if they say yes (which is nearly impossible), this work is still unofficial.

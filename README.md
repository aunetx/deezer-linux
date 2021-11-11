# Deezer for linux

This repo is an UNOFFICIAL linux port of the official windows-only Deezer app. Being based on the windows app, it allows downloading your songs to listen to them offline!

It packages the app in a number of formats:

- Flatpak
- Snap (not tested yet)
- AppImage (can't automatically login without desktop integration)
- `rpm` (Fedora, Red Hat, CentOS, openSUSE, ...)
- `deb` (Debian, Ubuntu, Pop!_OS, elementary OS, ...)
- `tar.gz`/`zip`/`7z` to install anywhere else

It was done thanks to the hard work of [SibrenVasse](https://github.com/SibrenVasse), who [packaged the app for the AUR](https://github.com/SibrenVasse/deezer).

Please note that it is still in alpha stage, and you will probably need to install some things in order to generate the packages from source (`nodejs` and `npm` at least).

## Flatpak

The main point of the project is the flatpak image.

You can install it thanks to [the `flatpakref` file](https://github.com/aunetx/deezer-linux/releases/download/v5.30.80-beta.1/deezer.flatpakref).

To build it from source, you can one of the following commands:

```sh
# To build it and install it
make install_flatpak

# To just build it, but do nothing with it
make build_flatpak

# To build it and install it in the local repo (which you can import later)
make export_flatpak
```

And when it is installed, you can run it with `flatpak run dev.aunetx.deezer`, or from the desktop icon.

## AppImage

This project also generates an AppImage file, which can be used as a stand-alone application.

To use it, you must build it from source for the moment: the package size is randomly big, which prevents me from making a public release.

To generate it from source, call:

```sh
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

## rpm / deb / tar.gz / 7z / zip / snap

To generate the `rpm`/`deb`/`tar.gz`/`7z`/`zip`/`snap` packages, you can call `make build_pkgs`, everything should be generated in `artifacts/x64`.

Please note that generating all at once will take a very long time, and it oddly results in big package sizes for the moment.

The `tar.gz` is not a pacman package by the way, but just an archive containing the executable (like for `7z` and `zip`).
I can't get to generate pacman packages for the moment (throws an error, will investigate later).

To only generate `rpm` or `deb`, call:

```sh
make build_rpm
# or
make build_deb
```

## Wthout package manager

*This will be soon supported, but you can install it by hand with one of the generated `7z`/`zip`/`tar.gz` archive*

## **IMPORTANT NOTICE**

This work is UNOFFICIAL, and Deezer does not officially support linux yet.

Installing/using this is consequently outside of the scope of the Deezer EULA, and I am not responsible for your usage of this.

I will try to talk to Deezer to ask them if I can upload this on Flathub, but even if they say yes (which is nearly impossible), this work is still unofficial.

# Maintainer: Aurélien Hamy <aunetx@yandex.com>

PKGNAME = deezer
PKGVER = 5.30.0
BASE_URL = https://www.deezer.com/desktop/download/artifact/win32/x86/$(PKGVER)
EXE_NAME = $(PKGNAME)-$(PKGVER)-setup.exe

pkg_json_append = '},\
  "scripts": {\
	"dist": "electron-builder",\
	"start": "electron ."\
  },\
  "devDependencies": {\
    "electron": "^13.5.1",\
	"electron-builder": "^22.13.1"\
  },\
  "build": {\
  	"files": [\
      "**"\
    ],\
    "directories": {\
      "buildResources": "build"\
    },\
    "extraResources": [\
      {\
        "from": "../extra/",\
        "to": ".",\
        "filter": [\
          "**"\
        ]\
      }\
    ],\
    "linux": {\
      "maintainer": "aunetx <me@aunetx.dev>",\
      "icon": "../icons",\
      "category": "Utility;AudioVideo;Audio;Player;Music;",\
      "desktop": {\
        "Name": "Deezer",\
        "Type": "Application",\
        "GenericName": "Online music streaming service",\
        "Comment": "Listen and download all your favorite music",\
        "MimeType": "x-scheme-handler/deezer;",\
        "Keywords": "Music;Player;Streaming;Online;"\
      }\
    }\
  }\
}'


install_build_deps:
	npm install --engine-strict asar
	npm install prettier

prepare: install_build_deps
	mkdir -p source
	# Download installer
	wget -c $(BASE_URL) -O source/$(EXE_NAME)
	# Extract app archive from installer
	cd source && 7z x -so $(EXE_NAME) '$$PLUGINSDIR/app-32.7z' > app-32.7z
	# Extract app from app archive
	cd source && 7z x -y -bsp0 -bso0 app-32.7z
	# Extract app sources from the app
	asar extract source/resources/app.asar app

	# Prettier the sources to patch successfully
	prettier --write "app/build/*.js"

	# Apply patches from ./patches, default ones:
	# Hide to tray when closing (https://github.com/SibrenVasse/deezer/issues/4)
	# Start in tray cli option (https://github.com/SibrenVasse/deezer/pull/12)
	$(foreach p, $(wildcard ./patches/*), patch -p1 -dapp < $(p);)

	# Append `pkg_json_append` to the `package.json` of the app
	# Adds electron, elecron-builder dependencies, and build directives
	head -n -2 app/package.json > tmp.txt && mv tmp.txt app/package.json
	echo  $(pkg_json_append) | tee -a app/package.json

prepare_flatpak: prepare
	# Generate npm sources (without installing them)
	npm i --prefix=app --package-lock-only
	# Package the sources to use them in flatpak-builder offline
	./flatpak-node-generator.py npm app/package-lock.json -o flatpak/generated-sources.json --electron-node-headers --xdg-layout

build_flatpak: prepare_flatpak
	# Build the flatpak image
	flatpak-builder --force-clean build dev.aunetx.deezer.yml

export_flatpak: prepare_flatpak
	# Build the flatpak package and export it to the repo
	flatpak-builder --gpg-sign=5A7D3B06F15FB60238941027EB3A799E7EE716EB --repo=repo --force-clean build dev.aunetx.deezer.yml

flatpak_bundle: build_flatpak
	# Create a flatpak bundle
	flatpak build-bundle --gpg-sign=5A7D3B06F15FB60238941027EB3A799E7EE716EB flatpak/repo deezer.flatpak dev.aunetx.deezer

install_flatpak: prepare_flatpak
	# Build and install locally the flatpak image
	flatpak-builder --force-clean --user --install build dev.aunetx.deezer.yml

build_appimage: prepare
	# Install required dependencies to pack them with AppImage
	npm i --prefix=app
	# Build the AppImage package
	npm run dist --prefix=app

run_flatpak:
	flatpak run dev.aunetx.deezer

clean:
	rm -rf app flatpak node_modules source package-lock.json
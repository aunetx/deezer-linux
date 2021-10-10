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
    ]\
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
	
	# Add extra resources to be used at runtime
	mkdir -p extra/linux
	cp source/resources/win/systray.png extra/linux/
	
	# Prettier the sources to patch successfully
	prettier --write "app/build/*.js"
	# Patch hide to tray (https://github.com/SibrenVasse/deezer/issues/4)
	patch -p1 -dapp < quit.patch
	# Add start in tray cli option (https://github.com/SibrenVasse/deezer/pull/12)
	patch -p1 -dapp < start-hidden-in-tray.patch

	# Append `pkg_json_append` to the `package.json` of the app
	# Adds electron, elecron-builder dependencies, and build directives
	head -n -2 app/package.json > tmp.txt && mv tmp.txt app/package.json
	echo  $(pkg_json_append) | tee -a app/package.json


build_flatpak: prepare
	# Generate npm sources (without installing them)
	npm i --prefix=app --package-lock-only
	# Package the sources to use them in flatpak-builder offline
	./flatpak-node-generator.py npm app/package-lock.json -o flatpak/generated-sources.json --electron-node-headers --xdg-layout

	# Build the Flatpak app
	cd flatpak && flatpak-builder build dev.aunetx.deezer.yml --install --force-clean --user


build_appimage: prepare
	# Install required dependencies to pack them with AppImage
	npm i --prefix=app
	# Build the AppImage package
	npm run dist --prefix=app


run_flatpak:
	flatpak run dev.aunetx.deezer


clean:
	rm -rf app extra flatpak/{.flatpak-builder,build} node_modules source app-32.7z app.7z deezer-*.exe package-lock.json
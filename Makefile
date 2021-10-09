# Maintainer: Aurélien Hamy <aunetx@yandex.com>

PKGNAME = deezer
PKGVER = 5.30.0
BASE_URL = https://www.deezer.com/desktop/download/artifact/win32/x86/$(PKGVER)
EXE_NAME = $(PKGNAME)-$(PKGVER)-setup.exe

json_add = '},\
  "scripts": {\
	"dist": "electron-builder",\
	"start": "electron ."\
  },\
  "devDependencies": {\
    "electron": "^12.0.11",\
	"electron-builder": "^22.13.1"\
  },\
  "build": {\
  	"files": [\
      "**"\
    ],\
    "directories": {\
      "buildResources": "build"\
    }\
  }\
}'

install_build_deps:
	npm install --engine-strict asar

prepare: install_build_deps
	wget -c $(BASE_URL) -O $(EXE_NAME)
	# Extract app from installer
	7z x -so $(EXE_NAME) '$$PLUGINSDIR/app-32.7z' > app-32.7z
	# Extract app archive
	7z x -y -bsp0 -bso0 app-32.7z -osource
	
	asar extract source/resources/app.asar app
	
	mkdir -p app/resources/linux/
	install -Dm644 source/resources/win/systray.png app/resources/linux/
	
	# prettier --write "app/build/*.js"
	# Hide to tray (https://github.com/SibrenVasse/deezer/issues/4)
	# patch -p1 -dresources/app < quit.patch

	head -n -2 app/package.json > tmp.txt && mv tmp.txt app/package.json
	echo  $(json_add) | tee -a app/package.json

	npm i --prefix=app --package-lock-only
	./flatpak-node-generator.py npm app/package-lock.json -o flatpak/generated-sources.json --electron-node-headers --xdg-layout


build: prepare
	cd flatpak && flatpak-builder build dev.aunetx.deezer.yml -/*", "build/assets/*-install --force-clean --user


clean:
	rm -rf app flatpak/{.flatpak-builder,build} node_modules source app-32.7z app.7z deezer-*.exe package-lock.json
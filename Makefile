# Maintainer: Aurélien Hamy <aunetx@yandex.com>

APPNAME = dev.aunetx.deezer
PKGVER = 5.30.220
BASE_URL = https://www.deezer.com/desktop/download/artifact/win32/x86/$(PKGVER)
GPG_KEY_ID = 5A7D3B06F15FB60238941027EB3A799E7EE716EB
VERSION_REGEX = ^v$(PKGVER)-[0-9]{1,}$$


install_build_deps:
	@npm install --engine-strict asar
	@npm install prettier

prepare: clean install_build_deps
	@mkdir -p source

	@echo "Download installer"
	@wget -nv -c $(BASE_URL) -O source/deezer-setup-$(PKGVER).exe

	@echo "Extract app archive from installer"
	@cd source && 7z x -so deezer-setup-$(PKGVER).exe '$$PLUGINSDIR/app-32.7z' > app-32.7z

	@echo "Extract app from app archive"
	@cd source && 7z x -y -bsp0 -bso0 app-32.7z

	@echo "Extract app sources from the app"
	@node_modules/asar/bin/asar.js extract source/resources/app.asar app

	@echo "Prettier the sources to patch successfully"
	@node_modules/prettier/bin-prettier.js --write "app/build/*.js"

	@echo "Apply patches from ./patches, default ones:"
	@echo "Hide to tray when closing (https://github.com/SibrenVasse/deezer/issues/4)"
	@echo "Start in tray cli option (https://github.com/SibrenVasse/deezer/pull/12)"
	@echo "Remove kernel version from User-Agent (https://github.com/aunetx/deezer-linux/pull/9)"
	$(foreach p, $(wildcard ./patches/*), patch -p1 -dapp < $(p);)

	@echo "Append `package-append.json` to the `package.json` of the app"
	@echo "Adds electron, elecron-builder dependencies, and build directives"
	@head -n -1 app/package.json > tmp.txt && mv tmp.txt app/package.json
	@cat package-append.json | tee -a app/package.json


#! FLATPAK

prepare_flatpak: prepare
	@echo "Generate yarn sources (without installing them)"
	@yarn --cwd=app install --mode update-lockfile

	@echo "Package the sources to use them in flatpak-builder offline"
	@mkdir -p flatpak
	@./flatpak-node-generator.py yarn app/yarn.lock -o flatpak/generated-sources.json --electron-node-headers --xdg-layout

build_flatpak: prepare_flatpak
	@echo "Build the flatpak image"
	@flatpak-builder --force-clean --state-dir=flatpak/flatpak-builder flatpak/build $(APPNAME).yml

export_flatpak: prepare_flatpak
	@echo "Build the flatpak package and export it to the repo"
	@flatpak-builder --gpg-sign=$(GPG_KEY_ID) --repo=docs --state-dir=flatpak/flatpak-builder --force-clean flatpak/build $(APPNAME).yml
	@flatpak build-update-repo --generate-static-deltas --gpg-sign=$(GPG_KEY_ID) docs

bundle_flatpak: build_flatpak
	@echo "Create a flatpak bundle"
	@flatpak build-bundle --gpg-sign=$(GPG_KEY_ID) --state-dir=flatpak/flatpak-builder docs deezer.flatpak $(APPNAME)

install_flatpak: prepare_flatpak
	@echo "Build and install locally the flatpak image"
	@flatpak-builder --force-clean --state-dir=flatpak/flatpak-builder --user --install flatpak/build $(APPNAME).yml


#! PACKAGES

install_deps: prepare
	@echo "Install yarn dependencies to pack them later"
	@yarn --cwd=app install

build_deb:
	@echo "Build deb package"
	@yarn --cwd=app run build-deb

build_rpm:
	@echo "Build rpm package"
	@yarn --cwd=app run build-rpm

build_snap:
	@echo "Build snap package"
	@yarn --cwd=app run build-snap

build_appimage:
	@echo "Build AppImage binary"
	@yarn --cwd=app run build-appimage

build_7z:
	@echo "Build 7z archive"
	@yarn --cwd=app run build-7z

build_pkgs: install_deps build_deb build_rpm build_snap build_appimage build_7z


#! UTILS

prepare-release:
	@echo $(DEEZER_RELEASE) | egrep "$(VERSION_REGEX)" > /dev/null || \
		(echo "$(DEEZER_RELEASE) is not a correct release version of v$(PKGVER)" && false)

	@cat $(APPNAME).appdata.xml | egrep "$(PKGVER)" > /dev/null || \
		(echo "$(APPNAME).appdata.xml should contain version $(DEEZER_RELEASE)" && false)

	@desktop-file-validate $(APPNAME).desktop || \
		(echo "Desktop file validation failed" && false)

	@appstream-util validate-relax $(APPNAME).appdata.xml > /dev/null || \
		(echo "Appstream file validation failed" && false)


release: prepare-release
	@echo "Updating to $(DEEZER_RELEASE)..."
	git tag -s $(DEEZER_RELEASE) -m ""
	git push origin $(DEEZER_RELEASE)
	git push


clean:
	@rm -rf app flatpak node_modules source artifacts package-lock.json package.json

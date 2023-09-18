# Maintainer: Aurélien Hamy <aunetx@yandex.com>

APPNAME = dev.aunetx.deezer
PKGVER = 5.30.590
BASE_URL = https://www.deezer.com/desktop/download/artifact/win32/x86/$(PKGVER)
VERSION_REGEX = ^v$(PKGVER)-[0-9]{1,}$$


install_build_deps:
	@npm install --engine-strict asar
	@npm install prettier@2.8.8

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
	@echo "Avoid to set the text/html mime type (https://github.com/aunetx/deezer-linux/issues/13)"
	$(foreach p, $(wildcard ./patches/*), patch -p1 -dapp < $(p);)

	@echo "Append `package-append.json` to the `package.json` of the app"
	@echo "Adds electron, elecron-builder dependencies, and build directives"
	@head -n -1 app/package.json > tmp.txt && mv tmp.txt app/package.json
	@cat package-append.json | tee -a app/package.json


#! PACKAGES

install_deps: prepare
	@echo "Install yarn dependencies to pack them later"
	@yarn --cwd=app install


build_tar.xz_x64:
	@echo "Build tar.xz archive"
	@yarn --cwd=app run build-tar.xz-x64

build_deb_x64:
	@echo "Build deb package"
	@yarn --cwd=app run build-deb-x64

build_rpm_x64:
	@echo "Build rpm package"
	@yarn --cwd=app run build-rpm-x64

build_appimage_x64:
	@echo "Build AppImage binary"
	@yarn --cwd=app run build-appimage-x64


build_tar.xz_arm64:
	@echo "Build tar.xz archive"
	@yarn --cwd=app run build-tar.xz-arm64

build_deb_arm64:
	@echo "Build deb package"
	@yarn --cwd=app run build-deb-arm64

build_rpm_arm64:
	@echo "Build rpm package"
	@yarn --cwd=app run build-rpm-arm64

build_appimage_arm64:
	@echo "Build AppImage binary"
	@yarn --cwd=app run build-appimage-arm64


#! UTILS

prepare-release:
	@echo $(DEEZER_RELEASE) | egrep "$(VERSION_REGEX)" > /dev/null || \
		(echo "$(DEEZER_RELEASE) is not a correct release version of v$(PKGVER)" && false)

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

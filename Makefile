# Maintainer: Aurélien Hamy <aunetx@yandex.com>

APPNAME = dev.aunetx.deezer
PKGVER = 5.30.100
BASE_URL = https://www.deezer.com/desktop/download/artifact/win32/x86/$(PKGVER)
GPG_KEY_ID = 5A7D3B06F15FB60238941027EB3A799E7EE716EB


install_build_deps:
	npm install --engine-strict asar
	npm install prettier

prepare: install_build_deps
	mkdir -p source
	# Download installer
	wget -c $(BASE_URL) -O source/deezer-setup-$(PKGVER).exe
	# Extract app archive from installer
	cd source && 7z x -so deezer-setup-$(PKGVER).exe '$$PLUGINSDIR/app-32.7z' > app-32.7z
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

	# Append `package-append.json` to the `package.json` of the app
	# Adds electron, elecron-builder dependencies, and build directives
	head -n -1 app/package.json > tmp.txt && mv tmp.txt app/package.json
	cat package-append.json | tee -a app/package.json


#! FLATPAK
prepare_flatpak: prepare
	# Generate npm sources (without installing them)
	npm i --prefix=app --package-lock-only
	# Package the sources to use them in flatpak-builder offline
	mkdir -p flatpak
	./flatpak-node-generator.py npm app/package-lock.json -o flatpak/generated-sources.json --electron-node-headers --xdg-layout

build_flatpak: prepare_flatpak
	# Build the flatpak image
	flatpak-builder --force-clean --state-dir=flatpak/flatpak-builder flatpak/build $(APPNAME).yml

export_flatpak: prepare_flatpak
	# Build the flatpak package and export it to the repo
	flatpak-builder --gpg-sign=$(GPG_KEY_ID) --repo=docs --state-dir=flatpak/flatpak-builder --force-clean flatpak/build $(APPNAME).yml
	flatpak build-update-repo --generate-static-deltas --gpg-sign=$(GPG_KEY_ID) docs

flatpak_bundle: build_flatpak
	# Create a flatpak bundle
	flatpak build-bundle --gpg-sign=$(GPG_KEY_ID) --state-dir=flatpak/flatpak-builder docs deezer.flatpak $(APPNAME)

install_flatpak: prepare_flatpak
	# Build and install locally the flatpak image
	flatpak-builder --force-clean --state-dir=flatpak/flatpak-builder --user --install flatpak/build $(APPNAME).yml

run_flatpak:
	flatpak run $(APPNAME)


#! APPIMAGE
install_deps: prepare
	# Install npm dependencies to pack them later
	npm i --prefix=app

build_appimage: install_deps
	# Build the AppImage package
	npm run build-appimage --prefix=app


#! PKGS
build_pkgs: install_deps
	# Build everything
	npm run build --prefix=app


build_rpm: install_deps
	# Build rpm package
	npm run build-rpm --prefix=app


build_deb: install_deps
	# Build deb package
	npm run build-deb --prefix=app


build_pkgs_arm64: install_deps
	# Build everything
	npm run build-arm --prefix=app

build_pkgs_x86: install_deps
	# Build everything
	npm run build-x86 --prefix=app


clean:
	rm -rf app flatpak node_modules source artifacts package-lock.json package.json

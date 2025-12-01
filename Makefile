# Maintainers:
# - Aurélien Hamy <aunetx@yandex.com>
# - Josselin Dulongcourty <contact@josselinonduty.fr>

APPNAME = dev.aunetx.deezer
BASE_URL = $(shell jq ".modules[0].sources[0].url" dev.aunetx.deezer.json)
SHA256 = $(shell jq ".modules[0].sources[0].sha256" dev.aunetx.deezer.json)
PKGVER = $(shell echo $(BASE_URL) | grep -Eo "([0-9]+\.[0-9]+\.[0-9]+)" | head -1)
VERSION_REGEX = ^v$(PKGVER)-[0-9]{1,}$$
SOURCE_DIR ?= ./source
APP_DIR ?= ./app
PACKAGE_MANAGER ?= npm
PACKAGE_MANAGER_SUBDIR_ARG ?= --prefix
PACKAGE_MANAGER_INSTALL_CMD ?= install
PACKAGE_MANAGER_ADD_CMD ?= install

install_build_deps:
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_INSTALL_CMD)

prepare: clean install_build_deps
	@mkdir -p $(SOURCE_DIR)

	@echo "Download installer"
	@wget -nv $(BASE_URL) -O $(SOURCE_DIR)/deezer-setup-$(PKGVER).exe

	@echo "Verify installer"
	@echo "$(SHA256) $(SOURCE_DIR)/deezer-setup-$(PKGVER).exe" | sha256sum -c --status || exit 1

	@echo "Extract app archive from installer"
	@cd $(SOURCE_DIR) && 7z x -so deezer-setup-$(PKGVER).exe '$$PLUGINSDIR/app-32.7z' > app-32.7z

	@echo "Extract app from app archive"
	@cd $(SOURCE_DIR) && 7z x -y -bsp0 -bso0 app-32.7z

	@echo "Extract app sources from the app"
	@npm run asar extract "$(SOURCE_DIR)/resources/app.asar" "$(APP_DIR)"

	@echo "Prettier the sources to patch successfully"
	@cp .prettierrc.json $(APP_DIR)/
	@npm run prettier -- --write "$(APP_DIR)/build/*.{js,html}" --config .prettierrc.json --ignore-path /dev/null

	@echo "--------------------------------"
	@$(foreach p,$(wildcard ./patches/*), echo "Applying $(p)"; patch -p 1 -d $(APP_DIR) < $(p) && echo "Applied $(p)\n";)

	@echo "Append package-append.json to the package.json of the app"
	@echo "Adds electron, elecron-builder dependencies, prod and build directives"
	@jq -s '.[0] * .[1]' $(APP_DIR)/package.json package-append.json > $(APP_DIR)/tmp.json && mv $(APP_DIR)/tmp.json $(APP_DIR)/package.json

	@echo "Download new packages"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_INSTALL_CMD)

#! PACKAGES

install_deps: prepare
	@echo "Install $(PACKAGE_MANAGER) dependencies to pack them later"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) $(PACKAGE_MANAGER_INSTALL_CMD)


build_tar.xz_x64:
	@echo "Build tar.xz archive"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-tar.xz-x64

build_deb_x64:
	@echo "Build deb package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-deb-x64

build_rpm_x64:
	@echo "Build rpm package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-rpm-x64

build_appimage_x64:
	@echo "Build AppImage binary"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-appimage-x64

build_snap_x64:
	@echo "Build Snap package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-snap-x64


build_tar.xz_arm64:
	@echo "Build tar.xz archive"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-tar.xz-arm64

build_deb_arm64:
	@echo "Build deb package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-deb-arm64

build_rpm_arm64:
	@echo "Build rpm package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-rpm-arm64

build_appimage_arm64:
	@echo "Build AppImage binary"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-appimage-arm64

build_snap_arm64:
	@echo "Build Snap package"
	@$(PACKAGE_MANAGER) $(PACKAGE_MANAGER_SUBDIR_ARG) $(APP_DIR) run build-snap-arm64

#! DEV

patch-new: install_deps
	@echo "Setting up the development environment..."
	@cd $(APP_DIR) && echo "node_modules\n*.diff\n*.orig" > .gitignore && git init && git add .
	@cd $(APP_DIR) && git commit -m "initial commit"
	@echo "You can now edit the sources in the $(APP_DIR) directory"
	@echo "When you are done, commit your changes, run 'make patch-gen'."
	@echo "Don't forget to rename your patch."

patch-gen:
	@npm run prettier -- --write "$(APP_DIR)/build/*.{js,html}" --config .prettierrc.json --ignore-path /dev/null
	@cd $(APP_DIR) && git add .
	@cd $(APP_DIR) && git commit
	@cd $(APP_DIR) && git format-patch -1 HEAD --stdout > ../patches/$(shell date +%y%m%d-%s).patch

#! UTILS

prepare-release:
	@echo $(DEEZER_RELEASE) | egrep "$(VERSION_REGEX)" > /dev/null || \
		(echo "$(DEEZER_RELEASE) is not a correct release version of v$(PKGVER)" && false)

	@desktop-file-validate $(APPNAME).desktop || \
		(echo "Desktop file validation failed" && false)


release: prepare-release
	@echo "Updating to $(DEEZER_RELEASE)..."
	git tag -s $(DEEZER_RELEASE) -m ""
	git push origin $(DEEZER_RELEASE)
	git push


clean:
	@rm -rf ./$(APP_DIR) flatpak node_modules ./$(SOURCE_DIR) artifacts package-lock.json yarn.lock

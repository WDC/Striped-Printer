BINARY_NAME := StripedPrinter
BUILD_DIR := .build
RELEASE_BINARY := $(BUILD_DIR)/$(BINARY_NAME)
APP_BUNDLE := $(BUILD_DIR)/$(BINARY_NAME).app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)
INSTALL_DIR := /Applications
PLIST_NAME := com.striped-printer.plist
PLIST_SRC := $(PLIST_NAME)
PLIST_DEST := $(HOME)/Library/LaunchAgents/$(PLIST_NAME)
SIGNING_IDENTITY := Developer ID Application: David Lemcoe (3Y4684F72Z)
NOTARIZE_PROFILE := AC_PASSWORD

# --- Build ---

.PHONY: build
build:
	swift build -c release --arch arm64
	swift build -c release --arch x86_64
	lipo -create \
		$(BUILD_DIR)/arm64-apple-macosx/release/$(BINARY_NAME) \
		$(BUILD_DIR)/x86_64-apple-macosx/release/$(BINARY_NAME) \
		-output $(RELEASE_BINARY)
	@echo "Built universal binary: $(RELEASE_BINARY)"
	@file $(RELEASE_BINARY)

# --- App Bundle ---

.PHONY: bundle
bundle: build
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(RELEASE_BINARY) $(APP_BINARY)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Created $(APP_BUNDLE)"

# --- Code Sign ---

.PHONY: sign
sign:
	codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)
	@echo "Signed with Developer ID + hardened runtime"
	@codesign -dv $(APP_BUNDLE) 2>&1 | head -5

# --- Notarize ---

.PHONY: notarize
notarize:
	rm -f $(BUILD_DIR)/$(BINARY_NAME).zip
	cd $(BUILD_DIR) && zip -r $(BINARY_NAME).zip $(BINARY_NAME).app
	xcrun notarytool submit $(BUILD_DIR)/$(BINARY_NAME).zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	@echo "Notarization complete and stapled"

# --- GitHub Release ---

.PHONY: release
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=1.0.0)
endif
	@echo "==> Building v$(VERSION)..."
	$(MAKE) bundle
	$(MAKE) sign
	$(MAKE) notarize
	rm -f $(BUILD_DIR)/$(BINARY_NAME).zip
	cd $(BUILD_DIR) && zip -r $(BINARY_NAME).zip $(BINARY_NAME).app
	git tag -a "v$(VERSION)" -m "v$(VERSION)"
	git push origin "v$(VERSION)"
	gh release create "v$(VERSION)" \
		$(BUILD_DIR)/$(BINARY_NAME).zip \
		--title "Striped Printer v$(VERSION)" \
		--generate-notes
	@echo "Released v$(VERSION)"

# --- Install ---

.PHONY: install
install:
	@if [ ! -d $(APP_BUNDLE) ]; then \
		echo "App bundle not found. Run 'make bundle' first."; \
		exit 1; \
	fi
	-launchctl bootout gui/$$(id -u) $(PLIST_DEST) 2>/dev/null
	rm -rf $(INSTALL_DIR)/$(BINARY_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(BINARY_NAME).app
	@echo "Installed $(INSTALL_DIR)/$(BINARY_NAME).app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(INSTALL_DIR)/$(BINARY_NAME).app
	@echo "Registered with Launch Services (.zpl file association)"
	sed 's|/Users/david/striped-printer/.build/StripedPrinter.app/Contents/MacOS/StripedPrinter|$(INSTALL_DIR)/$(BINARY_NAME).app/Contents/MacOS/$(BINARY_NAME)|' \
		$(PLIST_SRC) > $(PLIST_DEST)
	launchctl bootstrap gui/$$(id -u) $(PLIST_DEST)
	@echo "LaunchAgent loaded — $(BINARY_NAME) is running"

# --- Uninstall ---

.PHONY: uninstall
uninstall:
	-launchctl bootout gui/$$(id -u) $(PLIST_DEST) 2>/dev/null
	rm -f $(PLIST_DEST)
	rm -rf $(INSTALL_DIR)/$(BINARY_NAME).app
	@echo "Uninstalled $(BINARY_NAME)"

# --- Clean ---

.PHONY: clean
clean:
	swift package clean
	rm -rf $(RELEASE_BINARY) $(BUILD_DIR)/$(BINARY_NAME).zip $(APP_BUNDLE)
	@echo "Cleaned build artifacts"

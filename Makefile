BINARY_NAME := StripedPrinter
BUILD_DIR := .build
RELEASE_BINARY := $(BUILD_DIR)/$(BINARY_NAME)
INSTALL_DIR := /usr/local/bin
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

# --- Code Sign ---

.PHONY: sign
sign:
	codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(RELEASE_BINARY)
	@echo "Signed with Developer ID + hardened runtime"
	@codesign -dv $(RELEASE_BINARY) 2>&1 | head -5

# --- Notarize ---

.PHONY: notarize
notarize:
	rm -f $(BUILD_DIR)/$(BINARY_NAME).zip
	zip -j $(BUILD_DIR)/$(BINARY_NAME).zip $(RELEASE_BINARY)
	xcrun notarytool submit $(BUILD_DIR)/$(BINARY_NAME).zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	@echo "Notarization complete. Bare binaries cannot be stapled — Gatekeeper checks online."

# --- GitHub Release ---

.PHONY: release
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=1.0.0)
endif
	@echo "==> Building v$(VERSION)..."
	$(MAKE) build
	$(MAKE) sign
	$(MAKE) notarize
	git tag -a "v$(VERSION)" -m "v$(VERSION)"
	git push origin "v$(VERSION)"
	gh release create "v$(VERSION)" \
		$(RELEASE_BINARY) \
		--title "Striped Printer v$(VERSION)" \
		--generate-notes
	@echo "Released v$(VERSION)"

# --- Install ---

.PHONY: install
install:
	@if [ ! -f $(RELEASE_BINARY) ]; then \
		echo "Binary not found. Run 'make build' first."; \
		exit 1; \
	fi
	-launchctl bootout gui/$$(id -u) $(PLIST_DEST) 2>/dev/null
	cp $(RELEASE_BINARY) $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Installed $(INSTALL_DIR)/$(BINARY_NAME)"
	sed 's|/Users/david/striped-printer/.build/release/StripedPrinter|$(INSTALL_DIR)/$(BINARY_NAME)|' \
		$(PLIST_SRC) > $(PLIST_DEST)
	launchctl bootstrap gui/$$(id -u) $(PLIST_DEST)
	@echo "LaunchAgent loaded — $(BINARY_NAME) is running"

# --- Uninstall ---

.PHONY: uninstall
uninstall:
	-launchctl bootout gui/$$(id -u) $(PLIST_DEST) 2>/dev/null
	rm -f $(PLIST_DEST)
	rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Uninstalled $(BINARY_NAME)"

# --- Clean ---

.PHONY: clean
clean:
	swift package clean
	rm -f $(RELEASE_BINARY) $(BUILD_DIR)/$(BINARY_NAME).zip
	@echo "Cleaned build artifacts"

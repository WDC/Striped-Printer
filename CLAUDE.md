# CLAUDE.md — Striped Printer

## What This Is

Striped Printer is a native macOS menu bar app that replaces both Zebra Browser Print and iZPL. It runs an HTTP server on port 9100 (and HTTPS on 9101) that implements the same API the Browser Print JavaScript SDK expects, then forwards raw ZPL to network Zebra printers over TCP 9100. It also handles `.zpl` files directly — double-click to send to a printer.

## Build & Run

```bash
# Debug build
swift build

# App bundle (release universal binary + .app structure)
make bundle

# Run from bundle
open .build/StripedPrinter.app

# Or run the debug binary directly
.build/debug/StripedPrinter
```

The app runs as a menu bar item (printer icon). Quit via the menu bar or `pkill StripedPrinter`.

### Release workflow

```bash
make release VERSION=X.Y.Z   # build → bundle → sign → notarize → tag → GitHub release
```

Then update the Homebrew tap (`WDC/homebrew-tap`) with the new version and SHA256.

## Project Structure

```
Sources/StripedPrinter/
├── main.swift              # Entry point — creates NSApplication, sets AppDelegate, runs
├── AppDelegate.swift       # Menu bar UI, status item, .zpl file open handling, printer picker
├── Models.swift            # Data models: PrinterDevice, NetworkPrinter, API request/response types
├── HTTPServer.swift        # Lightweight HTTP/1.1 server built on NWListener (Network.framework)
├── BrowserPrintAPI.swift   # Browser Print API endpoint handlers (/default, /available, /write, etc.)
├── PrinterManager.swift    # Printer discovery (Bonjour + subnet scanner), TCP connections, persistence
├── TLSManager.swift        # Self-signed cert generation (openssl), PKCS12 import, keychain trust

Info.plist                  # App bundle metadata, .zpl file association (CFBundleDocumentTypes)
AppIcon.icns                # App icon (reused from legacy iZPL)
Makefile                    # Build, bundle, sign, notarize, install, release targets
Formula/striped-printer.rb  # Homebrew formula
com.striped-printer.plist   # LaunchAgent template
```

No external dependencies. Uses only Apple frameworks: AppKit, Network, Security, Foundation.

## Key Architecture

- **HTTPServer** uses `NWListener` (Network.framework) for both HTTP and TLS connections. Routes are registered as `(method, path, handler)` tuples. CORS headers including `Access-Control-Allow-Private-Network` are added to all responses.
- **PrinterManager** is `@MainActor` and maintains three separate printer arrays: `bonjourPrinters`, `scannedPrinters`, `manualPrinters`. The `allPrinters` computed property deduplicates by host+port.
- **Subnet scanner** uses POSIX sockets (`socket` → non-blocking `connect` → `poll` → `send ~hi\r\n` → `recv`) on an `OperationQueue` (max 30 concurrent). NWConnection was unreliable for mass probing.
- **TLS** generates a self-signed cert via openssl CLI, converts to PKCS12, loads via `SecPKCS12Import`, and auto-trusts in the login keychain for browser compatibility.
- **File handling** — `application(_:openFile:)` and `application(_:openFiles:)` read `.zpl` files, show a printer picker (NSAlert + NSPopUpButton) if multiple printers exist, and send via `PrinterConnection`. The app stays running after sending.
- **Legacy migration** — `PrinterManager.migrateLegacyConfig()` imports `~/.zplprinters` (iZPL format: `IP:PORT:NAME`) into `manualPrinters` on first launch, then renames the file to `.zplprinters.migrated`.
- **App bundle** — `make bundle` creates `.build/StripedPrinter.app` with `Info.plist` (`.zpl` document type) and `AppIcon.icns`. Required for Launch Services file association. The Homebrew formula also builds the `.app` structure.

## Testing the API

```bash
# List all printers
curl -s http://127.0.0.1:9100/available | python3 -m json.tool

# Get default printer
curl -s 'http://127.0.0.1:9100/default?type=printer'

# Get config
curl -s http://127.0.0.1:9100/config

# Send ZPL to a printer
curl -s -X POST http://127.0.0.1:9100/write \
  -H 'Content-Type: application/json' \
  -d '{
    "device": {
      "uid": "10.175.176.30:9100",
      "deviceType": "printer",
      "connection": "network",
      "name": "ZT230-200dpi",
      "provider": "com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider",
      "version": 3,
      "manufacturer": "Zebra Technologies"
    },
    "data": "^XA^CF0,40^FO50,50^FDHello World^FS^XZ"
  }'

# HTTPS (works after cert is trusted)
curl -s 'https://localhost:9101/available'
```

## Printer Discovery

Three methods, in priority order:

1. **Manual printers** — saved in `~/Library/Application Support/StripedPrinter/printers.json`
2. **Subnet scan** — probes port 9100 across local /24 subnets, identifies Zebra printers with `~hi\r\n`
3. **Bonjour** — discovers `_pdl-datastream._tcp` services (catches non-Zebra printers too)

Default printer UID is saved in `~/Library/Application Support/StripedPrinter/default.txt`.

## LaunchAgent

Installed at `~/Library/LaunchAgents/com.striped-printer.plist`. The plist points to the binary inside the app bundle. Manage with:

```bash
launchctl load ~/Library/LaunchAgents/com.striped-printer.plist
launchctl unload ~/Library/LaunchAgents/com.striped-printer.plist
```

Logs go to `/tmp/striped-printer.log`.

**Important:** The app bundle must be code-signed (`codesign --force --sign -`) for the subnet scanner to work when launched via launchd. Without signing, macOS blocks outbound socket connections from LaunchAgent processes.

## ZPL File Handling

Striped Printer registers as the macOS handler for `.zpl` files via `CFBundleDocumentTypes` in `Info.plist`. When a `.zpl` file is opened:

1. If no printers are known → shows "No Printers Found" alert
2. If one printer → sends immediately
3. If multiple printers → shows a picker dialog (pre-selects the default printer)

Test with: `open -a .build/StripedPrinter.app /tmp/test.zpl`

## Browser Print API Compatibility

The JS SDK (`BrowserPrint-3.x.js`) hits `http://127.0.0.1:9100/` by default. On HTTPS pages:
- **Chrome/Edge**: stays on HTTP to 127.0.0.1 (mixed content exception for loopback)
- **Safari**: switches to `https://127.0.0.1:9101/`
- **Older SDK (v1.x)**: always switches to `https://localhost:9101/` on HTTPS pages

The self-signed cert covers both `127.0.0.1` (IP SAN) and `localhost` (DNS SAN).

## Common Issues

- **"Zebra offline" in browser** — check that StripedPrinter is running (`pgrep StripedPrinter`). If on HTTPS, ensure the cert is trusted (`security dump-trust-settings | grep 127.0.0.1`).
- **Scanner finds 0 printers** — ensure binary is code-signed. Check logs at `/tmp/striped-printer.log`.
- **Port 9100 already in use** — kill existing processes: `lsof -i :9100` then `pkill -f StripedPrinter` or stop Zebra Browser Print if installed.
- **Printers on different subnet** — use "Scan Network" from the menu bar to scan specific subnets, or "Add Printer" to enter an IP directly.

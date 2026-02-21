# Striped Printer

A fast, native macOS replacement for Zebra Browser Print. Drop it in, point your web apps at `localhost:9100`, and print ZPL to any network Zebra printer — no Java runtime, no Electron wrapper, no 200 MB install.

## Why?

Zebra's [Browser Print](https://www.zebra.com/us/en/software/printer-software/browser-print.html) bridges the gap between web applications and thermal printers by running a local HTTP server that accepts ZPL and forwards it over TCP 9100. It works, but:

- It's a **Java application** that bundles its own JRE (~200 MB)
- It runs a heavyweight process for what amounts to proxying TCP connections
- The installer hasn't been meaningfully updated in years
- It's closed-source and Windows-first; macOS is an afterthought

**Striped Printer** is a ~2,000 line Swift app that does the same thing. It's a single binary, starts instantly, lives in your menu bar, and uses about 15 MB of RAM. It implements the same HTTP API that the Browser Print JavaScript SDK expects, so your existing web integrations work without changing a line of code.

## Features

- **Drop-in compatible** — implements the full Browser Print HTTP API (`/default`, `/available`, `/config`, `/write`, `/read`)
- **Double-click `.zpl` files** — registers as the macOS handler for `.zpl` files, shows a printer picker, and sends directly
- **Auto-discovery** — finds Zebra printers via Bonjour and active subnet scanning with `~hi` identification
- **HTTPS support** — self-signed TLS on port 9101 for HTTPS-hosted web apps, auto-trusted in your login keychain
- **Menu bar app** — lightweight status item with printer list, manual add, network scan, and default printer selection
- **Zero dependencies** — pure Swift using Network.framework, Security.framework, and AppKit. No SPM packages, no CocoaPods
- **CORS + Private Network Access** — handles Chrome's `Access-Control-Allow-Private-Network` preflight requirements

## Installation

### Homebrew (recommended)

```bash
brew install WDC/tap/striped-printer
brew services start striped-printer
```

### Download

Grab the latest notarized app from [GitHub Releases](https://github.com/WDC/Striped-Printer/releases):

1. Download `StripedPrinter.zip`
2. Unzip and move `StripedPrinter.app` to `/Applications/`
3. Open it — it will appear in your menu bar

### Build from Source

```bash
git clone https://github.com/WDC/Striped-Printer.git
cd Striped-Printer
make bundle
make install
```

This builds a universal binary (arm64 + x86_64), creates an app bundle, installs it to `/Applications/`, registers `.zpl` file association, and sets up a LaunchAgent to start at login.

## Quick Start

A printer icon appears in your menu bar. Striped Printer will:

1. Start HTTP on port **9100** and HTTPS on port **9101**
2. Discover printers via Bonjour (`_pdl-datastream._tcp`)
3. Scan your local subnets for Zebra printers on port 9100
4. Serve the Browser Print API to your web applications

You can also double-click any `.zpl` file to send it directly to a printer. If multiple printers are available, a picker dialog appears.

## Migrating from iZPL / ZPL Printer

If you previously used iZPL (ZPL Printer), Striped Printer will automatically import your printers from `~/.zplprinters` on first launch. The old config file is renamed to `~/.zplprinters.migrated`.

## Uninstall

```bash
# Homebrew
brew services stop striped-printer
brew uninstall striped-printer

# Manual / make
make uninstall
```

## API Compatibility

Striped Printer implements the endpoints that the Zebra Browser Print JavaScript SDK (`BrowserPrint-3.x.js`) calls:

| Endpoint | Method | Description |
|---|---|---|
| `/default?type=printer` | GET | Returns the default printer device JSON |
| `/available` | GET | Returns `{"printer": [...]}` with all discovered devices |
| `/config` | GET | Returns application config (version, supported conversions) |
| `/write` | POST | Sends ZPL data to a printer |
| `/read` | POST | Reads response data from a printer |
| `/convert` | POST | Returns 501 (not supported — send raw ZPL directly) |

The device JSON matches Browser Print's format exactly:

```json
{
  "deviceType": "printer",
  "uid": "10.175.176.30:9100",
  "provider": "com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider",
  "name": "ZT230-200dpi (10.175.176.30)",
  "connection": "network",
  "version": 3,
  "manufacturer": "Zebra Technologies"
}
```

## Adding Printers

Striped Printer finds printers three ways:

1. **Bonjour** — automatically discovers printers advertising `_pdl-datastream._tcp`
2. **Subnet scan** — probes your local /24 subnets on port 9100 and identifies Zebra printers via the `~hi` command
3. **Manual** — add printers by IP address through the menu bar (persisted to `~/Library/Application Support/StripedPrinter/printers.json`)

If your Zebra printers are on a different VLAN or subnet, use **Scan Network** from the menu bar to scan specific subnets, or **Add Printer** to enter an IP directly.

## Requirements

- macOS 13+ (Ventura or later)
- Swift 5.9+ toolchain
- Network-accessible Zebra printer(s) on port 9100

## How It Works

```
Browser JS SDK                 Striped Printer              Zebra Printer
─────────────────            ─────────────────            ───────────────
                    HTTP/HTTPS                    TCP 9100
BrowserPrint.js  ──────────▶  localhost:9100  ──────────▶  10.x.x.x:9100
                               (or :9101)
  GET /default                                              Raw ZPL data
  POST /write { zpl }                                       ◀── response
  POST /read
```

The Browser Print JS SDK makes HTTP requests to `localhost:9100` (or `https://localhost:9101` on HTTPS pages). Striped Printer receives these, looks up the target printer, opens a TCP connection to port 9100 on the printer, and sends the raw ZPL. No drivers, no print spooler, no CUPS — just TCP.

## License

MIT

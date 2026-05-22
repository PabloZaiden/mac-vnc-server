# mac-vnc-server

`mac-vnc-server` is a macOS-only VNC/RFB server written in Swift. It captures the local Mac screen, accepts keyboard and mouse input from a VNC client, and exposes the session on a configurable TCP port.

The default setup is optimized for local testing with Apple Screen Sharing:

- bind address: `127.0.0.1`
- port: `5902`
- password: `macvnc`
- FPS target: `30`
- scale: `1.0`
- encoding: `auto`

Use SSH tunneling or an explicit LAN bind for remote use.

## Requirements

- macOS 13 or newer
- Xcode / Swift toolchain compatible with `swift-tools-version: 6.3`
- Screen Recording permission
- Accessibility / Post Event permission for keyboard and mouse injection

The package links macOS-native frameworks:

- `ScreenCaptureKit` for screen capture
- `CoreGraphics` / `ApplicationServices` for input injection and permissions
- `AppKit` for clipboard integration
- `zlib` for compressed framebuffer encodings

## Build

```sh
swift build -c release
```

The binary is produced at:

```text
.build/release/mac-vnc-server
```

For an explicit Apple Silicon build:

```sh
swift build -c release --arch arm64
```

## Versioning

Development builds always report:

```text
0.0.0-development
```

The release workflow replaces that value with the Git tag being released, stripping a leading `v`. For example, release tag `v1.2.3` builds a binary that reports `1.2.3`.

Show the version:

```sh
./.build/release/mac-vnc-server version
./.build/release/mac-vnc-server --help
```

The server also prints its version at startup.

## Permissions

Run this once:

```sh
./.build/release/mac-vnc-server permissions
```

Then grant the requested permissions in macOS System Settings:

- Privacy & Security -> Screen Recording
- Privacy & Security -> Accessibility

Restart the server after granting permissions.

Check current status:

```sh
./.build/release/mac-vnc-server diagnose
```

## Run locally

Default command:

```sh
./.build/release/mac-vnc-server
```

Equivalent explicit command:

```sh
./.build/release/mac-vnc-server run --bind 127.0.0.1 --port 5902 --fps 30 --scale 1 --encoding auto --password macvnc
```

Connect with Apple Screen Sharing:

```sh
open 'vnc://127.0.0.1:5902'
```

Password:

```text
macvnc
```

For unattended local testing, fill the native Screen Sharing password dialog with AppleScript:

```sh
open 'vnc://127.0.0.1:5902'
sleep 2
osascript -e 'tell application "System Events" to keystroke "macvnc"' \
          -e 'tell application "System Events" to key code 36'
```

Do not store test credentials in Keychain unless you explicitly want that behavior.

## Run on LAN

Bind all interfaces:

```sh
./.build/release/mac-vnc-server --bind 0.0.0.0 --port 5902 --password macvnc
```

Or bind a specific LAN IP:

```sh
./.build/release/mac-vnc-server --bind 192.168.1.10 --port 5902 --password macvnc
```

The server refuses unauthenticated non-loopback binds by default. To disable auth for clients that support unauthenticated VNC, you must opt in explicitly:

```sh
./.build/release/mac-vnc-server --bind 0.0.0.0 --no-password --insecure-allow-no-auth
```

Classic VNC password auth is weak and limited by the protocol. For untrusted networks, prefer an SSH tunnel:

```sh
ssh -L 5902:127.0.0.1:5902 user@mac-host
open 'vnc://127.0.0.1:5902'
```

## CLI

```text
mac-vnc-server [run] [options]
mac-vnc-server permissions
mac-vnc-server diagnose
mac-vnc-server version
mac-vnc-server --help
```

`run` is optional when the first argument is a flag.

Options:

| Option | Default | Description |
| --- | --- | --- |
| `--bind <ipv4>` | `127.0.0.1` | IPv4 address to listen on. |
| `--port <port>` / `-p <port>` | `5902` | TCP port. |
| `--password <value>` | `macvnc` | Classic VNC auth password. |
| `--no-password` | off | Use unauthenticated VNC. Apple Screen Sharing does not accept this path. |
| `--insecure-allow-no-auth` | off | Required with `--no-password` on non-loopback binds. |
| `--fps <1...120>` | `30` | Target framebuffer update rate. |
| `--scale <value>` | `1.0` | Virtual framebuffer scale. `1.0` is usually best for Retina/LAN performance. |
| `--encoding <auto\|zrle\|zlib\|raw>` | `auto` | Framebuffer encoding preference. |

## How it works

### RFB/VNC protocol

The server implements the RFB handshake and core client messages:

- protocol negotiation
- `SecurityType None` and classic VNC auth
- `SetPixelFormat`
- `SetEncodings`
- `FramebufferUpdateRequest`
- `KeyEvent`
- `PointerEvent`
- `ClientCutText`

Apple Screen Sharing negotiates RFB 3.3 and requires VNC auth, so the default password is enabled.

### Capture pipeline

Screen capture uses `ScreenCaptureKit` with one stream per display. Captured frames are stored in BGRA format and composed into a single virtual framebuffer. The virtual framebuffer supports multiple displays and maps VNC coordinates back to macOS global coordinates for mouse input.

### Encodings

`--encoding auto` chooses a compatible encoding based on the client:

- Apple Screen Sharing: persistent Zlib encoding (`6`)
- generic clients with ZRLE: ZRLE (`16`)
- generic clients with Zlib: Zlib (`6`)
- fallback: Raw (`0`)

Zlib is kept as a persistent stream per VNC connection, which is required for stable compressed updates with Apple Screen Sharing.

### Input

Keyboard and mouse events are injected with `CGEvent`.

The server processes input on the read loop and streams framebuffer updates on a separate writer queue. This prevents keyboard/mouse events from getting stuck behind frame compression or socket writes.

For Apple Screen Sharing, `Alt_L` / `Alt_R` keysyms are remapped to macOS Command because the native client sends Command that way. This enables shortcuts such as `Cmd+C`, `Cmd+V`, `Cmd+W`, and `Cmd+Q`.

### Clipboard

Clipboard support uses `NSPasteboard` and classic VNC cut text messages. This path is basic text clipboard support; full extended clipboard support is not implemented yet.

## GitHub Actions

This repository includes two workflows:

### CI

`.github/workflows/ci.yml`

Runs on pull requests and pushes to `main`:

- `swift test`
- `swift build -c release`

### Release

`.github/workflows/release.yml`

Runs when a GitHub Release is published:

- replaces `0.0.0-development` in `AppVersion.swift` with the release tag
- runs tests
- builds an arm64 macOS release binary
- packages the binary plus SHA-256 checksum
- uploads `mac-vnc-server-<version>-macos-arm64.tar.gz` to the GitHub Release

## Troubleshooting

### Apple Screen Sharing keeps asking for a password

The default password is printed on server startup:

```text
password=macvnc
```

For scripted testing, use AppleScript to type it instead of Keychain.

### Screen updates work, but input lags

Make sure you are running a build with the split reader/writer architecture. Rebuild:

```sh
swift build -c release
```

Then restart the server.

### Input works, but screen does not update

Use the default encoding first:

```sh
./.build/release/mac-vnc-server --encoding auto
```

If testing a generic client, try:

```sh
./.build/release/mac-vnc-server --encoding zrle
./.build/release/mac-vnc-server --encoding zlib
./.build/release/mac-vnc-server --encoding raw
```

### Port already in use

Use another port:

```sh
./.build/release/mac-vnc-server --port 5903
open 'vnc://127.0.0.1:5903'
```

### Permissions are missing

Run:

```sh
./.build/release/mac-vnc-server permissions
./.build/release/mac-vnc-server diagnose
```

Then restart the server after granting permissions.


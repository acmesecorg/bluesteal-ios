# bluesteal-ios

The **iOS** client for bluesteal — observe FIDO caBLE (CTAP 2.2 hybrid-tunnel)
BLE advertisements and relay them to a paired peer.

- **Stack:** Swift / SwiftUI
- **Role:** **host-only.** iOS can't re-broadcast peer adverts (Core Bluetooth
  peripheral mode rejects raw service-data for third-party apps), so the
  join/peer role is omitted — iOS always hosts, and a macOS / Windows / Android
  peer joins its token.

## Build & run

```bash
git clone https://github.com/acmesecorg/bluesteal-ios.git
open bluesteal-ios.xcodeproj   # scheme: bluesteal-ios
```

Needs a signing team for device builds (`-allowProvisioningUpdates`). Uses
Xcode 16 file-system-synchronized groups, so any source under `bluesteal-ios/`
is compiled automatically. No secrets or credentials needed.

## Driving the host flow for testing

- **URL scheme:** `bluesteal://host` (tap a link / Shortcut / Safari) — the
  production auto-drive.
- **Launch arg:** `-host` — handy on the simulator:
  `xcrun simctl launch <udid> org.crainiate.bluesteal-ios -host`.

The hosted token appears as a `token.ready` event in the per-PID JSONL trace
under `<app-container>/Library/Application Support/bluesteal/Logs/` (use the
in-app **Logs** share button, or pull via `devicectl … copy from`).

## Rendezvous pairing (two-rooms demo)

To pair with a device in another room without reading a token across, the host
publishes its current `CODE-ROUTING` token to a small Cloudflare Worker
("rendezvous") that the peer polls. Deploy your own Worker from the umbrella
repo's `tools/rendezvous/`, then configure this app **at runtime** — nothing is
compiled in or committed:

```
bluesteal://config?rv=<worker-base-url>&room=<room>&k=<bearer>
```

Open that URL **on the device** via a tappable link (e.g. paste into a Note) or a
QR of it — Safari's address bar won't launch a custom scheme. It stores
`rv.baseURL` / `rv.room` / `rv.key` in UserDefaults. Then tap **Host**: the host
runs a persistent loop that republishes a fresh token on every (re)connect, and
self-heals on drops. Inbound relayed adverts show up as the `recv` counter and
`advert.recv` trace events (iOS is host-only, so they aren't re-broadcast).

## More

Protocol, architecture, OOB-token format, and the shared specs live in the
umbrella repo: **https://github.com/acmesecorg/bluesteal**

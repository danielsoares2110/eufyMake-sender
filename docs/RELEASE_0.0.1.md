# EufyMake Sender 0.0.1

First release. A tiny native macOS app for the AnkerMake M5 / M5C: send a G-code file, watch
the printer's camera, and read the temperatures. No slicer, no cloud dashboard.

## Download

Grab **`EufyMake-Sender-0.0.1-macOS.zip`** from the assets below, unzip it, and drag
`EufyMake Sender.app` into Applications.

Requirements: **macOS 26 or newer**, Apple Silicon, and a printer on the same LAN.

### First launch

The app is ad-hoc signed, not notarized, so macOS will warn the first time. Either:

- **Right-click the app → Open → Open**, or
- run `xattr -dr com.apple.quarantine "/Applications/EufyMake Sender.app"`.

## What's in it

- **G-code** — drag a `.gcode` file onto the window and hit **Send to printer**. Uploads over
  PPPP (UDP 32108) and starts printing when the transfer completes.
- **Camera** — the M5's camera at 720p / 25 fps, decoded with VideoToolbox.
- **Temperatures and status** — nozzle/bed current and target temps, print state, progress,
  elapsed / remaining time, layers, via Anker's MQTT feed.
- **Print controls** — pause, resume, stop, preheat, home.
- **Settings (⌘,)** — optional minimum window size, and an Activity log (off by default) with
  raw `[API]` / `[Pppp]` / `[MQTT]` / `[H264]` output.
- **Native macOS 26 UI** — Liquid Glass panels, rounded cards, and a compact single-column
  layout when the window is small.

## Getting started

1. Launch the app and press **Sign in** — use the same AnkerMake account as eufyMake Studio.
   The session is cached locally in
   `~/Library/Application Support/EufyMakeSender/login.json`.
2. Pick your printer from the device menu.
3. Drop a `.gcode` file on the window and press **Send to printer**.
4. Press **Start** in the camera panel.

## Known limitations

- **LAN only.** No remote relay; the Mac and printer must be on the same network.
- MQTT TLS uses the broker's self-signed certificate (matching the reference clients), so the
  certificate is not verified.
- The camera pauses during an upload (one PPPP transfer at a time) and resumes afterwards.
- Pause / resume / stop use the reverse-engineered `1008` command format.

## Notes

This is an unofficial community tool, not affiliated with or supported by Anker or eufy. The
protocol was reverse-engineered — use it at your own risk.

Build from source: `./build.sh` (see the [README](https://github.com/danielsoares2110/eufyMake-sender#readme)).

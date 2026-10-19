# EufyMake Sender

A tiny native macOS app for the **AnkerMake M5 / M5C** that does exactly three things: send a
G-code file, show the printer's camera, and show the temperatures.

<img width="1021" height="985" alt="Screenshot 2026-10-19 at 6 36 19 PM" src="https://github.com/user-attachments/assets/4acdcda5-0ff8-4f42-b3a3-8bc5f5e35da1" />


![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![Arch](https://img.shields.io/badge/arch-arm64-lightgrey)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Version](https://img.shields.io/badge/version-0.0.1-green)
[![Release](https://img.shields.io/github/v/release/danielsoares2110/eufyMake-sender?include_prereleases)](https://github.com/danielsoares2110/eufyMake-sender/releases)

No slicer, no cloud dashboard, no account juggling beyond the one AnkerMake login. Drag a
`.gcode` file onto the window, hit **Send to printer**, and watch the camera while it prints.

## Features

- **G-code transfer** — import or drag-and-drop a `.gcode` file; it uploads over your LAN and
  starts printing as soon as the transfer completes.
- **Live camera** — the M5's built-in camera at 720p / 25 fps, decoded with VideoToolbox.
- **Temperatures** — nozzle and bed current/target temps, print state, progress, elapsed and
  remaining time, layer count.
- **Print control** — pause, resume, stop, preheat, home.
- **Native macOS 26 UI** — Liquid Glass panels, rounded floating cards, and a compact
  single-column layout when you shrink the window.
- **Settings (⌘,)** — optional minimum window size, and an Activity log (hidden by default)
  with the raw `[API]` / `[Pppp]` / `[MQTT]` / `[H264]` traffic.

## Requirements

- macOS 26 or newer (Apple Silicon).
- An AnkerMake M5 / M5C on the **same network** as the Mac.
- An AnkerMake account (the same one you use with eufyMake Studio / the AnkerMake app).

The camera stream and the file upload are strictly LAN-only. They use the printer's PPPP
protocol on UDP port 32108. The temperature feed uses Anker's MQTT service and needs your
account's auth token.

## Quick start

```bash
git clone https://github.com/danielsoares2110/eufyMake-sender.git
cd eufyMake-sender
./build.sh
open "EufyMake Sender.app"
```

`build.sh` uses `swiftc` + `clang` and `actool` for the icon — no Xcode project required.

The app icon is compiled from an Icon Composer `.icon` bundle. Point the build at your own
with:

```bash
ICON_SRC="/path/to/MyIcon.icon" ./build.sh
```

If no icon is found the app still builds, just with a generic icon.

## Signing in

Click **Sign in** and complete the normal AnkerMake login in the embedded window. The session
is stored locally at:

```
~/Library/Application Support/EufyMakeSender/login.json
```

The app only ever talks to Anker's own endpoints (`query_fdm_list`, MQTT) and to the printer
on your local network.

## Using it

1. Pick your printer from the device menu in the header.
2. **G-code** — drop a `.gcode` file on the window (or use *Choose file…*), then **Send to
   printer**. The printer starts the job automatically when the upload finishes.
3. **Camera** — press **Start** in the camera panel.
4. **Temperatures / status** — live as soon as the monitor connects. If it says *Monitor
   offline*, press **Reconnect**.
5. **Controls** — pause / resume / stop / preheat / home are enabled while a print is active.

Turning on **Show the Activity log** in Settings is the fastest way to see what the app is
doing if something misbehaves.

## How it works

The protocol here is ported from the reverse-engineering documented in the
[eufyMake-PrusaSlicer-Release-ARM](https://github.com/bobbyb/eufyMake-PrusaSlicer-Release-ARM)
fork (`AnkerStudio/src/slic3r/GUI/AnkerNetModule/PROTOCOL.md`), itself based on the community
`ankermake-m5-protocol` findings.

| Feature | Transport | Source |
|---|---|---|
| Login session | embedded WebView posting `{"functionName":"login",...}` over the `anker_msg` bridge | `Sources/LoginWindow.swift` |
| Device list (`query_fdm_list`) | HTTPS POST to `make-app(.eu).ankermake.com` with `X-Auth-Token` and `Gtoken: md5(user_id)` | `Sources/AnkerAPI.swift` |
| Temps / status / pause / resume / stop | MQTT-TLS on port 8789; `MA` frames = AES-CBC(`secret_key`, IV `3DPrintAnkerMake`, PKCS7) + XOR checksum; temps are ×100; `1008` = pause(2) / resume(3) / stop(4) | `Sources/AnkerMQTT.swift`, `Sources/PrinterHub.swift` |
| Discovery, upload, camera | PPPP over UDP 32108: broadcast `LAN_SEARCH`, DUID handshake, DRW reliable channel (500 ms retransmit), `XZYH` announce + camera JSON, `AABB` BEGIN → 32 KB DATA → END with CRC16-XMODEM | `Sources/Pppp.swift` |
| H.264 decode | Annex-B stream from PPPP channel 1, VideoToolbox; session rebuilt only when SPS/PPS change | `Sources/H264Decoder.swift` |

Protocol quirks honored here:

- The upload's **END** frame is mandatory — without it the printer reports "transfer failed"
  even though every packet was acked.
- Only one PPPP transfer runs at a time, so the camera is paused during an upload and resumed
  afterwards.
- MQTT is QoS 0, so important commands are sent three times ~0.4 s apart.

## Limitations

- **LAN only** — no Anker relay / remote punch-through. Be on the same network as the printer.
- The MQTT broker's TLS certificate is not verified (it presents a self-signed cert, matching
  the reference clients).
- Pause / resume / stop rely on the `1008` command format captured from the reference build.
- The app is ad-hoc signed, not notarized. On first launch use **right-click → Open** (or
  `xattr -dr com.apple.quarantine "EufyMake Sender.app"`).

## Troubleshooting

| Symptom | Try |
|---|---|
| *Monitor offline* | **Reconnect**; make sure the printer is on and the account is signed in |
| Printer not in the device menu | Same Wi-Fi/LAN; press the refresh button in the header |
| Camera stays black | Press **Start**; the camera is paused during uploads and resumes after |
| Upload finishes but nothing prints | Check the Activity log for `[Pppp]` END/report errors |
| Sign-in window blank | Close it and press **Sign in** again |

## Credits

- [ankermake-m5-protocol](https://github.com/geeksville/ankermake-m5-protocol) — the original
  community protocol notes.
- [bobbyb/eufyMake-PrusaSlicer-Release-ARM](https://github.com/bobbyb/eufyMake-PrusaSlicer-Release-ARM)
  — protocol documentation and reference implementation this app is ported from.

## Disclaimer

This is an unofficial, community-built tool. It is not affiliated with, endorsed by, or
supported by Anker or eufy. The protocol used here was reverse-engineered; use it at your own
risk.

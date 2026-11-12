# Tender for Frigate

Native iOS client for [Frigate NVR](https://frigate.video), built from the mockups in `design/`.
Tender is an independent app, compatible with Frigate NVR; it is not affiliated with or endorsed by the Frigate project.
Requires iOS 17 and Xcode 26 or newer. No third-party dependencies.

> **This app is fully vibe coded.** Every line of code, the Xcode project, the TestFlight setup and
> this README were written by an AI coding agent (Claude Code) from the design mockups and plain-language
> feedback, then tested in the iOS Simulator against a real Frigate 0.18 server. No code was written by hand.
> Expect rough edges, and review the code before trusting it with anything important.

## TestFlight

https://testflight.apple.com/join/s6KEWhy1

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/1-live.png" width="200"><br><sub>Live</sub></td>
    <td align="center"><img src="docs/screenshots/2-camera.png" width="200"><br><sub>Camera</sub></td>
    <td align="center"><img src="docs/screenshots/3-review.png" width="200"><br><sub>Review</sub></td>
    <td align="center"><img src="docs/screenshots/4-event.png" width="200"><br><sub>Event</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/5-history.png" width="200"><br><sub>History</sub></td>
    <td align="center"><img src="docs/screenshots/6-playback.png" width="200"><br><sub>Playback</sub></td>
    <td align="center"><img src="docs/screenshots/7-timeline.png" width="200"><br><sub>Timeline</sub></td>
    <td align="center"><img src="docs/screenshots/8-settings.png" width="200"><br><sub>Servers</sub></td>
  </tr>
</table>

## Run

```bash
open Frigate.xcodeproj
```

Pick an iPhone simulator and run. On first launch the app scans the local network for Frigate
servers (ports 8971 and 5000) and lets you add one. Several servers can be added; the Live,
Review and History tabs can show one server or all of them.

## Features

| Screen | What it does |
| --- | --- |
| Live | Camera grid with refreshing snapshots, live objects and last activity; camera groups from the Frigate config |
| Camera | Live stream through go2rtc (MSE over websocket, WebRTC and MJPEG as fallbacks), audio, snapshot, PTZ (ONVIF cameras), fullscreen, today's events |
| Review | Alerts, detections and motion across servers; filter by server, camera, label and unreviewed; mark reviewed |
| Event | Clip playback with the event range highlighted, 1x/2x/4x, score, zones, object lifecycle, download/share, delete |
| History | Activity per camera for any day (motion plus events), calendar that marks days with recordings |
| Playback | Recordings per camera and day, event list or scrubbable vertical timeline with zoom, filters by type, label and zone, save an event or a span around the playhead to Photos |
| Everywhere | Pinch to zoom on live and recorded video, swipe back, lighter streams on mobile data, English and Dutch (follows the iPhone language) |
| Settings | Servers (add, edit, remove), combined review |

Credentials are stored in the Keychain. When a username is set the app logs in through
`/api/login`; unauthenticated ports work without one. An optional remote address is used when
the primary address is unreachable.

## Implementation notes

- **Recordings are played in one-hour chunks.** Frigate's `/vod` endpoint returns 503 for ranges
  longer than about three hours. Chunks start on a recording segment boundary so the player
  position maps exactly to wall-clock time (`RecordingMap` in `PlaybackView.swift`).
- **HEVC recordings.** Many cameras deliver H.265 tagged `hev1`, which AVPlayer refuses over HLS.
  `HLSProxy` serves VOD through `127.0.0.1` and rewrites the init segment to `hvc1`; downloaded
  clips get the same patch. This is the same effect as Frigate's `-tag:v hvc1` recording option.
- **Motion activity** is requested per camera: when several cameras are requested at once, Frigate
  merges them into one series.

## Deep links

Useful for testing and shortcuts:

```
frigate://add?url=http://192.168.1.21:8971&name=Home
frigate://live | review | history | settings
frigate://review?view=motion
frigate://camera/<camera>[?server=<name>]
frigate://playback/<camera>[?review=<id>&view=timeline]
frigate://event/<review id>
```

## Not yet implemented

- Two-way audio (Talk button is disabled).
- Push notifications (Frigate notifications need APNs or web push; the "notifications per server"
  toggle from the mockup is left out).

## TestFlight

```bash
scripts/testflight.sh
```

Archives with a timestamp build number, signs with the "Frigate App Store" profile and uploads.
App Store Connect: "Tender for Frigate" (bundle ID `nl.wiebenieuwenhuis.frigate`, team EBTM3728EJ);
the internal group "Intern" gets every build automatically.

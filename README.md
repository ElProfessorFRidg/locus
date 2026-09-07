# Locus

Free and open-source iPhone location teleport. Tap the map, search a place, or drive a route — Locus injects coordinates through Apple’s **developer location service** into `locationd`, so Maps and other apps see the spoofed GPS (not just a Wi‑Fi lookup that outdoor GPS will overwrite).

<p align="center">
  <img src="docs/screenshots/map.png" alt="Locus map with spoof pin" width="180" />
  <img src="docs/screenshots/spoofing.png" alt="Locus spoofing in 3D" width="180" />
  <img src="docs/screenshots/joystick.png" alt="Locus joystick controls" width="180" />
  <img src="docs/screenshots/route.png" alt="Locus route on map" width="180" />
</p>

## Features

- One-tap teleport (map pin or place search)
- **Built-in tunnel** — Locus raises the loopback tunnel itself, no second app to launch
- Live joystick — walk / run / cycle / drive with light speed variation
- **Routes built by dragging them** — lettered markers on the map, stops along the way, tap an alternative to take it
- Walk/Drive routing on real roads & footpaths (MapKit), with Apple's alternatives compared by "+4 min, −1.2 km"
- Snap a finger-drawn path onto real roads, keeping its shape
- A trip summary when you arrive: distance, time, average, fuel — and one tap to drive it again or drive it back
- **Driving parameters** — respect the limit +10%, acceleration and braking, corner grip, traffic, junction stops, GPS scatter, lane offset, 0.5×–8× playback, loop / back-and-forth
- Named driving profiles, saved routes, and resume after an interrupted drive
- Route coloured by estimated limit before you drive it, with per-stretch corrections
- Live speedometer with a speed-limit sign, plus a Lock Screen / Dynamic Island Live Activity
- Playback speed changes mid-drive from the HUD, and the screen stays on while you watch
- Siri and Shortcuts — teleport, stop, connect the tunnel, switch profile
- Draw a path, or import / export GPX (timestamps replayed at their recorded pace)
- Background keep-alive + live status bar + drop alerts
- Paste a coordinate or a Maps link into search; long-press the status bar to copy, link or share where you are
- Precision placement — pan under a crosshair, then nudge the pin 1 / 5 / 25 m at a time
- Favorites & recents
- First-run setup walkthrough
- Liquid Glass UI on iOS 26, with a matched material fallback on 18–25
- Fully on-device — no analytics, nothing uploaded

## Driving a route

Routes are played through a small vehicle model rather than replayed point by point. A look-ahead controller brakes *into* corners and stops instead of snapping speed at them, and everything that shapes it is a parameter:

| | |
| --- | --- |
| **Speed** | Estimated road limit, a fixed speed, or the travel mode's pace |
| **Tolerance** | The `+10%` dial (−30% … +50%), with a live preview of what each sign becomes |
| **Car** | Presets, or set acceleration, braking and a cornering grip budget yourself |
| **Traffic** | Clear → gridlock, as a slow random walk rather than a flicker |
| **Stops** | Junction stops, how often you're caught, how long you wait |
| **Realism** | Speed wobble, GPS scatter, lane offset, drive on the left |
| **Playback** | 0.5×–8× time, 0.5–4 Hz fix rate, start delay, loop / back-and-forth / return once |

Keep several of these as named **profiles** — a commute and a walk in the park want opposite settings — and switch instead of retuning. Four ready-made ones are offered.

**Speed limits are estimated, not looked up.** MapKit publishes no posted-limit data. Locus derives a limit from the pace Apple expects for the route combined with how the road bends and how often it turns, then snaps the result to values roads are actually signed at (30/50/90/130, or 25/35/55/70 in mph). Treat it as a good reading of the road, not a legal figure.

Because it's an estimate, the route is **coloured by limit on the map** before you drive it, and any stretch it gets wrong can be **corrected by hand** from the route sheet — the drive then uses your number. Routes are saveable, corrections and all, and a drive that gets interrupted can be picked up where it stopped.

A **GPX with timestamps** can be replayed at the pace it was actually recorded at, stops included.

While a route plays, speed, the limit sign and progress appear on the **Lock Screen and Dynamic Island**, and **Siri / Shortcuts** can teleport to a saved place, stop spoofing, connect the tunnel or switch profile.

## Install

See [SETUP.md](SETUP.md) for full steps. Grab a prebuilt IPA from [Releases](https://github.com/ChrisMack32/Locus/releases), or build from source below.

### Builds from CI

Every push builds an unsigned IPA and publishes it to a **Release**, as the raw `.ipa` — not wrapped in a zip, so a sideloader can install it straight from the link.

| Branch | Download |
| --- | --- |
| `main` | `https://github.com/ElProfessorFRidg/locus/releases/download/latest/Locus.ipa` |
| any other branch | `.../releases/download/latest-<branch-with-dashes>/Locus.ipa` |
| tagged `v*` | `.../releases/download/<tag>/Locus-<tag>.ipa` |

Branch builds use a **rolling** release: the tag is replaced on every push, so the URL never changes and there's exactly one build to grab rather than a list to date-sort. Each run also prints its own download link in the Actions summary.

CI fails the build if either extension is missing from the IPA, so a release can't silently ship without the built-in tunnel or the Live Activity.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often don’t work inside LiveContainer. Use one of these:

1. Long-press **Locus** → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share the pairing file **into LiveContainer → Locus**.
3. Copy the RPPairing plist contents → in Locus use **Paste RPPairing from clipboard** (setup or Settings).

## How it works

Locus uses the MIT-licensed [idevice](https://github.com/jkcoxson/idevice) FFI to talk to Apple’s DVT location simulation over an on-device developer tunnel (the same class of mechanism Xcode uses).

**iOS 27:** Settings → **Pair on this iPhone** advertises `_remotepairing-pairable-host._tcp`. Confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host — no computer.

**iOS 18–26:** import an **RPPairing** file once from [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).

### Links Locus understands

Paste any of these into the search field, or open them from another app:

```
48.85837, 2.29448              48.85837 2.29448        48°51'30.1"N 2°17'40.1"E
geo:48.85837,2.29448           geo:0,0?q=48.85837,2.29448(Eiffel Tower)
https://maps.apple.com/?ll=48.85837,2.29448
https://www.google.com/maps/place/Eiffel+Tower/@48.85837,2.29448,17z
https://www.openstreetmap.org/#map=17/48.85837/2.29448
locus://pin?lat=48.85837&lon=2.29448&name=Eiffel%20Tower
locus://teleport?lat=48.85837&lon=2.29448
```

`locus://pin` only drops the pin; `locus://teleport` sets the location. Both bring Locus to the front, so nothing happens without you seeing it. Long-press the status bar (or any saved place) to copy coordinates, copy a `locus://` link back, open the spot in Maps, or share it.

### The tunnel

Reaching that service needs a loopback tunnel — an interface the phone can talk to *itself* on at `10.7.0.1`. Locus ships one as a packet-tunnel extension, so setup is a single **Turn on the tunnel** button and iOS' one-time VPN approval. Nothing leaves the device: the tunnel forwards no traffic anywhere.

If the first packet-rewrite strategy can't pass traffic on your network, Locus tries the rest and keeps the one that works. Settings → **Tunnel** shows which is live, and the tunnel log shows what the extension itself reported.

**When the built-in tunnel can't run, Locus says so and points at LocalDevVPN.** Locus is sideloaded, so the entitlements in this repo are a request, not a fact — whatever re-signs the IPA decides whether they were granted, and Apple only grants `packet-tunnel-provider` to paid developer accounts. Rather than failing later with "permission denied", Locus reads its own `embedded.mobileprovision` at launch and reports, in the status bar and in Settings:

- **no extension in the bundle** — LiveContainer, or a re-signer that dropped plug-ins;
- **entitlement not granted** — re-signed with a free profile (the ~7-day expiry gives it away, and it's called out);
- **iOS refused the VPN configuration** — a declined prompt, or a stale profile.

Each one opens an explanation with a **Get / Open LocalDevVPN** button and exactly what this copy was signed with. [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) raises the same tunnel on `10.7.0.1`, so Locus works with whichever one is up.

A missing **App Group** is reported separately as a warning, not a blocker: it only costs the tunnel's diagnostic log, and everything else keeps working.

Start a teleport on Wi‑Fi first; the session can keep working on cellular afterward.

### Pokémon GO & similar games

Locus spoofs location the same way Xcode’s developer tools do: it tells iOS “you’re here,” and other apps read that from the system. Apps that just trust GPS (Apple Maps, etc.) will follow it.

**Pokémon GO is different.** It runs its own location checks and often rejects developer / simulated GPS (e.g. “Failed to detect location”). That’s expected with this method, not a Locus bug, and there’s no supported fix for it in this app.

Tools like **iPogo** (and similar modified clients such as SpooferPro) work differently: they’re a **modified Pokémon GO app**, not a system-wide location spoof. Features live *inside* that altered game client, instead of feeding coordinates through iOS for every app. Locus never patches or replaces Pokémon GO; it only changes what the system reports. So those tools can appear to “work in Pokémon GO” while Locus correctly drives Maps but still gets blocked by Pokémon GO’s checks.

Locus is for system-level teleporting. It isn’t a Pokémon GO client or an anti-cheat bypass.

## Build

Building from source needs an Apple Developer account for code signing. The published IPA does **not** — just sideload it.

> **Network Extension capability.** The built-in tunnel is a packet-tunnel extension, and Apple only grants `packet-tunnel-provider` to **paid** developer accounts. With a free Apple ID the `LocusTunnel` target won't sign; drop it from `project.yml` (remove the target and the app's `dependencies` entry) and Locus falls back to the LocalDevVPN app at runtime — `TunnelController` detects the missing `.appex` and says so.
>
> The App Group `group.com.chrismack.locus` is only used for the tunnel's diagnostic log. If it isn't provisioned, the log is empty and Settings says why; nothing else changes.

`project.yml` is the source of truth. `Locus.xcodeproj` is generated from it and is **not** in the repo — a committed copy goes stale whenever a target moves, and a stale one builds an app with no `LocusTunnel` extension without telling you. Run `xcodegen generate` first; CI does the same on every run.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed: `brew install xcodegen`
2. Set your **Team ID** in `project.yml` (`DEVELOPMENT_TEAM`), *or* pick your team under Xcode → Signing & Capabilities after generating the project.
3. Generate and open:

```bash
xcodegen generate
open Locus.xcodeproj
```

Or build from the CLI (replace with your Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership):

```bash
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

## Credits & license

MIT. `Vendor/idevice` contains the idevice FFI (MIT).

The built-in tunnel (`LocusTunnel/`) is **based on and uses code from [LocalDevVPN](https://github.com/ElProfessorFRidg/LocalDevVPN) (formerly StosVPN)** by Stossy11 and the SideStore Team, used under the StosVPN License. The packet-rewrite strategies and the cellular-rebind workaround come from that project; the method ladder, the connectivity-confirmed connect and the runtime bundle-ID discovery are Locus'. The same attribution appears in the app under Settings → About.

Locus is an independent open-source project and is not affiliated with Mirage / Wapixel.

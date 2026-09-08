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
- Walk/Drive routing on real roads & footpaths (MapKit), alternatives badged **Fastest** / **Shortest** and compared by "+4 min, −1.2 km"
- Snap a finger-drawn path onto real roads, keeping its shape
- **Saved routes you can pick from** — each row draws its own shape, says where it runs between, and is filterable by either; swipe to drive, duplicate or rename
- **What a route involves before you drive it** — stops, waiting time, speed band, and how many bends the grip budget rather than the sign decides
- A trip summary when you arrive: distance, time, average, fuel — and one tap to drive it again or drive it back
- **Driving parameters** — respect the limit +10%, acceleration and braking, corner grip, traffic, junction stops, GPS scatter, lane offset, 0.5×–8× playback, loop / back-and-forth
- Named driving profiles, saved routes, and resume after an interrupted drive
- Route coloured by estimated limit before you drive it, with per-stretch corrections
- Live speedometer with a speed-limit sign, plus a Lock Screen / Dynamic Island Live Activity
- Playback speed changes mid-drive from the HUD, and the screen stays on while you watch
- Siri and Shortcuts — teleport, **drive a saved route by name**, stop, connect the tunnel, switch profile
- Draw a path, or import / export GPX (timestamps replayed at their recorded pace)
- Background keep-alive + live status bar + drop alerts
- Paste a coordinate or a Maps link into search; long-press the status bar to copy, link or share where you are
- Precision placement — pan under a crosshair, then nudge the pin 1 / 5 / 25 m at a time
- Favorites & recents
- First-run setup walkthrough
- Liquid Glass UI on iOS 26, with a matched material fallback on 18–25
- **Two interfaces** — the full one, and a Fun mode for someone who has never sideloaded anything
- Fully on-device — no analytics, nothing uploaded

## Two interfaces

Locus' interface is for whoever sideloaded it: a map with everything floating on
it, a route planner with lettered stops and per-stretch corrections, thirty-odd
driving parameters, and a settings screen that reports the tunnel method, the
interface it went over and what this copy was signed with. That is the right
answer for the person who got the IPA onto the phone. It is not the answer for
whoever they hand the phone to.

So there is a second one. **Settings → Interface → Switch to Fun mode.**

It is not the same screens with the hard parts hidden — it is a different app
over the same engine:

| | Locus | Fun mode |
| --- | --- | --- |
| Shape | One map, chrome floating on it | Four tabs, one question each |
| Going somewhere | Drop a pin, then Teleport | Tap a spot, or search and you're there |
| Saved places | A named list | A grid of emoji you recognise before you read |
| Walking speed | Speed source → fixed speed → units → travel mode | One dial, 1–40 km/h, with 🐢 🚶 🏃 🚴 on it |
| A journey | Stops, alternatives, limit corrections, saved routes | Two ends you tap, stops in between, 🐢 / 🚗 / ⚡ |
| Where you are | A pin, and a status bar reading coordinates | Both dots on one map, and how far apart they are |
| Walking around | A joystick in the tray | The pad sits on the map, and dragging it sets you off |
| Playback | `timeScale`, 0.5×–8× | The same three chips, mid-trip |
| The connection | Tunnel status, method, interface, entitlement, log | **Ready**, or **Tap to switch on** |
| Palette | Glass over a dark map | Its own — indigo, pink, mint |

Fun mode drives with its own parameters and **never writes to the profiles you
tuned**: they are handed to the engine as an override while it is on screen and
dropped when it isn't. Your places, your pairing and your tunnel are shared —
star something in one and it is in the other, with the emoji kept.

The way back is the first card of its **You** tab, and it asks before it
switches. Pro stays the default: an existing install opens exactly where it
always did.

Everything Fun mode can't do, Locus still can. Nothing was removed to build it.

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

**Speed limits are estimated, not looked up.** MapKit publishes no posted-limit data, so Locus reads the road two ways and snaps the answer to values roads are actually signed at — 20/30/50/70/80/90/110/130, or the mph equivalents.

First, the road's **number**, where the route names one. Continental Europe encodes the class in the prefix — A is an autoroute, N a nationale, D a départementale — so the number says what kind of road this is, which no amount of looking at its shape can. Each class gets a band, and the road's shape picks within it: the same D road is 90 through open country and 50 through a village. Suffixed numbers count too (A6a and A6b are the two halves of the A6 into Paris), and a stretch of road that MapKit doesn't name — "Keep left" — is claimed for the road either side when that is the only thing it can be, so an unnamed step can't punch a hole through the middle of a motorway. The letters mean other things in Britain, so this is trusted only where the units say the numbering holds.

Second, where no number is given, the road's **shape**: corner radius and how often it changes direction, scaled off the pace Apple expects for the route.

Treat the result as a good reading of the road, not a legal figure.

Because it's an estimate, the route is **coloured by limit on the map** before you drive it, and any stretch it gets wrong can be **corrected by hand** from the route sheet — the drive then uses your number. Routes are saveable, corrections and all, and a drive that gets interrupted can be picked up where it stopped.

Before committing forty minutes to a route, the sheet says what driving it will involve: how many junctions the car will sit at, how long for in total, the band of speeds the plan permits, and how many bends are decided by the grip budget rather than the sign.

**Saved routes are a list you can pick from.** Each row draws the route's own outline — you recognise your commute's shape the way you recognise a signature — next to where it runs between, resolved once when it's saved. Past four routes the list gains a filter (matching the endpoint names as well as the route's name, so "office" finds the one you called "Monday") and an order: recently driven, most driven, or longest. Swipe a row right to drive it, left to rename, duplicate or delete.

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

### Tests

```bash
xcodegen generate
xcodebuild test -project Locus.xcodeproj -scheme LocusTests \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

`LocusTests` is a logic bundle with **no host application**, on purpose. The app links `Vendor/idevice`, an arm64 device-only static library, so anything hosted by it can't build for a simulator at all — and a test bundle that only runs on a paired iPhone is a test bundle nobody runs. This one compiles the pure files directly: no UIKit, no SwiftUI, no FFI, nothing that needs a device to be true. That constraint is why `TravelMode`, `DriveFormat`, `RoadClass`, `RouteShape`, `SavedRouteOrder` and `RouteComparison` have files of their own.

CI runs it before the archive, so a failing assertion stops the build rather than publishing an IPA nobody has reason to trust. What it covers, and why those parts:

| | |
| --- | --- |
| **`CoordinateParser`** | Its failure mode is silent — a false positive swallows a place search and drops a pin in the Gulf of Guinea. Every shape it accepts, and every one it must refuse. |
| **Persistence** | Synthesised `Codable` throws on one missing key and the loaders answer a throw with an empty list, so "a field was added" and "every route you saved is gone" are one bug apart. |
| **Geometry** | Pure maths with answers you can check by hand: a 3-4-5 offset measuring 500 m, a 200 m circle measuring 200 m, coordinates that aren't coordinates. |
| **The driving model** | Fixed-speed plans, stopping at the end, resuming halfway, corrections beating the estimate — and every stored parameter clamped where the engine reads it. |
| **Choosing a route** | Which route "office" finds, what sits at the top of the list, which alternative gets badged. |
| **Reading a road number** | What separates an autoroute from a distance in metres is one lookahead in a regex, and getting it wrong would silently poison every limit on the route. Every prefix, every suffix, and both directions of the rule that claims an unnamed stretch. |
| **Fun mode's dial** | It is the one speed in the app set by dragging rather than typed, and nothing downstream re-reads what it meant. Every band, both units, and that the profile it builds needs none of the engine's clamps. |

Two bugs that had been shipping fell out of the suite's first run — every bend reading as twice as open as it is, and an inverted wait range collapsing instead of swapping — and several more were caught in new code before it ever shipped. Each is described in the commit that fixed it.

## Credits & license

MIT. `Vendor/idevice` contains the idevice FFI (MIT).

The built-in tunnel (`LocusTunnel/`) is **based on and uses code from [LocalDevVPN](https://github.com/ElProfessorFRidg/LocalDevVPN) (formerly StosVPN)** by Stossy11 and the SideStore Team, used under the StosVPN License. The packet-rewrite strategies and the cellular-rebind workaround come from that project; the method ladder, the connectivity-confirmed connect and the runtime bundle-ID discovery are Locus'. The same attribution appears in the app under Settings → About.

Locus is an independent open-source project and is not affiliated with Mirage / Wapixel.

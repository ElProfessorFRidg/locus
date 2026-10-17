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
- **Direct simulation on TrollStore and jailbroken phones** — Geranium's LocSim method: no pairing file, no tunnel, and the location stays put after Locus is closed
- **Built-in tunnel** — Locus raises the loopback tunnel itself, no second app to launch
- **Network mode** — no pairing file, no Developer Mode, no proxy app: Locus rewrites Apple's Wi‑Fi/cell positioning replies itself, inside its own tunnel
- Live joystick — walk / run / cycle / drive with light speed variation
- **Routes built by dragging them** — lettered markers on the map, stops along the way, tap an alternative to take it
- Walk/Drive routing on real roads & footpaths (MapKit), alternatives badged **Fastest** / **Shortest** and compared by "+4 min, −1.2 km"
- Snap a finger-drawn path onto real roads, keeping its shape
- **Saved routes you can pick from** — each row draws its own shape, says where it runs between, and is filterable by either; swipe to drive, duplicate or rename
- **What a route involves before you drive it** — stops, waiting time, speed band, and how many bends the grip budget rather than the sign decides
- A trip summary when you arrive: distance, time, average, fuel — and one tap to drive it again or drive it back
- **Driving parameters** — respect the limit +10%, acceleration and braking, corner grip, traffic, junction stops, GPS scatter, lane offset, 0.5×–8× playback, loop / back-and-forth
- Named driving profiles, saved routes, and resume after an interrupted drive
- **What you've changed** — every parameter that differs from standard, listed at the top of the sheet, each one a tap to put back
- Route coloured by estimated limit before you drive it, with per-stretch corrections
- Live speedometer with a speed-limit sign, plus a Lock Screen / Dynamic Island Live Activity
- Playback speed changes mid-drive from the HUD, and the screen stays on while you watch
- Siri and Shortcuts — teleport, **drive a saved route by name**, stop, connect the tunnel, switch profile
- Draw a path, or import / export GPX (timestamps replayed at their recorded pace)
- Background keep-alive + live status bar + drop alerts
- Paste a coordinate or a Maps link into search; long-press the status bar to copy, link or share where you are
- Precision placement — pan under a crosshair, then nudge the pin 1 / 5 / 25 m at a time
- **Pro mode** — a live "what apps see" readout: the fix Core Location really delivers, whether iOS flags it as simulated, accuracy, and how far it is from what Locus asked for
- Favorites & recents
- First-run setup walkthrough
- Liquid Glass UI on iOS 26, with a matched material fallback on 18–25
- **Two interfaces** — the full one, and a Fun mode for someone who has never sideloaded anything
- Correct placement in mainland China, where Apple's map is drawn in GCJ-02
- Time zone follows the teleport
- Fully on-device — no analytics, nothing uploaded

## Two interfaces

Locus' interface is for whoever sideloaded it: a map with everything floating on
it, a route planner with lettered stops and per-stretch corrections, thirty-odd
driving parameters, and a settings screen that reports the tunnel method, the
interface it went over and what this copy was signed with. That is the right
answer for the person who got the IPA onto the phone. It is not the answer for
whoever they hand the phone to.

The walkthrough asks which one you want on its last screen, so whoever is setting the phone up for someone else picks once, at the moment they are already thinking about it. Afterwards: **Settings → Interface → Switch to Fun mode.**

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

Locus needs **iOS 17.0 or later**.

### Builds from CI

Every push builds the app once and publishes it to a **Release** four ways — each the raw file, not wrapped in a zip, so it installs straight from the link:

| File | For | Sets the location through |
| --- | --- | --- |
| `Locus.ipa` | Any sideloader (unsigned — it re-signs it) | The developer tunnel |
| `Locus.tipa` | TrollStore; or a jailbreak with TrollStore / AppSync | `locationd` directly |
| `Locus-rootless.deb` | Rootless jailbreaks (Dopamine, palera1n, nathanlr) | `locationd` directly |
| `Locus-rootful.deb` | Rootful jailbreaks (palera1n rootful) | `locationd` directly |

| Branch | Download |
| --- | --- |
| `main` | `https://github.com/ElProfessorFRidg/locus/releases/download/latest/Locus.ipa` (or `Locus.tipa`, `Locus-rootless.deb`, `Locus-rootful.deb`) |
| any other branch | `.../releases/download/latest-<branch-with-dashes>/Locus.ipa` (same names) |
| tagged `v*` | `.../releases/download/<tag>/Locus-<tag>.ipa` (`.tipa`, `-rootless.deb`, `-rootful.deb`) |

Branch builds use a **rolling** release: the tag is replaced on every push, so the URL never changes and there's exactly one build to grab rather than a list to date-sort. Each run also prints its own download link in the Actions summary.

CI fails the build if either extension is missing from the IPA, so a release can't silently ship without the built-in tunnel or the Live Activity. It also fails if the `.tipa` isn't signed with `com.apple.locationd.simulation`, if any of its three binaries is unsigned, if it asks for more than iOS 17.0, or if either `.deb` puts the app anywhere but where its jailbreak keeps applications.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often don’t work inside LiveContainer. Use one of these:

1. Long-press **Locus** → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share the pairing file **into LiveContainer → Locus**.
3. Copy the RPPairing plist contents → in Locus use **Paste RPPairing from clipboard** (setup or Settings).

## How it works

Locus has two engines, and picks the one this copy can use.

### Direct — TrollStore and jailbroken phones

Apple's location simulation lives in `locationd`, behind a private class, `CLSimulationManager`, and one entitlement, `com.apple.locationd.simulation`. Xcode reaches it through a developer service on the phone that holds that entitlement. An app that holds it itself can make the same calls from its own process — which is what [Geranium](https://github.com/c22dev/Geranium)'s LocSim does, and what Locus does when it can.

No sideloader can grant that entitlement. TrollStore can, and so can a jailbreak, so `Locus.tipa` and the `.deb`s are signed with it. At launch Locus asks the kernel what its own code signature actually holds (`SecTaskCopyValueForEntitlement`) — not what a provisioning profile says, and not how it was installed — so any route that keeps the entitlement works, and any route that strips it (a sideloader re-signing the `.tipa`) quietly falls back to the tunnel.

What that changes:

- **Nothing to set up.** No pairing file, no tunnel, no VPN prompt; the walkthrough is two screens.
- **It stays set.** The simulation is `locationd`'s, not a connection Locus holds open, so it survives Locus being closed — exactly as in Geranium. Locus remembers it (and which boot it belongs to), so reopening shows where you are, with Stop.
- **More than coordinates.** The developer service takes a latitude and a longitude. `CLSimulationManager` takes a whole `CLLocation`, so routes and the joystick report their **speed and heading** to every app, a stop reports zero, and an **altitude** can be set in Settings → Location.
- **Checked, not assumed.** `CLSimulationManager` returns nothing, and a `locationd` that ignores the caller ignores it silently. So after the first teleport Locus asks CoreLocation where the phone now is; if it is still somewhere else, Locus says so and points at the tunnel. Settings → Location shows the verdict and can check again.
- **Stop sticks.** Stopping is sent three times, a moment apart — Geranium has a setting for this because one stop sometimes doesn't take.

Bookmarks saved in Geranium or Mika's LocSim can be imported from Settings → Location.

### Both engines

- **China.** In mainland China Apple's map is drawn in GCJ-02, a mandated offset of a few hundred metres, and every tap, search result and route MapKit hands back is in it. Locus converts at the edge — map → WGS-84 when a location is sent, WGS-84 → map for CoreLocation's own fix and for GPX files — so a teleport lands on the pin. Automatic by default, and limited to mainland China (not Hong Kong, Macau, Taiwan, Korea or Japan, all of which the usual single rectangle wrongly covers); Settings → Location can force it on or off.
- **Time zone.** After a teleport Locus asks iOS to re-derive the time zone from the new location, so the clock moves with you when Date & Time is set automatically. Settings → Location → *Time zone follows the location*.

### Tunnel — everything else

Locus uses the MIT-licensed [idevice](https://github.com/jkcoxson/idevice) FFI to talk to Apple’s DVT location simulation over an on-device developer tunnel (the same class of mechanism Xcode uses).

**iOS 27:** Settings → **Pair on this iPhone** advertises `_remotepairing-pairable-host._tcp`. Confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host — no computer.

**iOS 18–26:** import an **RPPairing** file once from [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).

### Network mode

The developer method above is the better one when you can pair. Network mode is for when you can't, or don't want to: **no RPPairing file, no Developer Mode, and no Shadowrocket / Surge / Loon.**

iPhones work out where they are partly by reading the Wi‑Fi access points and cell towers around them and asking Apple where each one is (`/clls/wloc`). Network mode answers that question itself, with the place you picked. It does it entirely on the device, through the same packet-tunnel extension Locus already ships:

1. The tunnel tells iOS to resolve **only Apple's location hosts** through it. The packet loop answers those DNS questions with the tunnel's own address (it builds the reply packet itself — no socket, no port 53).
2. TCP 443 to that address is steered to a TLS listener in the extension. The existing address swap already hands such connections to the device's own kernel, so there is no userspace TCP stack.
3. The listener forwards each request to the real server and rewrites the coordinates in the `/clls/wloc` reply — latitude, longitude and accuracy, nothing else. Other requests on those hosts, and any reply that doesn't parse, pass through untouched. It will only ever talk to the five allow-listed hosts.

Setup is in **Settings → Spoofing method → Network → Set up network mode**: create the certificate, install it, switch it on under *Certificate Trust Settings*, and run the built-in test, which reports whether certificate, tunnel, DNS and proxy each work.

**About the certificate.** It is generated on the device. The authority is name-constrained to Apple's location hosts, and its private key is thrown away as soon as it has signed the one leaf certificate — nothing can be issued from it afterwards, and it cannot vouch for any other site.

**Limits, honestly:**

- It changes **Wi‑Fi and cell-tower positioning only**. With a clear sky, GPS can still report where you really are; indoors, it usually follows.
- iOS re-asks only now and then. After teleporting, turn Location Services off and on (or toggle Airplane Mode) to make it ask straight away.
- It **teleports**; it doesn't move. Routes and the joystick are best on the developer method.
- It needs **Locus' own tunnel**, so the same signing requirement as the built-in tunnel applies (a paid developer account). LocalDevVPN can't provide it.
- The method was reimplemented from the idea behind [ios-location-spoofer](https://github.com/mekos2772/ios-location-spoofer) (itself built on [acheong08/ios-location-spoofer](https://github.com/acheong08/ios-location-spoofer)); no code was copied.

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

### Remote control (jailbreak)

For a jailbroken device driven from outside — a script, or a web UI that runs `uiopen` over ssh. It needs the **direct** engine and the `.deb`/`.tipa` signed by CI, which carries a sandbox exception for `/var/jb/var/locate-ipad/` (rootless layout; the other builds don't have it, and the commands below then answer "remote control disabled").

```
locus://drive?to=<lat>,<lon>[&from=<lat>,<lon>][&mode=drive|walk|cycle][&profile=<name>][&speed=0.5-8][&loop=0|1|2]&key=<key>
locus://route?name=<saved route name>&key=<key>
locus://stop?key=<key>
locus://go?lat=<lat>&lon=<lon>&key=<key>
```

- **drive** builds a MapKit route and plays it. `from` defaults to the simulated position, else the real one; coordinates are in the same space as `locus://teleport`. `mode` defaults to `drive`; `cycle` is the app's cycle mode (MapKit still routes it as a car). `profile` is the exact name (case-insensitive) of an existing driving profile — an unknown one is an error, not a fallback. `speed` is the playback time scale. `loop`: 0 stop at the end, 1 loop, 2 back and forth. Profile, speed, loop and mode apply to that drive only; saved profiles and the mode picker are left alone.
- **route** plays the saved route with that name (case-insensitive; if several match, the most recently driven).
- **go** teleports to the coordinates, like the Siri intent, without needing any screen to be showing (unlike `locus://teleport`, which only a mounted map handles). Same coordinate space as `teleport`; the result lands in `lastCommand` (`name: "go"`).
- **stop** stops routes, joystick and simulation.
- Names must be URL-encoded (`%20` for a space), at most 120 characters. Anything malformed, repeated, unknown or out of range is refused.
- `teleport` and `pin` work as before, with no key (and need the map on screen).

**The key.** Put a secret in `/var/jb/var/locate-ipad/locus.key` (first line, surrounding whitespace ignored) and pass it as `key=`. If the file is missing, unreadable or empty, remote control is off; a wrong key is ignored. Either way nothing moves and the reason lands in `lastCommand` below. The key is compared in constant time and never logged.

**State files**, rewritten atomically (temp file, then rename) in `/var/jb/var/locate-ipad/`, silently skipped if the directory isn't there:

- `locus-state.json` — `ts`, `engine` (`direct`/`tunnel`), `status` (`idle`/`connecting`/`active`/`reconnecting`/`dropped`), `simulating`, `mode` (`idle`/`teleport`/`route`/`joystick`), `position` (`{lat,lon}`, WGS-84 as sent to the engine), `route` (`{name,progressPct,paused}`), `speedKmh`, `loop`, `timeScale`, `profile`, `tunnel` (`direct`/`up`/`down`/`n/a`), `lastCommand` (`{name,ts,ok,error}`), `error`, `version`. Unset fields are `null`. Written on every change (position at most once a second) and at least every 5 seconds while the app is running.
- `locus-routes.json` — the saved routes: `id`, `name`, `journey`, `distanceM`, `timesDriven`, `lastDriven` (epoch seconds or `null`). Rewritten at launch and whenever the list changes.

**Inbox (no URL, no screen).** For a launch with nothing to open, such as a helper starting Locus in the background on a locked device. Drop `/var/jb/var/locate-ipad/inbox/<id>.json` (id: 6-32 lowercase hex characters, matching the file name; regular file, at most 4 KB):

```
{"id":"a1b2c3d4","cmd":"go","args":{"lat":48.8584,"lon":2.2945}}
{"id":"a1b2c3d5","cmd":"drive","args":{"to":{"lat":0,"lon":0},"from":{"lat":0,"lon":0},"mode":"walk","profile":"On foot","speed":2,"loop":1}}
{"id":"a1b2c3d6","cmd":"route","args":{"name":"Commute"}}
{"id":"a1b2c3d7","cmd":"stop"}
```

The same validation as the URLs applies (`from`, `mode`, `profile`, `speed`, `loop` are optional). No key is needed: the directory is only reachable by processes with the file-access exception (and root), who could read `locus.key` anyway; URLs still require it. Locus reads the directory at launch, once a second while awake, when it comes to the front, and on the Darwin notification `com.aubin.locus.inbox` (`notifyutil -p com.aubin.locus.inbox`). Files are handled oldest first and deleted once read, valid or not; symlinks, directories and oversized files are ignored. Each gets `/var/jb/var/locate-ipad/results/<id>.json` (created if missing, pruned after 10 minutes):

```
{"id":"a1b2c3d4","cmd":"go","ok":true,"error":null,"ts":1760000000,"state":{ ...the locus-state.json object after the command settled... }}
```

It waits for the command to settle (teleport lands, route starts, stop completes) for at most 25 seconds. It needs no setup or pairing file when the direct engine is available. A drive started from a background launch relies on the background-location mode Locus already declares to keep the process running.

**Limits.** iOS delivers a URL to the app only when it is opened, so `uiopen` brings Locus to the foreground and the device has to be unlocked; there is no way to send a command to a suspended app. A drive keeps running once the app is backgrounded (it holds the background location session), but the state files only update while the app process is alive. The repo targets iOS 17.0 and later; this has only been written against that, not tested on any particular version.

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
| **What you've changed** | The summary of a profile is only worth reading if it is complete, and a parameter added to `DriveProfile` and forgotten in the table would silently never appear. Reflection checks the two lists still match, so that mistake fails the build instead of shipping. |
| **The China map offset** | Wrong one way, every teleport in China lands on the wrong block; wrong the other, every one in Seoul, Tokyo or Hong Kong does. Checked against the published reference pair, round-tripped to a millimetre, and asked about a dozen cities on both sides of the border. |
| **Bookmarks from Geranium and LocSim** | Two loosely typed plists from other apps. One malformed entry must cost that entry, not the import. |

Two bugs that had been shipping fell out of the suite's first run — every bend reading as twice as open as it is, and an inverted wait range collapsing instead of swapping — and several more were caught in new code before it ever shipped. Each is described in the commit that fixed it.

## Credits & license

MIT. `Vendor/idevice` contains the idevice FFI (MIT).

The built-in tunnel (`LocusTunnel/`) is **based on and uses code from [LocalDevVPN](https://github.com/ElProfessorFRidg/LocalDevVPN) (formerly StosVPN)** by Stossy11 and the SideStore Team, used under the StosVPN License. The packet-rewrite strategies and the cellular-rebind workaround come from that project; the method ladder, the connectivity-confirmed connect and the runtime bundle-ID discovery are Locus'. The same attribution appears in the app under Settings → About.

The direct engine follows [Geranium](https://github.com/c22dev/Geranium)'s LocSim by c22dev — the `CLSimulationManager` call sequence, the time-zone nudge, the repeated stop, and the GCJ-02 correction contributed there by acg7878. No Geranium source is included; the GCJ-02 formulas are the standard published ones.

Locus is an independent open-source project and is not affiliated with Mirage / Wapixel.

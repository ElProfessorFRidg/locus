# Locus — install & first teleport

## 1. Sideload the IPA

Install the latest IPA from [Releases](https://github.com/ChrisMack32/Locus/releases) (or build from source) with Feather, SideStore, AltStore, Sideloadly, or LiveContainer.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often break inside LiveContainer. Do one of the following:

1. Long-press **Locus** in LiveContainer → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share / open the pairing file **into LiveContainer → Locus** (iOS share sheet).
3. Copy the RPPairing plist contents, open Locus → **Paste RPPairing from clipboard** (setup or Settings).

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. When the second prompt appears, type the **6-digit code** Locus shows (also sent as a notification).
7. Done — RPPairing file is saved on-device.

### On iOS 18–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

## 3. The tunnel

Locus needs a loopback tunnel so it can reach this iPhone's own developer service at `10.7.0.1`. It ships with one.

### Built in (default)

During setup, tap **Turn on the tunnel**. iOS asks once to allow the VPN configuration — approve it. Nothing leaves the device: the tunnel forwards no traffic anywhere, it only lets the phone talk to itself.

If the first packet strategy can't pass traffic on your network, Locus tries the others and keeps whichever works. Settings → **Tunnel** shows which one is live, and **Tunnel log** shows what the extension itself reported.

### Fallback: the LocalDevVPN app

App extensions don't load in **LiveContainer**, so there is no built-in tunnel there. Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) and connect it instead (default tunnel IP `10.7.0.1`). Locus uses whichever tunnel is up, so the two are interchangeable.

## 4. Teleport

On Wi‑Fi: drop a pin → **Teleport**. Then joystick / routes / GPX work; the session can continue on cellular.

## 5. Driving a route

Routes → **Find route on roads**, pick one of Apple's alternatives, then **Drive this route**.

**Driving parameters** is where the route stops being a straight replay:

- **Speed** — drive to the estimated road limit, a fixed speed, or the travel mode's pace.
- **Tolerance** — the `+10%` dial. Presets for −10 / 0 / +5 / +10 / +20, and a live preview of what each sign becomes.
- **Car** — preset vehicles, or set acceleration, braking and a cornering grip budget yourself. Corners are braked into, not snapped at.
- **Traffic & stops** — density, junction stops and how long you're held at them.
- **Realism** — speed wobble, GPS scatter, lane offset, drive-on-the-left.
- **Playback** — 0.5×–8× time, fix rate, start delay, and loop / back-and-forth / return-once.

Speed limits are **estimated**, not looked up: MapKit publishes no posted-limit data, so Locus reads the pace Apple expects for the route together with how the road bends, and snaps the result to values roads are actually signed at.

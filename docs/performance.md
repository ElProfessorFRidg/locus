# Performance notes

What a pass over Locus for memory, storage and stalls turned up, what was
changed, and what was left alone and why. Ordered by how much it costs the
device, not by how hard it was to find.

The tunnel extension comes first throughout. It is the one part of Locus that
does not run in the app's address space, and iOS holds a `NEPacketTunnelProvider`
to a memory ceiling far below an app's — an allocation per packet or per log line
is not a rounding error there, it is the difference between a tunnel that stays
up and one jetsam takes down mid-drive.

## The tunnel

### Every log line was a container lookup, a formatter and two syscalls

`LocusTunnelStatusFile.write` did all of this per line:

- `containerURL(forSecurityApplicationGroupIdentifier:)` — a cross-process lookup
  into the container manager, for an answer that cannot change while the process
  lives.
- `ISO8601DateFormatter()` — built and thrown away. It is among the most
  expensive objects in Foundation to create.
- `FileHandle(forWritingTo:)` … `close()` — a file descriptor opened and closed
  around a single append.
- `trim()` unconditionally: an `attributesOfItem` stat on every line and, once
  the file passed 64 KB, a full `Data(contentsOf:)` read of all 64 KB followed by
  a rewrite — *on every subsequent line*.

Now: URL and formatter resolved once, one append handle held open, the length
tracked in memory, and the read-and-rewrite trim run only on the line that
actually crosses the cap.

### The path monitor logged on every update

`pathUpdateHandler` fires in bursts whenever the radio changes state, and each
one wrote a line to the App Group file. Only a path that reads differently from
the last one is logged now. The interface-name table it built per update is a
static.

### Every IPv4 packet was copied, whether or not it needed rewriting

`rewritePacket` took `Data.withUnsafeMutableBytes` *before* checking whether
either address matched. That call triggers copy-on-write on entry, so a packet
the tunnel then decided not to touch had already been malloc'd and memcpy'd. A
batch where nothing matched still rebuilt the whole array.

The address check now happens through a read-only `withUnsafeBytes`, and the
batch is handed back untouched when nothing was rewritten. `readBE16`/`readBE32`
take `UnsafePointer` so both paths share them.

### Teardown

`stopTunnel` cancelled the path monitor but left its handler — which captures
`self` — and the applied `NEPacketTunnelNetworkSettings` in place. Both are
released now.

## The app side of the tunnel

### `loopbackReachable` allocated to answer a yes/no

The status bar polls it every two seconds for as long as Locus is on screen. It
ran every interface on the device through `getnameinfo` into a 1 KB `[CChar]`
buffer, built a `String` per address, then did string prefix matching. It is one
32-bit compare per interface, and now that is what it does — `hasIPv4Address`
walks `getifaddrs` and compares `sin_addr` directly, allocating nothing.

### The probe's timeout outlived the probe

`probe()` scheduled a 5-second `asyncAfter` that fired whether or not the
handshake had already answered, holding the continuation and connection for the
full timeout. The method ladder runs six of these back to back. It is a
cancellable `DispatchWorkItem` now, cancelled the moment the probe resolves, and
the connection's `stateUpdateHandler` is cleared before cancelling.

## Drive playback

### Two `Timer`s were rebuilt four times a second

`apply` — which runs per simulated fix, up to 4 Hz for the whole length of a
route — called `startResend` and `startHealth`, and both began with
`invalidate()` before scheduling a fresh timer. Eight timer allocations and
sixteen run-loop edits a second, for two timers that should be created once.
They now no-op when one is already running; `stopResend`/`stopHealth` remain the
way they end.

### `isBusy` toggled twice per fix

`isBusy` exists to disable the Teleport button. Setting it true and false around
every route fix published two `objectWillChange` events per fix — and every view
observing the session redraws on those, including the map and its per-stretch
route overlay. `apply` now takes an `interactive` flag; only a teleport and the
joystick's first fix set it.

### The keep-alive was restarted per fix

`BackgroundKeepAlive.start()` ran `requestAlwaysAuthorization()` and
`startUpdatingLocation()` on every call, and `apply` calls it on every fix. It
tracks whether it is already running.

### The speeding haptic fired continuously

`if fix.isOverLimit, profile.hapticOnLimitChange` built a
`UIImpactFeedbackGenerator` and fired it *on every fix while over the limit* —
four buzzes a second for as long as you were speeding, thousands over a motorway
stretch. That is a real battery cost and, going by the property's own name
(`hapticOnLimitChange`), not what was meant. It now fires once on the crossing,
from a generator held for the session's lifetime.

**This is a deliberate behaviour change**, the only one in this pass.

## Storage

### The resume file rewrote the whole route every five seconds

`recordProgress` runs every five seconds for the length of a drive and wrote the
entire `RouteResumeState` each time — including its coordinate list, which for a
40 km route resampled for driving is several thousand points and a few hundred
kilobytes of JSON. The coordinates cannot change while the drive plays. Over an
hour that is hundreds of megabytes written to flash to record a distance that
fits in eight bytes.

The state is now split: `resume.json` holds the drive and is written when the
drive changes, `resume-progress.json` holds `travelled`, `lap` and `savedAt` and
is the only thing the five-second write touches. On load the progress is applied
over the route if it is newer. A `resume.json` written by an older build, with no
progress file beside it, still reads correctly on its own.

### Profiles were re-encoded on every frame of a slider drag

The settings sliders bind straight to the live `DriveProfile`, which writes back
through `DriveProfileStore.update` → `persist()` → a fresh `JSONEncoder`, the
whole profile array encoded, and a `UserDefaults` write. On a ProMotion display
that is up to 120 encodes a second where only the last one is kept. Writes from
that path are coalesced (250 ms) and flushed when Locus leaves the foreground;
structural edits — add, rename, delete — still write straight through. The
encoder is reused, here and in `RouteStore`.

## Stalls

### A slider drag replanned the whole route, per frame

The worst stall in the app. `MapHomeView` has
`.onChange(of: session.drive) { refreshPreview() }`, and `refreshPreview` runs
the entire planner — resample, corner radius and turn density at every point,
junction stops, a moving average over all of it — across the whole route, on the
main actor. `session.drive` changes on every frame of a slider drag, so a 40 km
route was being fully replanned sixty times a second while a finger moved, for
one picture at the end of it. Rebuilds are coalesced now; what finally gets drawn
is unchanged.

### GPX import compiled three regexes per track point

`coordinateFrom` built an `NSRegularExpression` for `lat` and another for `lon`,
and `timeFrom` built a third — inside the per-point loop. A ten-thousand-point
GPX compiled thirty thousand regex objects, on the main thread, which is most of
why importing a long recorded track felt like a hang. The three are compiled once
now.

## Found, not changed

### A probable leak in the FFI session

`LocationEngine.setLocked` does `remoteServer = nil` after
`location_simulation_new` succeeds, on the stated assumption that the call
consumes its server handle. `idevice.h` documents consumption explicitly where it
happens — `remote_server_new`: *"It is consumed and may not be used again"*;
`lockdown_location_simulation_new`: *"Ownership of the `IdeviceHandle` is
transferred"* — and says nothing of the sort for `location_simulation_new`. If it
borrows, as the header implies, Locus leaks one `RemoteServerHandle` and the
connection behind it per handshake, and the health timer re-handshakes after
every drop.

Left alone on purpose: if the Rust side *does* take ownership, freeing it is a
double free rather than a leak, and that cannot be settled from the header. It
needs checking against the idevice revision `libidevice_ffi.a` was built from.
If it borrows, the fix is one line — keep the pointer and let `cleanup()` free it
after the simulation, which is already the order it frees in.

### The planner still runs on the main actor

`RouteSimulator.plan` is pure and could move off the main thread, but its
`recordedSpeed` parameter is a non-`Sendable` closure, so it is not the one-line
change it looks like. Coalescing removed the repeated cost; a single plan of a
long route still blocks the main actor when a drive starts.

### `RoutePlan.stretches()` folds in O(n²)

The short-stretch fold restarts its scan after every merge and removes from the
middle of an array each time. It is bounded by the number of distinct limit runs
rather than by points, so it is milliseconds rather than the seconds the planner
itself costs — and it is behind the coalescing now. Worth a linear rewrite if the
preview ever needs to be interactive.

### Live Activity states are formatted then dropped

`SpoofSession.run` builds the `ContentState` — distance and ETA strings included
— on every fix and hands it to a controller that throttles to one update every
two seconds. About ten small string allocations a second are formatted and
discarded. Fixing it means either passing an autoclosure or letting the
controller do the formatting, and the module boundary that keeps formatting on
the app side is deliberate.

### `libidevice_ffi.a` is 95 MB in the tree

Most of it never reaches the binary — the linker pulls in only the archive
members it references — so this is a clone-size cost rather than an install-size
one. Worth measuring the linked `Locus.app` before reaching for build-setting
changes.

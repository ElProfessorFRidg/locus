# TrollStore build

Entitlements `ldid` signs into `Locus.tipa` in CI (see `.github/workflows/build.yml`).
They are not used by Xcode — the regular build keeps `Locus/Resources/Locus.entitlements`.

| Binary | Entitlements |
| --- | --- |
| `Locus` | `Locus.entitlements` — adds `com.apple.locationd.simulation` |
| `LocusTunnel.appex` | `../LocusTunnel/LocusTunnel.entitlements`, unchanged |
| `LocusWidgets.appex` | `LocusWidgets.entitlements` (none) |

With `com.apple.locationd.simulation` held, Locus sets the location through
`CLSimulationManager` directly — Geranium's LocSim method — and needs neither a
pairing file nor the loopback tunnel. Nothing else in the app changes.

The two extra entries beyond the simulation entitlement are read-only and only
serve **Settings → Location → Import from Geranium / LocSim**:

- App Group `group.live.cclerc.geraniumBookmarks` — where Geranium keeps its LocSim bookmarks.
- `com.apple.security.exception.files.absolute-path.read-only` on
  `/var/mobile/Library/Preferences/com.mika.LocationSimulation.plist` — Mika's LocationSimulation bookmarks.

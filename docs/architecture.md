# Architecture

ModRadio is a small native menu-bar app assembled as a standard signed macOS
application bundle.

- `Sources/ModRadio/` owns BassoonTracker discovery, the libxmp-lite audio
  adapter, audio output, and the menu-bar application.
- `Vendor/LibXMP.xcframework` is a pinned Apple-silicon static build of
  libxmp-lite 4.7.2. It handles MOD, XM, S3M, and IT replay without requiring a
  package manager or library installation on the user’s Mac.
- `Support/` owns bundle metadata and the original Finder icon. The menu bar
  uses Apple’s native radio symbol for immediate recognition.
- `Support/ModRadio.entitlements` enables App Sandbox, outbound network
  connections, and two named connections to Sparkle’s update installer. No file,
  process automation, incoming network, personal information, or device
  entitlements are present.
- `scripts/build-app.sh` builds the Swift package, assembles the app bundle,
  signs each embedded component, and verifies the bundle and sandbox policy.
- `scripts/install-app.sh` replaces only `/Applications/ModRadio.app` and opens
  the installed copy.

The single Swift target keeps this small application together. If playlists,
favourites, or multiple catalogues prove useful, catalogue behavior can move
into a testable `ModRadioCore` target without changing the bundle or UI
boundary. The C decoder remains isolated behind `TrackerAudioPlayer`.

Downloaded modules are held in memory. The shipped executable has no arbitrary
path-reading command and does not launch or inspect other processes. External
module links are handed to macOS through `NSWorkspace`.

The release updater lives in `AppUpdater.swift`. It adds native menu items and stays disabled in development builds. Sparkle is pinned in the Swift package; its installer service and helper executables are embedded inside the signed framework. See [security and privacy](security.md) for the update boundary.

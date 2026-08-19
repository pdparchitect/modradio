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
- `scripts/build-app.sh` builds the Swift package, assembles the app bundle,
  signs it, and verifies the signature.
- `scripts/install-app.sh` replaces only `/Applications/ModRadio.app` and opens
  the installed copy.

The single Swift target is deliberate for version 0.1. If playlists,
favourites, or multiple catalogues prove useful, catalogue behavior can move
into a testable `ModRadioCore` target without changing the bundle or UI
boundary. The C decoder remains isolated behind `TrackerAudioPlayer`.

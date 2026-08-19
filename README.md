# ModRadio

ModRadio is a small native macOS menu-bar radio for tracker music. Choose
**Play Random MOD or XM** and it asks BassoonTracker for a random ProTracker or
FastTracker module, plays it locally, and moves to another track when it
finishes.

## Version 0.2

This release is intentionally focused on the first product question: is an
always-available random tracker station useful and enjoyable?

- Native menu-bar application with no Dock icon
- Original multi-resolution Finder and Applications icon
- Clear native radio symbol in the menu bar
- Random MOD and XM discovery through BassoonTracker and The Mod Archive
- Continuous play, pause, resume, skip, stop, and persistent in-menu volume control
- Song title and available artist attribution
- Links to the current song in BassoonTracker and The Mod Archive
- Bundled libxmp-lite replay engine with no external runtime installation
- Standard signed macOS app bundle, Swift package, and repeatable build scripts

The bundled replay engine supports MOD, XM, S3M, and IT files. Continuous radio
play alternates between the random MOD and random XM catalogues so both formats
are represented. A small native
ProTracker fallback preserves compatibility with older MOD variants that the
compact decoder does not recognize. The current radio catalogue deliberately
selects between BassoonTracker’s random MOD and random XM feeds. Saved
playlists, favourites, and offline storage remain future work.

## Build

Requirements: macOS 15 or later and full Xcode.

Build a signed local bundle:

```sh
scripts/build-app.sh
```

Build and launch the local bundle:

```sh
scripts/build-and-launch.sh
```

Build, install to Applications, and launch:

```sh
scripts/install-app.sh
```

The local bundle is written to `.build/ModRadio.app`. Builds are signed ad hoc
by default. Set `MODRADIO_SIGNING_IDENTITY` to use a particular local signing
identity, or `MODRADIO_INSTALL_DIR` to install somewhere other than
`/Applications`.

Run an end-to-end playback check:

```sh
.build/ModRadio.app/Contents/MacOS/ModRadio --smoke-test
```

To verify parsing and audio without depending on the catalogue service:

```sh
.build/ModRadio.app/Contents/MacOS/ModRadio --smoke-stdin < /path/to/song.mod
```

## Security boundary

ModRadio runs inside the macOS App Sandbox. Its signed entitlement set contains
only the sandbox itself and outbound network access for BassoonTracker. It has
no file-selection, Downloads, Music, Pictures, Movies, process automation,
incoming-network, microphone, camera, Bluetooth, USB, or location access.
Downloaded module data stays in memory and preferences, if introduced later,
remain inside the app’s private container.

## Project layout

```text
Sources/ModRadio/       Native menu-bar app and version 0.1 replay engine
Vendor/LibXMP.xcframework
                        Pinned libxmp-lite 4.7.2 decoder for Apple silicon
Support/AppIcon.png     Generated 1024px application-icon master
Support/ModRadio.icns   Multi-resolution Finder and launch icon
Support/ModRadio.entitlements
                        Deny-by-default sandbox and outbound network access
scripts/                Build, sign, launch, and install workflows
docs/architecture.md    Current boundaries and extension direction
THIRD_PARTY_NOTICES.md  Bundled decoder version, provenance, and licence
```

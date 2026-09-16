# Security and privacy

ModRadio runs inside the macOS App Sandbox. It uses outbound network access to discover and download music from BassoonTracker and The Mod Archive. Downloaded modules stay in memory; volume preferences stay in the app’s private container.

The app does not request file-selection, Downloads, Music, Pictures, Movies, microphone, camera, incoming-network, Accessibility, or automation permissions. Native Now Playing and media keys do not require global keyboard monitoring.

Release builds use Developer ID signing, hardened runtime, and Apple notarization. The bundled libxmp-lite decoder is statically linked; no external runtime installation is needed.

## Updates

The updater uses ModRadio’s own signed GitHub feed and verifies update archives before extraction. It does not send a system profile or contain a GitHub token. Development builds have updates disabled.

Automatic installation requires Sparkle’s installer service to replace and relaunch the app outside the host sandbox. Its two connections are restricted to `com.pdparchitect.modradio-spks` and `com.pdparchitect.modradio-spki`. The installer, updater, and framework are signed with the app’s Developer ID certificate. No separate downloader service is needed because the app already has outbound network access.

See [Sparkle’s sandbox integration](https://sparkle-project.org/documentation/sandboxing/) for the installer boundary.

[Documentation](README.md)

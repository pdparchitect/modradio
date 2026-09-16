# Development

Requires Apple Silicon, macOS 15 or later, and full Xcode. The repository includes a pinned static libxmp-lite decoder; no external runtime installation is needed.

```sh
make build
make run
make test
```

The app is written to `dist/ModRadio.app`. Choose a persistent local identity with `security find-identity -v -p codesigning`, then set `git config --local modradio.signingIdentity CERTIFICATE_SHA1` or the `MODRADIO_SIGNING_IDENTITY` environment variable. This lets the hardened app load its signed Sparkle framework. Ad-hoc signing is available only as an explicit `MODRADIO_SIGNING_IDENTITY=-` override for disposable CI verification builds. `make install` installs to `/Applications`; `MODRADIO_INSTALL_DIR` selects another location and `MODRADIO_SKIP_OPEN=1` skips launching.

The assembled app includes playback checks:

```sh
dist/ModRadio.app/Contents/MacOS/ModRadio --smoke-media
dist/ModRadio.app/Contents/MacOS/ModRadio --smoke-mod
dist/ModRadio.app/Contents/MacOS/ModRadio --smoke-xm
dist/ModRadio.app/Contents/MacOS/ModRadio --smoke-transition
dist/ModRadio.app/Contents/MacOS/ModRadio --smoke-stdin < /path/to/song.mod
```

The media check uses a synthetic module. The MOD, XM, and transition checks contact the live catalogue and exercise playback, seeking, and completion. The stdin check exercises a supplied module without catalogue access. These run inside the app’s normal sandbox.

[Documentation](README.md)

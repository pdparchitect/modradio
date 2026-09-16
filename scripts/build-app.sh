#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
configuration="${MODRADIO_BUILD_CONFIGURATION:-release}"
version="$(python3 "$project_root/scripts/release.py" version)"
release="${MODRADIO_RELEASE:-0}"
[[ "$release" == 0 || "$release" == 1 ]] || { print -u2 'MODRADIO_RELEASE must be 0 or 1.'; exit 1; }
[[ "$configuration" == release || "$configuration" == debug ]] || { print -u2 'Invalid build configuration.'; exit 1; }
# A persistent identity lets hardened runtime load the same-team Sparkle framework.
identity="${MODRADIO_SIGNING_IDENTITY:-$(git -C "$project_root" config --local --get modradio.signingIdentity 2>/dev/null || true)}"
if [[ -z "$identity" ]]; then
  print -u2 'Choose a persistent local signing identity before building ModRadio:'
  print -u2 '  security find-identity -v -p codesigning'
  print -u2 '  git config --local modradio.signingIdentity CERTIFICATE_SHA1'
  print -u2 'For disposable CI verification only, set MODRADIO_SIGNING_IDENTITY=-.'
  exit 1
fi
if [[ "$identity" == - && "${MODRADIO_SIGNING_IDENTITY:-}" != - ]]; then
  print -u2 'Ad-hoc signing requires an explicit MODRADIO_SIGNING_IDENTITY=- override.'
  exit 1
fi
if [[ "$release" == 1 && ( "$identity" != Developer\ ID\ Application:* || "$configuration" != release ) ]]; then
  print -u2 'Distributed releases require a Developer ID Application identity and release configuration.'
  exit 1
fi
timestamp_option=--timestamp=none
if [[ "$release" == 1 ]]; then timestamp_option=--timestamp; fi
signing_options=(--force --options runtime "$timestamp_option" --sign "$identity")
if [[ -n "${MODRADIO_SIGNING_KEYCHAIN:-}" ]]; then
  signing_options+=(--keychain "$MODRADIO_SIGNING_KEYCHAIN")
fi
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
zsh "$project_root/scripts/swift.sh" build --package-path "$project_root" --configuration "$configuration" >&2
bin_path="$(zsh "$project_root/scripts/swift.sh" build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"
python3 "$project_root/scripts/verify-build-sdk.py" "$bin_path/ModRadio" "$(xcrun --sdk macosx --show-sdk-version)" >&2
output="$project_root/dist/ModRadio.app"
mkdir -p "$project_root/dist"
staging="$(mktemp -d "$project_root/dist/.modradio-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/ModRadio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle"
# The app already has outbound network access; only the installer service is needed.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
cp "$project_root/.build/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp "$project_root/Support/Noodle-LICENSE.txt" "$app/Contents/Resources/Noodle-LICENSE.txt"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$bin_path/ModRadio" "$app/Contents/MacOS/ModRadio"
# Recent Swift toolchains add a development-only fallback runtime path. Keep only OS/bundle paths.
python3 - "$app/Contents/MacOS/ModRadio" <<'PY'
import subprocess
import sys
executable = sys.argv[1]
lines = subprocess.check_output(['otool', '-l', executable], text=True).splitlines()
for index, line in enumerate(lines):
    if line.strip() != 'cmd LC_RPATH':
        continue
    path = lines[index + 2].strip().split(' (offset', 1)[0].removeprefix('path ')
    if path.startswith('/') and not path.startswith(('/System/Library/', '/usr/lib/')):
        subprocess.run(['install_name_tool', '-delete_rpath', path, executable], check=True)
PY
cp "$project_root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Support/ModRadio.icns" "$app/Contents/Resources/ModRadio.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
if [[ "$release" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :ModRadioUpdatesEnabled true' "$app/Contents/Info.plist"
fi
# Sign the dedicated installer components inside-out, then the sandboxed host.
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
  codesign "${signing_options[@]}" "$component"
done
codesign "${signing_options[@]}" --entitlements "$project_root/Support/ModRadio.entitlements" "$app"
"$project_root/scripts/verify-app.sh" "$app" >&2
rm -rf "$output"
mv "$app" "$output"
print "$output"

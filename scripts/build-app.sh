#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${MODRADIO_BUILD_CONFIGURATION:-release}"
build_root="$project_root/.build"
app="$build_root/ModRadio.app"
contents="$app/Contents"
module_cache="$build_root/module-cache"
entitlements="$project_root/Support/ModRadio.entitlements"

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

swift build --package-path "$project_root" --configuration "$configuration" >&2
bin_path="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_path/ModRadio" "$contents/MacOS/ModRadio"
cp "$project_root/Support/Info.plist" "$contents/Info.plist"
cp "$project_root/Support/ModRadio.icns" "$contents/Resources/ModRadio.icns"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$contents/Resources/THIRD_PARTY_NOTICES.md"

signing_identity="${MODRADIO_SIGNING_IDENTITY:--}"
codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$entitlements" \
    --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

print "$app"

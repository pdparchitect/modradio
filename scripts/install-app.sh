#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app="$($project_root/scripts/build-app.sh)"
install_root="${MODRADIO_INSTALL_DIR:-/Applications}"
installed_app="$install_root/ModRadio.app"

pkill -x ModRadio 2>/dev/null || true
rm -rf "$installed_app"
ditto "$app" "$installed_app"
codesign --verify --deep --strict --verbose=2 "$installed_app"

if [[ "${MODRADIO_SKIP_OPEN:-0}" != "1" ]]; then
    open "$installed_app"
fi

print "Installed $installed_app"

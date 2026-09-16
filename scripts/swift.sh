#!/bin/zsh
set -euo pipefail

# Match Noodle's SDK selection for compilation and linking. Without the linker
# sysroot, SwiftPM can stamp the deployment target as the SDK and make SwiftUI
# select legacy controls, menu ordering, and settings-window behavior.
modradio_sdk="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT="$modradio_sdk"
modradio_command="${1:?Pass build or test}"
shift
exec "$(xcrun --find swift)" "$modradio_command" --build-system native --sdk "$modradio_sdk" \
    -Xlinker -syslibroot -Xlinker "$modradio_sdk" "$@"

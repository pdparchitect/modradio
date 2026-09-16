#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export PYTHONPYCACHEPREFIX="$project_root/.build/python-cache"
python3 -m unittest discover -s "$project_root/Tests/ReleaseAutomation" -v
# Playback checks run against the assembled, sandboxed app in CI.

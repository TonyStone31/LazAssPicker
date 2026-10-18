#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
LAZBUILD=${LAZBUILD:-lazbuild}
mkdir -p bin
"$LAZBUILD" --ws=gtk3 "$@" lazasspicker.lpi

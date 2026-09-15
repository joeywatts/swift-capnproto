#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == decode ]] || exit 64
printf '(int = 0, msg = "corrupt")\n'

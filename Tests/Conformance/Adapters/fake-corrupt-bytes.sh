#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == encode ]] || exit 64
printf 'not a Capn Proto message'

#!/bin/sh
# Occupies one logical core for the given number of seconds (default 20), then exits.
# The worker appears as "yes" in the process list. Use it for the roadmap acceptance runs.
set -eu
seconds=${1:-20}
yes > /dev/null &
worker=$!
trap 'kill "$worker" 2>/dev/null || true' EXIT INT TERM
printf 'Worker PID %s for %s s\n' "$worker" "$seconds"
sleep "$seconds"

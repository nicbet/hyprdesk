#!/bin/sh
# Quits a running hyprdesk and waits until it's gone. It puts parked windows back first; opening
# the app again while the old one is still quitting fails with LaunchServices error -609.
running() { pgrep -qx hyprdesk; }
running || exit 0
pkill -x hyprdesk 2>/dev/null
for _ in $(seq 50); do
    running || exit 0
    sleep 0.1
done
echo "hyprdesk still quitting after 5s; killing it" >&2
pkill -9 -x hyprdesk 2>/dev/null
sleep 0.2

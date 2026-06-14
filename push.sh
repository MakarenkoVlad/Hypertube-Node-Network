#!/usr/bin/env bash
# Commit everything and push to GitHub (origin -> main).
# Usage:  ./push.sh "your message"      (message optional; defaults to "update")
set -e
cd "$(dirname "$0")"

rm -f .git/index.lock                         # clear any stale lock

git add -A
git commit -m "${1:-update}" || echo "(nothing new to commit)"
git push origin HEAD:main

RAW="https://raw.githubusercontent.com/MakarenkoVlad/Hypertube-Node-Network/main"
echo
echo "Pushed."
echo "Update a running node (on its CC computer):"
echo "  wget $RAW/src/ht_node.lua firmware.lua && reboot"
echo "Or update every node over rednet (from one node):"
echo "  wget $RAW/src/ht_node.lua firmware.lua && ht_push firmware.lua"

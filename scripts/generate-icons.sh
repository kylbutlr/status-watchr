#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
working_directory="$(mktemp -d "${TMPDIR:-/tmp}/status-watchr-icons.XXXXXX")"
trap 'rm -rf "$working_directory"' EXIT

public_directory="$repository_root/public"
icons_directory="$public_directory/icons"
macos_resources="$repository_root/apps/macos/Resources"
master_path="$working_directory/status-watchr-master.png"

mkdir -p "$public_directory" "$icons_directory" "$macos_resources"
swift "$script_directory/render-macos-icon.swift" "$master_path"

cp "$repository_root/apps/macos/Resources/StatusWatchrIcon.svg" "$public_directory/favicon.svg"
sips -z 32 32 "$master_path" --out "$public_directory/favicon.png" >/dev/null
sips -z 180 180 "$master_path" --out "$public_directory/apple-touch-icon.png" >/dev/null
sips -z 192 192 "$master_path" --out "$icons_directory/status-watchr-192.png" >/dev/null
sips -z 512 512 "$master_path" --out "$icons_directory/status-watchr-512.png" >/dev/null

iconset_directory="$working_directory/StatusWatchr.iconset"
mkdir -p "$iconset_directory"
while read -r filename pixels; do
    sips -z "$pixels" "$pixels" "$master_path" --out "$iconset_directory/$filename" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

iconutil --convert icns --output "$macos_resources/StatusWatchr.icns" "$iconset_directory"
echo "Generated Status Watchr web and macOS icons."

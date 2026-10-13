#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 VERSION" >&2
    echo "Example: $0 0.1.0" >&2
    exit 64
fi

version="$1"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must use major.minor.patch format." >&2
    exit 64
fi

IFS=. read -r major minor patch <<< "$version"
build_number=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))
script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
updates_directory="$repository_root/public/updates"
archive_name="Status-Watchr-$version.zip"
archive_path="$updates_directory/$archive_name"
distributed_version="$(< "$repository_root/apps/macos/Resources/latest-distributed-version.txt")"
published_version="$(sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' "$updates_directory/appcast.xml" | head -n 1)"
minimum_version="$("$script_directory/next-macos-version.sh" 0.0.0 "$published_version" "$distributed_version")"
IFS=. read -r floor_major floor_minor floor_patch <<< "$minimum_version"
minimum_build=$((10#$floor_major * 1000000 + 10#$floor_minor * 1000 + 10#$floor_patch))
if (( build_number < minimum_build )); then
    echo "Release must be at least $minimum_version to exceed previously distributed builds." >&2
    exit 1
fi
installed_plist="/Applications/Status Watchr.app/Contents/Info.plist"
if [[ -f "$installed_plist" ]]; then
    installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_plist")"
    if [[ ! "$installed_build" =~ ^[0-9]+$ ]] || (( build_number <= 10#$installed_build )); then
        echo "Release build must be newer than the installed Mac app." >&2
        exit 1
    fi
fi
if [[ -e "$archive_path" ]]; then
    echo "Refusing to overwrite an existing release archive." >&2
    exit 1
fi
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/status-watchr-release.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT

source_info_plist="$repository_root/apps/macos/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$source_info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$source_info_plist"

public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$source_info_plist")"
if [[ "$public_key" == "REPLACE_WITH_STATUS_WATCHR_SPARKLE_PUBLIC_KEY" ]]; then
    echo "Configure the Status Watchr Sparkle public key in apps/macos/Resources/Info.plist first." >&2
    exit 1
fi

STATUS_WATCHR_VERSION="$version" \
STATUS_WATCHR_BUILD="$build_number" \
    "$script_directory/build-macos-app.sh" "$staging_directory"

mkdir -p "$updates_directory"
ditto -c -k --sequesterRsrc --keepParent \
    "$staging_directory/Status Watchr.app" \
    "$archive_path"

sparkle_tools="$repository_root/apps/macos/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
    echo "Sparkle signing tools are missing. Run swift package resolve first." >&2
    exit 1
fi

generate_appcast_args=(
    --download-url-prefix "https://statuswatchr.netlify.app/updates/"
    --link "https://statuswatchr.netlify.app"
    --maximum-versions 3
    --maximum-deltas 0
)

if [[ -n "${STATUS_WATCHR_SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$STATUS_WATCHR_SPARKLE_PRIVATE_KEY" |
        "$sparkle_tools/generate_appcast" --ed-key-file - "${generate_appcast_args[@]}" "$updates_directory"
else
    "$sparkle_tools/generate_appcast" \
        --account com.kylbutlr.statuswatchr \
        "${generate_appcast_args[@]}" \
        "$updates_directory"
fi

rm -rf -- "$updates_directory/old_updates"

echo "Prepared Status Watchr $version (build $build_number)."
echo "Archive: $archive_path"
echo "Feed: $updates_directory/appcast.xml"

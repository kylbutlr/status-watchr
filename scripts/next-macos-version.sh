#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $0 SOURCE_VERSION [PUBLISHED_VERSION] [LATEST_DISTRIBUTED_VERSION]" >&2
    exit 64
fi

source_version="$1"
published_version="${2:-}"
distributed_version="${3:-}"

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

if ! validate_version "$source_version"; then
    echo "Versions must use major.minor.patch format." >&2
    exit 64
fi
if [[ -n "$published_version" ]] && ! validate_version "$published_version"; then
    echo "Versions must use major.minor.patch format." >&2
    exit 64
fi
if [[ -n "$distributed_version" ]] && ! validate_version "$distributed_version"; then
    echo "Versions must use major.minor.patch format." >&2
    exit 64
fi

version_number() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$1"
    printf '%d' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

next_patch() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$1"
    printf '%d.%d.%d' "$((10#$major))" "$((10#$minor))" "$((10#$patch + 1))"
}

if [[ -n "$distributed_version" ]] && { [[ -z "$published_version" ]] || (( $(version_number "$distributed_version") > $(version_number "$published_version") )); }; then
    published_version="$distributed_version"
fi

if [[ -n "$published_version" ]] && (( $(version_number "$source_version") < $(version_number "$published_version") )); then
    next_patch "$published_version"
elif [[ -n "$published_version" ]] && (( $(version_number "$source_version") > $(version_number "$published_version") )); then
    printf '%s\n' "$source_version"
else
    next_patch "$source_version"
fi

#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 64
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
package_directory="$repository_root/apps/macos"
output_directory="$1"
application_name="Status Watchr"
executable_name="StatusWatchr"
signing_identity="${STATUS_WATCHR_CODESIGN_IDENTITY:-Status Watchr Local Code Signing}"
signing_keychain="${STATUS_WATCHR_KEYCHAIN:-}"
rcodesign_binary="${STATUS_WATCHR_RCODESIGN:-}"
signing_p12="${STATUS_WATCHR_CODESIGN_P12:-}"
signing_password_file="${STATUS_WATCHR_CODESIGN_PASSWORD_FILE:-}"
identity_search_args=(-v -p codesigning)
if [[ -n "$signing_keychain" ]]; then identity_search_args+=("$signing_keychain"); fi

if [[ -n "$rcodesign_binary" || -n "$signing_p12" || -n "$signing_password_file" ]]; then
    if [[ -z "$rcodesign_binary" || -z "$signing_p12" || -z "$signing_password_file" ]]; then
        echo "STATUS_WATCHR_RCODESIGN, STATUS_WATCHR_CODESIGN_P12, and STATUS_WATCHR_CODESIGN_PASSWORD_FILE must be set together." >&2
        exit 1
    fi
    if [[ ! -x "$rcodesign_binary" || ! -f "$signing_p12" || ! -f "$signing_password_file" ]]; then
        echo "Trust-independent signing inputs are missing or invalid." >&2
        exit 1
    fi
    signing_mode="rcodesign"
else
    signing_mode="codesign"
    if [[ "$signing_identity" == "-" ]]; then
        echo "Ad hoc signing is disabled for release bundles." >&2
        exit 1
    elif ! security find-identity "${identity_search_args[@]}" | grep -Fq "\"$signing_identity\""; then
        echo "Code Signing identity not found: $signing_identity" >&2
        echo "Create it in the login keychain or set STATUS_WATCHR_CODESIGN_IDENTITY to another persistent identity." >&2
        exit 1
    fi
fi

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
application_bundle="$output_directory/$application_name.app"

if [[ -e "$application_bundle" ]]; then
    echo "Refusing to overwrite existing bundle: $application_bundle" >&2
    exit 1
fi

source_info_plist="$package_directory/Resources/Info.plist"
application_version="${STATUS_WATCHR_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_info_plist")}"
application_build="${STATUS_WATCHR_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_info_plist")}"

if [[ ! -f "$package_directory/Resources/StatusWatchr.icns" ]]; then
    echo "StatusWatchr.icns is missing. Run scripts/generate-icons.sh first." >&2
    exit 1
fi

swift build --configuration release --package-path "$package_directory" >&2
product_directory="$(swift build --configuration release --package-path "$package_directory" --show-bin-path 2>/dev/null)"
sparkle_framework="$product_directory/Sparkle.framework"

if [[ ! -d "$sparkle_framework" ]]; then
    echo "Sparkle.framework was not produced by Swift Package Manager." >&2
    exit 1
fi

contents_directory="$application_bundle/Contents"
mkdir -p "$contents_directory/MacOS" "$contents_directory/Frameworks" "$contents_directory/Resources"
cp "$product_directory/$executable_name" "$contents_directory/MacOS/$executable_name"
cp "$source_info_plist" "$contents_directory/Info.plist"
cp "$package_directory/Resources/StatusWatchr.icns" "$contents_directory/Resources/StatusWatchr.icns"
ditto "$sparkle_framework" "$contents_directory/Frameworks/Sparkle.framework"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $application_version" "$contents_directory/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $application_build" "$contents_directory/Info.plist"

# Embed provenance before signing. Dirty builds are explicitly identifiable, not claimed as exact commits.
source_revision="source-archive"
source_dirty=true
if [[ -e "$repository_root/.git" ]] && git -C "$repository_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    source_revision="$(git -C "$repository_root" rev-parse HEAD)"
    source_dirty=false
    if [[ -n "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ]]; then source_dirty=true; fi
fi
/usr/libexec/PlistBuddy -c "Add :StatusWatchrSourceRevision string $source_revision" "$contents_directory/Info.plist"
/usr/libexec/PlistBuddy -c "Add :StatusWatchrSourceDirty bool $source_dirty" "$contents_directory/Info.plist"

if [[ "$signing_mode" == "rcodesign" ]]; then
    signature_report="$output_directory/status-watchr-signature-info.txt"
    "$rcodesign_binary" sign \
        --timestamp-url none \
        --p12-file "$signing_p12" \
        --p12-password-file "$signing_password_file" \
        "$application_bundle"
    "$rcodesign_binary" verify "$contents_directory/MacOS/$executable_name"
    "$rcodesign_binary" print-signature-info "$application_bundle" > "$signature_report"
    if ! grep -Fq "signature_verifies: true" "$signature_report"; then
        echo "rcodesign did not report a verified cryptographic signature." >&2
        exit 1
    fi
    if grep -Fq "signature_verifies: false" "$signature_report"; then
        echo "rcodesign reported an invalid cryptographic signature." >&2
        exit 1
    fi
    rm -f "$signature_report"
else
    codesign --force --timestamp=none --sign "$signing_identity" "$contents_directory/MacOS/$executable_name"
    codesign --force --timestamp=none --sign "$signing_identity" "$contents_directory/Frameworks/Sparkle.framework"
    codesign --force --timestamp=none --sign "$signing_identity" "$application_bundle"
    codesign --verify --deep --strict --verbose=2 "$application_bundle"
fi

python3 "$repository_root/scripts/check-connections-bundle.py" "$application_bundle" >&2

echo "$application_bundle"

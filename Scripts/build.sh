#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/dist.noindex"
APP_NAME="Pop.app"
REPLACE_EXISTING=false
SCRATCH_DIRECTORY="$PROJECT_DIRECTORY/.build.noindex"
ARCHITECTURE="universal"
SIGNING_IDENTITY="-"

usage() {
    cat <<'USAGE'
Usage: build.sh [--output DIRECTORY] [--replace] [--scratch-path DIRECTORY]
                [--arch universal|arm64|x86_64] [--sign IDENTITY]

Builds a macOS 15+ Pop.app using the macOS 26+ SDK. The default is a universal
arm64 + x86_64 app signed ad hoc. --sign accepts a Developer ID Application
identity in your keychain; it enables hardened runtime but does not notarize.
The default output is dist.noindex/ and build scratch is .build.noindex/.
Output and scratch paths must be inside a directory ending in .noindex, so
builds do not create extra indexed application entries. Relative paths are
relative to your current directory.
With --replace, previous Pop.app or legacy pop.app bundles are archived as
timestamped ZIPs, then replaced by one Pop.app. The script does not install or
launch the app. Bundle ID, data paths and URL scheme remain unchanged.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            OUTPUT_DIRECTORY="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_DIRECTORY="${1#--output=}"
            [[ -n "$OUTPUT_DIRECTORY" ]] || { usage >&2; exit 2; }
            shift
            ;;
        --replace)
            REPLACE_EXISTING=true; shift
            ;;
        --scratch-path)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            SCRATCH_DIRECTORY="$2"; shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            ARCHITECTURE="$2"; shift 2
            ;;
        --sign)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            SIGNING_IDENTITY="$2"; shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || { printf 'This build requires macOS.\n' >&2; exit 1; }
command -v xcrun >/dev/null || { printf 'Install Apple Command Line Tools or Xcode with the macOS 26+ SDK.\n' >&2; exit 1; }
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 26 ]] || { printf 'macOS SDK 26+ is required; selected SDK is %s. Set DEVELOPER_DIR or xcode-select.\n' "$SDK_VERSION" >&2; exit 1; }
case "$ARCHITECTURE" in
    universal) ARCHITECTURES=(arm64 x86_64) ;;
    arm64|x86_64) ARCHITECTURES=("$ARCHITECTURE") ;;
    *) printf 'Unsupported architecture: %s\n' "$ARCHITECTURE" >&2; exit 2 ;;
esac
[[ -f "$PROJECT_DIRECTORY/Resources/Info.plist" && -f "$PROJECT_DIRECTORY/Resources/Pop.sdef" ]] || {
    printf 'Required Info.plist or Pop.sdef is missing.\n' >&2
    exit 1
}

for directory in "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"; do
    case "/$directory/" in
        *.noindex/*) ;;
        *) printf 'Output and scratch must be inside a .noindex directory: %s\n' "$directory" >&2; exit 2 ;;
    esac
done
mkdir -p "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
SCRATCH_DIRECTORY="$(cd "$SCRATCH_DIRECTORY" && pwd)"
for directory in "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"; do
    case "$directory/" in *.noindex/*) ;; *) printf 'Resolved path is outside .noindex: %s\n' "$directory" >&2; exit 2 ;; esac
done
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PROJECT_DIRECTORY/Resources/Info.plist")"
[[ "$MINIMUM_OS" == "15.0" ]] || { printf 'Expected deployment minimum 15.0, found %s.\n' "$MINIMUM_OS" >&2; exit 1; }
FINAL_APPLICATION="$OUTPUT_DIRECTORY/$APP_NAME"
EXISTING_APPLICATIONS=()
find_existing_applications() {
    EXISTING_APPLICATIONS=()
    local candidate
    # Read actual directory-entry spelling: on case-insensitive volumes,
    # testing Pop.app and pop.app directly would identify the same app twice.
    for candidate in "$OUTPUT_DIRECTORY/"*.app; do
        case "$(basename "$candidate")" in
            Pop.app|pop.app)
                [[ -e "$candidate" || -L "$candidate" ]] && EXISTING_APPLICATIONS+=("$candidate")
                ;;
        esac
    done
}
find_existing_applications
if [[ ${#EXISTING_APPLICATIONS[@]} -gt 0 && "$REPLACE_EXISTING" != true ]]; then
    printf 'Existing app: %s. Use --replace to update it as Pop.app.\n' "${EXISTING_APPLICATIONS[0]}" >&2
    exit 1
fi

STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.pop-build.XXXXXX")"
mv "$STAGING_DIRECTORY" "$STAGING_DIRECTORY.noindex"
STAGING_DIRECTORY="$STAGING_DIRECTORY.noindex"
PRESERVE_STAGING=false
cleanup() {
    if [[ "$PRESERVE_STAGING" != true && -n "${STAGING_DIRECTORY:-}" && -d "$STAGING_DIRECTORY" ]]; then
        rm -rf -- "$STAGING_DIRECTORY"
    fi
}
trap cleanup EXIT

cd "$PROJECT_DIRECTORY"
BINARIES=()
for architecture in "${ARCHITECTURES[@]}"; do
    BUILD_ARGUMENTS=(-c release --product Pop --scratch-path "$SCRATCH_DIRECTORY/$architecture"
        --triple "$architecture-apple-macosx$MINIMUM_OS" --sdk "$SDK_PATH"
        -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIRECTORY=."
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
    MACOSX_DEPLOYMENT_TARGET="$MINIMUM_OS" xcrun swift build "${BUILD_ARGUMENTS[@]}"
    BINARY_DIRECTORY="$(xcrun swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
    [[ -x "$BINARY_DIRECTORY/Pop" ]] || { printf 'The %s executable was not produced.\n' "$architecture" >&2; exit 1; }
    BINARIES+=("$BINARY_DIRECTORY/Pop")
done

STAGED_APPLICATION="$STAGING_DIRECTORY/$APP_NAME"
CONTENTS="$STAGED_APPLICATION/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Licenses" "$CONTENTS/Frameworks"
xcrun lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/Pop"
for architecture in "${ARCHITECTURES[@]}"; do
    xcrun lipo "$CONTENTS/MacOS/Pop" -verify_arch "$architecture"
done
# Release downloads do not include source paths or DWARF debug information.
xcrun strip -S "$CONTENTS/MacOS/Pop"
chmod 755 "$CONTENTS/MacOS/Pop"
cp "$PROJECT_DIRECTORY/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

shopt -s nullglob dotglob
for resource in "$PROJECT_DIRECTORY/Resources/"*; do
    [[ "$(basename "$resource")" == "Info.plist" ]] && continue
    /usr/bin/ditto "$resource" "$CONTENTS/Resources/$(basename "$resource")"
done
if [[ -d "$PROJECT_DIRECTORY/Integrations" ]]; then
    /usr/bin/ditto "$PROJECT_DIRECTORY/Integrations" "$CONTENTS/Resources/Integrations"
fi

# Only project-contained resources and explicitly provided licence/notice files are
# copied. The script never searches installed software for icons or resources.
for license_name in LICENSE LICENSE.txt LICENSE.md THIRD_PARTY_NOTICES.txt THIRD_PARTY_NOTICES.md ThirdPartyNotices.txt; do
    if [[ -f "$PROJECT_DIRECTORY/$license_name" ]]; then
        cp "$PROJECT_DIRECTORY/$license_name" "$CONTENTS/Resources/Licenses/$license_name"
    fi
done
for license_directory in Licenses licenses ThirdPartyLicenses; do
    if [[ -d "$PROJECT_DIRECTORY/$license_directory" ]]; then
        /usr/bin/ditto "$PROJECT_DIRECTORY/$license_directory" "$CONTENTS/Resources/Licenses/$license_directory"
    fi
done

# Keep usage instructions and the stated compatibility limits with the app.
for document_name in README.md README.txt FEATURES.csv CLOUD_SERVICES.txt; do
    if [[ -f "$PROJECT_DIRECTORY/$document_name" ]]; then
        cp "$PROJECT_DIRECTORY/$document_name" "$CONTENTS/Resources/$document_name"
    fi
done

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
# Include any Swift compatibility libraries the selected toolchain requires.
# The executable explicitly searches Contents/Frameworks before OS fallback.
xcrun swift-stdlib-tool --copy --scan-executable "$CONTENTS/MacOS/Pop" --platform macosx --destination "$CONTENTS/Frameworks"
SIGN_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGN_ARGUMENTS+=(--timestamp=none)
else
    SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi
for library in "$CONTENTS/Frameworks/"*.dylib; do
    /usr/bin/codesign "${SIGN_ARGUMENTS[@]}" "$library"
done
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    /usr/bin/codesign "${SIGN_ARGUMENTS[@]}" "$STAGED_APPLICATION"
else
    # Apple-event control is an explicit feature of selected-text translation.
    # JSC executes installed translation plugins inside a dedicated worker.
    cat > "$STAGING_DIRECTORY/DeveloperID.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
ENTITLEMENTS
    /usr/bin/codesign "${SIGN_ARGUMENTS[@]}" --entitlements "$STAGING_DIRECTORY/DeveloperID.entitlements" "$STAGED_APPLICATION"
fi
/usr/bin/codesign --verify --deep --strict "$STAGED_APPLICATION"

find_existing_applications
if [[ ${#EXISTING_APPLICATIONS[@]} -gt 0 ]]; then
    ARCHIVE_DIRECTORY="$OUTPUT_DIRECTORY/.pop-archives.noindex"
    mkdir -p "$ARCHIVE_DIRECTORY"
    # Validate and archive every old spelling before moving any application.
    # Case-sensitive volumes may contain both old and new names.
    ARCHIVE_INDEX=0
    for application in "${EXISTING_APPLICATIONS[@]}"; do
        [[ "$REPLACE_EXISTING" == true && -d "$application" && ! -L "$application" ]] || {
            printf 'Output changed while building; cannot replace safely: %s\n' "$application" >&2; exit 1;
        }
        [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$application/Contents/Info.plist")" == "com.local.pop" ]] || {
            printf 'Existing application is not Pop; refusing to replace: %s\n' "$application" >&2; exit 1;
        }
        ARCHIVE_PATH="$ARCHIVE_DIRECTORY/Pop-$(date +%Y%m%d-%H%M%S)-$$-$ARCHIVE_INDEX.zip"
        /usr/bin/ditto -c -k --keepParent "$application" "$ARCHIVE_PATH"
        /usr/bin/unzip -tq "$ARCHIVE_PATH" >/dev/null
        printf 'Previous version archived: %s\n' "$ARCHIVE_PATH"
        ARCHIVE_INDEX=$((ARCHIVE_INDEX + 1))
    done
    MOVED_COUNT=0
    restore_previous_applications() {
        local index previous original
        for ((index=MOVED_COUNT-1; index>=0; index--)); do
            previous="$STAGING_DIRECTORY/previous-$index.app"
            original="${EXISTING_APPLICATIONS[$index]}"
            if [[ -e "$original" || -L "$original" ]] || ! mv "$previous" "$original"; then
                PRESERVE_STAGING=true
                printf 'Previous app retained for recovery: %s\n' "$previous" >&2
            fi
        done
    }
    for application in "${EXISTING_APPLICATIONS[@]}"; do
        if ! mv "$application" "$STAGING_DIRECTORY/previous-$MOVED_COUNT.app"; then
            restore_previous_applications
            exit 1
        fi
        MOVED_COUNT=$((MOVED_COUNT + 1))
    done
    # Removing the old directory entry before installing also fixes its case
    # on the default macOS filesystem without creating a second visible app.
    if ! /bin/mv -n "$STAGED_APPLICATION" "$OUTPUT_DIRECTORY/" || [[ -e "$STAGED_APPLICATION" ]]; then
        restore_previous_applications
        printf 'Output app appeared while building; replacement stopped.\n' >&2
        exit 1
    fi
else
    /bin/mv -n "$STAGED_APPLICATION" "$OUTPUT_DIRECTORY/"
    [[ ! -e "$STAGED_APPLICATION" ]] || { printf 'Output app appeared while building.\n' >&2; exit 1; }
fi
printf 'Built: %s\n' "$FINAL_APPLICATION"
printf 'Architectures: %s; minimum macOS: %s; SDK: %s\n' "${ARCHITECTURES[*]}" "$MINIMUM_OS" "$SDK_VERSION"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    printf 'Signature: ad hoc. This build is not notarized for Gatekeeper.\n'
else
    printf 'Signature: %s. Notarization is a separate release step.\n' "$SIGNING_IDENTITY"
fi
printf 'The app has not been installed or launched.\n'

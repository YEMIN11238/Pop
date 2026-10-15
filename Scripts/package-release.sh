#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/release.noindex"
SCRATCH_DIRECTORY="$PROJECT_DIRECTORY/.build-release.noindex"
APPLICATION=""
SIGNING_IDENTITY="-"
REPLACE_EXISTING=false

usage() {
    cat <<'USAGE'
Usage: package-release.sh [--output DIRECTORY] [--scratch-path DIRECTORY]
                          [--app PATH/Pop.app] [--sign IDENTITY] [--replace]

Builds a universal macOS 15+ app and packages a ZIP plus a drag-to-Applications
DMG and SHA-256 checksums. --app packages an already signed universal app instead.
--sign is forwarded to build.sh when building; it does not re-sign --app input.
Defaults: release.noindex/ and .build-release.noindex/. Output and scratch must
be inside .noindex directories. --replace permits replacing same-version assets.
No installation, launch, upload, GitHub release or notarization is performed.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|--scratch-path|--app|--sign)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            case "$1" in
                --output) OUTPUT_DIRECTORY="$2" ;;
                --scratch-path) SCRATCH_DIRECTORY="$2" ;;
                --app) APPLICATION="$2" ;;
                --sign) SIGNING_IDENTITY="$2" ;;
            esac
            shift 2 ;;
        --replace) REPLACE_EXISTING=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || { printf 'Packaging requires macOS.\n' >&2; exit 1; }
for directory in "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"; do
    case "/$directory/" in *.noindex/*) ;; *) printf 'Use a .noindex output/scratch directory: %s\n' "$directory" >&2; exit 2 ;; esac
done
mkdir -p "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
SCRATCH_DIRECTORY="$(cd "$SCRATCH_DIRECTORY" && pwd)"
for directory in "$OUTPUT_DIRECTORY" "$SCRATCH_DIRECTORY"; do
    case "$directory/" in *.noindex/*) ;; *) printf 'Resolved path is outside .noindex: %s\n' "$directory" >&2; exit 2 ;; esac
done

if [[ -z "$APPLICATION" ]]; then
    "$SCRIPT_DIRECTORY/build.sh" --output "$SCRATCH_DIRECTORY/app.noindex" \
        --scratch-path "$SCRATCH_DIRECTORY/compile.noindex" --arch universal --sign "$SIGNING_IDENTITY" --replace
    APPLICATION="$SCRATCH_DIRECTORY/app.noindex/Pop.app"
fi
[[ -d "$APPLICATION" && ! -L "$APPLICATION" ]] || { printf 'App bundle not found or is a symlink: %s\n' "$APPLICATION" >&2; exit 1; }
APPLICATION="$(cd "$APPLICATION" && pwd)"
INFO="$APPLICATION/Contents/Info.plist"
[[ -f "$INFO" && -x "$APPLICATION/Contents/MacOS/Pop" && -f "$APPLICATION/Contents/Resources/AppIcon.icns" ]] || {
    printf 'Incomplete Pop app bundle.\n' >&2; exit 1;
}
/usr/bin/plutil -lint "$INFO"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$INFO")" == "Pop" ]] || { printf 'The supplied app is not Pop.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$INFO")" == "Pop" ]] || { printf 'Unexpected executable name.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INFO")" == "15.0" ]] || { printf 'Expected macOS 15.0 deployment minimum.\n' >&2; exit 1; }
for architecture in arm64 x86_64; do xcrun lipo "$APPLICATION/Contents/MacOS/Pop" -verify_arch "$architecture"; done
/usr/bin/codesign --verify --deep --strict "$APPLICATION"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ && "$BUILD" =~ ^[0-9]+$ ]] || { printf 'Unsafe or missing version/build number.\n' >&2; exit 1; }
ASSET_NAME="Pop-$VERSION-universal"
for asset in "$ASSET_NAME.zip" "$ASSET_NAME.dmg" SHA256SUMS.txt; do
    [[ "$REPLACE_EXISTING" == true || ! -e "$OUTPUT_DIRECTORY/$asset" ]] || {
        printf 'Existing release asset: %s (use --replace).\n' "$OUTPUT_DIRECTORY/$asset" >&2; exit 1;
    }
done

STAGING_DIRECTORY="$(mktemp -d "$SCRATCH_DIRECTORY/package.XXXXXX")"
cleanup() { [[ -z "${STAGING_DIRECTORY:-}" || ! -d "$STAGING_DIRECTORY" ]] || rm -rf -- "$STAGING_DIRECTORY"; }
trap cleanup EXIT
mkdir -p "$STAGING_DIRECTORY/image" "$STAGING_DIRECTORY/zip-check"
/usr/bin/ditto "$APPLICATION" "$STAGING_DIRECTORY/image/Pop.app"
ln -s /Applications "$STAGING_DIRECTORY/image/Applications"
cat > "$STAGING_DIRECTORY/image/安装说明.txt" <<INSTALL
Pop ${VERSION}（构建 ${BUILD}）

支持 macOS 15 及以上，Apple Silicon 和 Intel Mac。
将 Pop.app 拖入旁边的 Applications 文件夹，然后从“应用程序”打开 Pop。
更新已有版本时，请先退出正在运行的 Pop，再替换同名应用。

首次使用截图、取词和回填时，按应用提示授予相应系统权限。
此安装包不会自动安装或更改系统权限。
签名详情及首次打开说明请参阅项目 README；ad hoc 签名版本未经 Apple 公证，
macOS Gatekeeper 可能阻止首次打开，不能保证双击直接启动。
INSTALL

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIRECTORY/image/Pop.app" "$STAGING_DIRECTORY/$ASSET_NAME.zip"
/usr/bin/unzip -tq "$STAGING_DIRECTORY/$ASSET_NAME.zip" >/dev/null
/usr/bin/ditto -x -k "$STAGING_DIRECTORY/$ASSET_NAME.zip" "$STAGING_DIRECTORY/zip-check"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIRECTORY/zip-check/Pop.app"
for architecture in arm64 x86_64; do
    xcrun lipo "$STAGING_DIRECTORY/zip-check/Pop.app/Contents/MacOS/Pop" -verify_arch "$architecture"
done
/usr/bin/hdiutil create -quiet -volname "Pop $VERSION" -srcfolder "$STAGING_DIRECTORY/image" \
    -fs HFS+ -format UDZO -nospotlight "$STAGING_DIRECTORY/$ASSET_NAME.dmg"
/usr/bin/hdiutil verify -quiet "$STAGING_DIRECTORY/$ASSET_NAME.dmg"
(
    cd "$STAGING_DIRECTORY"
    /usr/bin/shasum -a 256 "$ASSET_NAME.zip" "$ASSET_NAME.dmg" > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

# Publish only complete, locally verified assets to the output directory.
for asset in "$ASSET_NAME.zip" "$ASSET_NAME.dmg" SHA256SUMS.txt; do
    if [[ "$REPLACE_EXISTING" == true ]]; then
        /bin/mv -f "$STAGING_DIRECTORY/$asset" "$OUTPUT_DIRECTORY/"
    else
        /bin/mv -n "$STAGING_DIRECTORY/$asset" "$OUTPUT_DIRECTORY/"
        [[ ! -e "$STAGING_DIRECTORY/$asset" ]] || { printf 'An output asset appeared while packaging.\n' >&2; exit 1; }
    fi
done
printf 'Release assets: %s/%s.{zip,dmg} and SHA256SUMS.txt\n' "$OUTPUT_DIRECTORY" "$ASSET_NAME"
printf 'Verified: universal architectures, app signatures, ZIP round trip, DMG integrity and SHA-256.\n'
printf 'Not installed, launched, uploaded or notarized.\n'

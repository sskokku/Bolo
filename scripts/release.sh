#!/usr/bin/env bash
# =============================================================================
# Bolo — Release Script (Direct Distribution with Notarization)
# =============================================================================
#
# USAGE:
#   ./scripts/release.sh [--version X.Y] [--build N] [--skip-notarize]
#
# PREREQUISITES (one-time setup):
#   1. Xcode with a valid "Developer ID Application" certificate in Keychain
#   2. Store your notarization credentials in the macOS Keychain (do this once):
#
#      xcrun notarytool store-credentials "bolo-notarize" \
#          --apple-id "your@email.com" \
#          --team-id  "KJ47YGNM8Z" \
#          --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
#
#      After running the above, notarytool reads the credentials automatically
#      by profile name — no passwords in shell history.
#
# WHAT THIS SCRIPT DOES:
#   1. Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml
#   2. Runs xcodegen to regenerate Bolo.xcodeproj
#   3. Archives Bolo.app with xcodebuild
#   4. Exports a Developer-ID-signed .app via ExportOptions.plist
#   5. Submits to Apple Notarization and waits for approval
#   6. Staples the notarization ticket to Bolo.app
#   7. Packages into a drag-install Bolo-<version>.dmg
#
# OUTPUT:
#   dist/
#     export/Bolo.app           (signed + notarized)
#     Bolo-<version>.zip        (intermediate, safe to delete)
#     Bolo-<version>.dmg        (ready to distribute)
#
# =============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_YML="$REPO_ROOT/project.yml"
XCODEPROJ="$REPO_ROOT/Bolo.xcodeproj"
SCHEME="Bolo"
CONFIGURATION="Release"
TEAM_ID="KJ47YGNM8Z"
BUNDLE_ID="com.bolo.app"
NOTARIZE_PROFILE="bolo-notarize"   # matches the --profile-name used in store-credentials
EXPORT_OPTIONS="$REPO_ROOT/ExportOptions.plist"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$DIST_DIR/Bolo.xcarchive"
EXPORT_PATH="$DIST_DIR/export"

# Colours for readability
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}▸ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────

SKIP_NOTARIZE=false
CUSTOM_VERSION=""
CUSTOM_BUILD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   CUSTOM_VERSION="$2"; shift 2 ;;
        --build)     CUSTOM_BUILD="$2";   shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Read current version from project.yml ─────────────────────────────────────

CURRENT_VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | awk '{print $2}' | tr -d '"')
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | awk '{print $2}' | tr -d '"')

VERSION="${CUSTOM_VERSION:-$CURRENT_VERSION}"
BUILD="${CUSTOM_BUILD:-$((CURRENT_BUILD + 1))}"

info "Bolo Release Builder"
echo "  Version : $VERSION"
echo "  Build   : $BUILD"
echo "  Notarize: $([[ $SKIP_NOTARIZE == true ]] && echo 'NO (--skip-notarize)' || echo 'YES')"
echo ""

# ── Step 1: Bump version in project.yml ───────────────────────────────────────

info "Bumping version → $VERSION ($BUILD)"
# Use perl for portable in-place sed (works on macOS without GNU sed)
perl -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
perl -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" "$PROJECT_YML"
success "project.yml updated"

# ── Step 2: Re-generate Xcode project ─────────────────────────────────────────

info "Running xcodegen…"
cd "$REPO_ROOT"
xcodegen generate --quiet
success "Xcode project regenerated"

# ── Step 3: Clean dist directory ──────────────────────────────────────────────

info "Preparing dist/ directory…"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ── Step 4: Archive ───────────────────────────────────────────────────────────

info "Archiving ($CONFIGURATION)…"
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | grep -E "(Build |error:|warning:|✓)" || true

[[ -d "$ARCHIVE_PATH" ]] || die "Archive failed — .xcarchive not found"
success "Archive complete → $ARCHIVE_PATH"

# ── Step 5: Export (Developer ID signed .app) ─────────────────────────────────

info "Exporting Developer-ID-signed app…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | grep -E "(Export |error:|warning:)" || true

APP_PATH="$EXPORT_PATH/Bolo.app"
[[ -d "$APP_PATH" ]] || die "Export failed — Bolo.app not found in $EXPORT_PATH"
success "Exported → $APP_PATH"

# ── Step 6: Notarize ──────────────────────────────────────────────────────────
# Note: always notarize/staple the plain Bolo.app — the .app name must stay
# "Bolo.app" so macOS registers it correctly in TCC (Privacy permissions).

ZIP_PATH="$DIST_DIR/Bolo-$VERSION.zip"

if [[ $SKIP_NOTARIZE == true ]]; then
    warn "Skipping notarization (--skip-notarize flag set)"
else
    info "Zipping for notarization…"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    success "Zipped → $ZIP_PATH"

    info "Submitting to Apple Notarization (this takes 1–5 min)…"
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait \
        --timeout 600 \
        2>&1 | tee "$DIST_DIR/notarization.log"

    # Check result
    if grep -q "status: Accepted" "$DIST_DIR/notarization.log"; then
        success "Notarization accepted!"
    else
        die "Notarization failed — see $DIST_DIR/notarization.log"
    fi

    info "Stapling notarization ticket to Bolo.app…"
    xcrun stapler staple "$APP_PATH"
    success "Ticket stapled"

    # Verify Gatekeeper will accept the app
    info "Verifying Gatekeeper acceptance…"
    spctl --assess --type exec --verbose "$APP_PATH" \
        && success "Gatekeeper: accepted" \
        || warn "Gatekeeper check returned non-zero — review output above"
fi

# ── Step 7: Create DMG ────────────────────────────────────────────────────────
# The app inside the DMG is always "Bolo.app" — the version is in the DMG
# filename and encoded in CFBundleShortVersionString inside the bundle.

DMG_PATH="$DIST_DIR/Bolo-$VERSION.dmg"
DMG_STAGING="$DIST_DIR/dmg_staging"

info "Creating DMG…"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/Bolo.app"

# Symlink to /Applications so the DMG has a drag-install arrow
ln -s /Applications "$DMG_STAGING/Applications"

# Create a read-write DMG first, then convert to compressed read-only
RW_DMG="$DIST_DIR/rw.dmg"
hdiutil create \
    -volname "Bolo $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW \
    "$RW_DMG" > /dev/null

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" > /dev/null
rm -f "$RW_DMG"
rm -rf "$DMG_STAGING"

success "DMG created → $DMG_PATH"

# ── Step 8: Summary ───────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Bolo $VERSION (build $BUILD) — Release Ready!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  📦 DMG  : $DMG_PATH"
echo "  🖥  App  : $APP_PATH  (named Bolo.app inside DMG)"
echo ""
echo "  Next steps:"
echo "    1. Open $DMG_PATH and drag Bolo.app to /Applications"
echo "    2. git tag v$VERSION && git push origin v$VERSION"
echo "    3. Upload $DMG_PATH to GitHub Releases"
echo "       (the GitHub Actions workflow does this automatically on tag push)"
echo ""

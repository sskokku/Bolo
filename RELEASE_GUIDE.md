# Bolo — Release Guide

Bolo is distributed directly (not through the Mac App Store) via a notarized `.dmg`.
This lets it use global hotkeys, cross-app text insertion, and Accessibility APIs
without App Sandbox restrictions.

---

## One-Time Setup

### 1. Developer ID Certificate

You need a **Developer ID Application** certificate — distinct from the "Apple Development" cert used for local builds.

1. Open **Xcode → Settings → Accounts → Manage Certificates**
2. Click **+** → **Developer ID Application**
3. Xcode creates and installs it automatically

### 2. Notarization Credentials (local releases)

Store your Apple ID credentials in the Keychain so the release script can use them without typing a password:

```bash
xcrun notarytool store-credentials "bolo-notarize" \
    --apple-id "your@email.com" \
    --team-id  "KJ47YGNM8Z" \
    --password "xxxx-xxxx-xxxx-xxxx"
```

> **What's the app-specific password?**
> Sign in at [appleid.apple.com](https://appleid.apple.com) → App-Specific Passwords → Generate.
> Use it here; never use your actual Apple ID password.

This writes to your local Keychain (not the repo). Run it once; re-run only if the password expires.

### 3. Install XcodeGen (if not already installed)

```bash
brew install xcodegen
```

---

## Local Release (Recommended)

Run the release script. It handles everything end-to-end.

```bash
# Release with the version already in project.yml, auto-incrementing build:
./scripts/release.sh

# Override version and/or build number:
./scripts/release.sh --version 1.1.0 --build 42

# Skip notarization (for a quick local test DMG — NOT for distribution):
./scripts/release.sh --skip-notarize
```

### What the script does

| Step | Action |
|------|--------|
| 1 | Bumps `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml` |
| 2 | Runs `xcodegen generate` |
| 3 | Archives via `xcodebuild archive` |
| 4 | Exports a **Developer ID** signed `.app` via `ExportOptions.plist` |
| 5 | Zips the `.app` (required format for `notarytool`) |
| 6 | Submits to Apple Notarization and waits (~2–5 min) |
| 7 | Staples the ticket to the `.app` |
| 8 | Packages into `Bolo-<version>.dmg` via `hdiutil` |

### Output

```
dist/
  Bolo-1.0.0.app    ← signed + notarized (keep or delete)
  Bolo-1.0.0.zip    ← notarization payload (safe to delete)
  Bolo-1.0.0.dmg    ← 👈 distribute this
  notarization.log  ← Apple's submission log
```

### After the script succeeds

```bash
# Tag and push (triggers the GitHub Actions release automatically)
git add project.yml
git commit -m "chore: bump version to 1.0.0"
git tag v1.0.0
git push origin main --tags
```

---

## Automated GitHub Releases (CI)

The workflow at `.github/workflows/release.yml` runs automatically when you push a version tag (`v1.0`, `v1.2.3`, etc.).

### Required GitHub Secrets

Go to **GitHub → Settings → Secrets and variables → Actions → New repository secret**:

| Secret name | Value |
|---|---|
| `APPLE_DEVELOPER_CERTIFICATE_BASE64` | Base64-encoded Developer ID `.p12` (see below) |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` |
| `NOTARIZE_APPLE_ID` | `your@email.com` |
| `NOTARIZE_APP_PASSWORD` | App-specific password from appleid.apple.com |
| `NOTARIZE_TEAM_ID` | `KJ47YGNM8Z` |

### Export your Developer ID certificate

1. Open **Keychain Access** → search for **Developer ID Application**
2. Right-click → **Export** → save as `DeveloperID.p12` (set a strong password)
3. Base64-encode it:
   ```bash
   base64 -i ~/Downloads/DeveloperID.p12 | pbcopy
   ```
4. Paste into the `APPLE_DEVELOPER_CERTIFICATE_BASE64` secret

### Triggering a CI release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will build, sign, notarize, and attach `Bolo-1.0.0.dmg` to a new GitHub Release automatically.

---

## Checklist Before Each Release

- [ ] All tests pass (if you add a test suite later)
- [ ] Version in `project.yml` is correct (`MARKETING_VERSION`)
- [ ] What's new is documented (release notes auto-generated from commits — keep commit messages clean)
- [ ] `xcodebuild` builds cleanly in Release mode locally
- [ ] App works on a clean Mac (no dev environment)
- [ ] Gatekeeper passes: `spctl --assess --type exec --verbose /path/to/Bolo.app`

---

## Troubleshooting

**"No signing certificate found"**
→ Make sure your Developer ID Application cert is in Keychain. Check in Xcode → Settings → Accounts.

**Notarization times out**
→ Apple's service can be slow. The script waits up to 10 min. Try again or check [developer.apple.com/system-status](https://developer.apple.com/system-status/).

**"Gatekeeper quarantine" warning on first launch**
→ The `.dmg` must be opened normally (not via Terminal `open`). Stapling solves this for all subsequent opens.

**stapler: "The staple and validate action failed"**
→ Notarization may have been rejected. Check `dist/notarization.log` for the failure reason.

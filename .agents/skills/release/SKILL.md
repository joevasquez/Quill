---
name: release
description: Publish a new version of the Quill macOS app. Covers the full release workflow — updating AGENTS.md, creating changesets, bumping versions, syncing version numbers across Info.plist and pbxproj, running the release script (archive, sign, notarize, DMG, Sparkle), managing the appcast for auto-updates, tagging, pushing to GitHub, and uploading to GitHub Releases. Use this skill when the user says "release", "ship", "publish", "cut a release", "bump version", "push a new version", or anything about deploying/distributing a new build of Quill.
---

# Quill Release Workflow

This skill walks through the complete process of shipping a new version of the Quill macOS app. Each step has a verification check — don't proceed until the check passes.

The release process has two main phases: **prep** (versioning, changelog, AGENTS.md) and **ship** (build, sign, notarize, distribute). The user may want to do just one phase (e.g., "update AGENTS.md and bump version" vs. "run the release script"), so ask which steps they need if it's not clear.

---

## Phase 1: Prep

### Step 1 — Update AGENTS.md

Any new features, architectural changes, bug fixes, or lessons learned from this development cycle should be documented in `AGENTS.md` before releasing. This is the project's living knowledge base for future agents.

**What to update:**

1. **Implementation Details** (numbered list starting at "## Important Implementation Details"): Add new entries for significant features or architectural decisions. Each entry is a numbered bold title followed by a paragraph explaining the what and why. Keep the numbering sequential.

2. **Lessons Learned** (numbered list under "## Lessons Learned (for agents)"): Add entries for gotchas, debugging insights, or patterns that would save a future agent time. Focus on things that were surprising or hard to figure out.

3. **Enhancement Opportunities** (numbered list under "## Enhancement Opportunities"): Remove items that were implemented in this cycle. Add new ones discovered during development.

4. **Other sections**: Update entitlements, dependencies, permissions, UI descriptions, etc. if they changed.

**How to update:**
```bash
# Review what changed since the last release tag
git log --oneline $(git describe --tags --abbrev=0)..HEAD
git diff $(git describe --tags --abbrev=0)..HEAD --stat
```

Read through the commits and diffs, then update the relevant AGENTS.md sections. Match the existing style — terse technical prose, no fluff.

**Verify:** Read back the sections you edited. Each new entry should be self-contained and useful to an agent seeing the codebase for the first time.

### Step 2 — Ensure changesets exist

Every user-facing change needs a changeset fragment in `.changeset/`. Check if any are pending:

```bash
ls .changeset/*.md 2>/dev/null | grep -v README.md
```

If there are no changesets and there are user-facing changes since the last tag, create them:

```bash
# For bug fixes / small improvements
bun run changeset:add-ai patch "Fix Edit mode race condition where fast transcription beat clipboard fallback"

# For new features
bun run changeset:add-ai minor "Add API key validation indicator in Settings UI"

# For breaking changes (rare)
bun run changeset:add-ai major "Description of breaking change"
```

Write one changeset per logical change. The summary should describe the user-facing impact, not the implementation detail. Reference GitHub issues with `(#123)` when applicable.

**Verify:** `ls .changeset/*.md | grep -v README` shows at least one changeset file.

### Step 3 — Bump version

This folds all changeset fragments into `CHANGELOG.md` and bumps the version in `package.json`:

```bash
bun run changeset:version
```

Read the new version from `package.json`:

```bash
grep '"version"' package.json | head -1
```

**Verify:** `package.json` has the new version, `CHANGELOG.md` has a new section at the top with the release notes, and the `.changeset/*.md` fragments are gone (consumed).

### Step 4 — Sync version numbers

`changeset version` only bumps `package.json`. You must manually sync the version to three other places. Read the new version from package.json first, then:

**4a. Update `Hex/Info.plist`:**
- `CFBundleShortVersionString` → the new version (e.g., `0.15.0`)
- `CFBundleVersion` → increment the build number by 1 (e.g., `99` → `100`)

**4b. Update `Hex.xcodeproj/project.pbxproj`:**
- `MARKETING_VERSION` → the new version (there are 4 occurrences for macOS — update all of them, but NOT the iOS occurrences)
- `CURRENT_PROJECT_VERSION` → the new build number (same 4 macOS occurrences)

To find which occurrences are macOS vs iOS, look at the surrounding context — macOS ones are in build configurations that reference `com.joevasquez.Quill` (not `.iOS`).

**4c. Copy changelog:**
```bash
cp CHANGELOG.md Hex/Resources/changelog.md
```

**Verify:**
```bash
# All four should show the same version
grep CFBundleShortVersionString Hex/Info.plist -A1
grep CFBundleVersion Hex/Info.plist -A1
grep MARKETING_VERSION Hex.xcodeproj/project.pbxproj | head -4
grep CURRENT_PROJECT_VERSION Hex.xcodeproj/project.pbxproj | head -4
# Changelog copied
diff CHANGELOG.md Hex/Resources/changelog.md
```

### Step 5 — Commit version bump

```bash
git add -A
git commit -m "$(cat <<'EOF'
Bump version to X.Y.Z

Co-Authored-By: Codex Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

Replace `X.Y.Z` with the actual version.

**Verify:** `git status` shows a clean working tree. `git log --oneline -1` shows the bump commit.

---

## Phase 2: Ship

### Step 6 — Pre-flight checks

Before running the release script, verify prerequisites:

```bash
# 1. Clean working tree
git status --porcelain

# 2. Codesigning identity exists
security find-identity -p codesigning -v | grep "Developer ID Application"

# 3. Notarization credentials stored
xcrun notarytool history --keychain-profile QUILL_NOTARY 2>&1 | head -3

# 4. Sparkle signing tools present
ls -la bin/sign_update bin/generate_appcast

# 5. xcode-select points at Xcode.app (not CommandLineTools)
xcode-select -p
```

**Verify:** All five checks pass. If `xcode-select` points at CommandLineTools, the script sets `DEVELOPER_DIR` itself, but it's better to fix it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Step 7 — Run the release script

This is the big one. It archives, signs, notarizes, creates the DMG, and generates the Sparkle appcast. Takes 5-10 minutes.

```bash
bash tools/scripts/release.sh
```

The script will:
1. Archive via `xcodebuild -scheme Quill -configuration Release`
2. Export with Developer ID signing (team `ND4KZ9EE2W`)
3. Submit to Apple notary service and wait for `Accepted`
4. Staple the notarization ticket
5. Create `Hex-latest.dmg`
6. Notarize + staple the DMG itself
7. Extract release notes from CHANGELOG.md
8. Sign the DMG with `bin/sign_update` (EdDSA for Sparkle)
9. Run `bin/generate_appcast` to produce `appcast.xml`

**Verify:**
```bash
# DMG exists and is reasonable size (~14 MB)
ls -lh build/release/Hex-latest.dmg

# Release notes extracted
cat build/release/release-notes.md

# Appcast generated
head -20 appcast.xml
```

### Step 8 — Preserve appcast rollback entry

`generate_appcast` writes a fresh `appcast.xml` with only the current build. To let users roll back, re-add the previous version's `<item>` block.

```bash
# Get the previous appcast from git
git show HEAD:appcast.xml
```

Copy the previous version's `<item>...</item>` block and add it after the new version's `<item>` in `appcast.xml`. The new version should be the FIRST item.

**Verify:** `appcast.xml` has two `<item>` blocks — the new version first, the previous version second. The `sparkle:version` in the first item matches the new build number.

### Step 9 — Commit appcast, tag, and push

```bash
git add appcast.xml
git commit -m "$(cat <<'EOF'
Update appcast for vX.Y.Z

Co-Authored-By: Codex Opus 4.6 <noreply@anthropic.com>
EOF
)"
git tag vX.Y.Z
git push origin main vX.Y.Z
```

**Verify:**
```bash
git log --oneline -2
git tag -l | tail -3
```

### Step 10 — Upload to GitHub Releases

```bash
gh release create vX.Y.Z --repo joevasquez/Quill \
  --title "Quill vX.Y.Z" \
  --notes-file build/release/release-notes.md \
  build/release/Hex-latest.dmg
```

If the release already exists (e.g., from a failed previous attempt):
```bash
gh release upload vX.Y.Z build/release/Hex-latest.dmg --clobber --repo joevasquez/Quill
```

**Verify:**
```bash
gh release view vX.Y.Z --repo joevasquez/Quill
```

The release should show the DMG as an asset and the release notes in the body.

### Step 11 — Verify Sparkle update flow

After pushing, the appcast is live at:
`https://raw.githubusercontent.com/joevasquez/Hex/main/appcast.xml`

Existing Quill installs will check this URL periodically. For the update to work:
- The `enclosure url` in appcast must point to the GitHub Release asset
- The `sparkle:edSignature` must match the exact DMG file uploaded
- The `sparkle:version` (build number) must be strictly greater than the installed version

If you re-built or re-notarized after the initial `generate_appcast`, the DMG changed — re-run:
```bash
bin/sign_update build/release/Hex-latest.dmg
bin/generate_appcast build/release/
```
Then re-commit the appcast and re-upload the DMG.

---

## iOS Release (TestFlight)

If the user also wants to push an iOS build:

```bash
bash tools/scripts/testflight.sh
```

This auto-bumps `CFBundleVersion` in `Quill iOS/Info.plist`, archives, and uploads to App Store Connect. TestFlight processes it in a few minutes.

If it fails, revert the build number bump:
```bash
git checkout "Quill iOS/Info.plist"
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Working tree is not clean" | Commit or stash first |
| `notarytool profile 'QUILL_NOTARY' not found` | Re-run `store-credentials` with the `.p8` API key at `~/.appstoreconnect/private_keys/AuthKey_3QDATSKTNN.p8` |
| Notarization returns `Invalid` | Run `xcrun notarytool log <id> --keychain-profile QUILL_NOTARY` for details |
| Build fails on `xcodebuild` | Ensure `xcode-select -p` shows `/Applications/Xcode.app/Contents/Developer` |
| Sparkle update not showing | Check: appcast pushed to main, edSignature matches DMG, sparkle:version > installed |
| TestFlight "build number must be higher" | Manually bump `CFBundleVersion` in `Quill iOS/Info.plist` |

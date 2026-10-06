# TestFlight Release Lane

## Overview

Pump Log ships internal TestFlight builds through a manual-dispatch GitHub Actions workflow (`.github/workflows/release.yml`).
The release pipeline executes `xcodebuild archive` and `-exportArchive` using the App Store Connect API key secrets configured on the repository, asserts registered identifiers and device family boundaries on the resulting `.xcarchive`, and polls the App Store Connect API until the uploaded build finishes processing.

## Configuration & Credentials

The workflow uses four repository Actions secrets (names only; values are never committed or logged):
- `ASC_KEY_ID`: App Store Connect API key ID
- `ASC_ISSUER_ID`: App Store Connect API issuer UUID
- `ASC_KEY_P8`: PEM-encoded private key content (`.p8`)
- `ASC_TEAM_ID`: Apple Developer team ID

### Secret Hygiene
- The `.p8` key file is written mode-600 inside `$RUNNER_TEMP` immediately before archive/export.
- The key file is deleted in an `always()` step regardless of job success or failure.
- Secret values are never echoed or written to console logs.
- Archive logs are kept out of published release evidence.

## Constraints & Gates

1. **Manual Dispatch Only**: Triggered solely via `workflow_dispatch` with an explicit `upload` boolean input (`true` for TestFlight upload, `false` for archive-and-export dry run).
2. **Monotonic Build Numbers**: `CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER` with `manageAppVersionAndBuildNumber=false`.
3. **App Store Connect Export Method**: Uses `method=app-store-connect` and `uploadMethod=app-store-connect`.
4. **App Icon Requirement**: Universal 1024x1024 opaque RGB asset catalog icon (`App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`).
5. **iPhone-Only Re-assertion**: Verifies `UIDeviceFamily == [1]` and `CFBundleIdentifier == com.infinityball.pumplog` on the archive `Info.plist`.
6. **Zero-Network Gate**: App runtime and tests remain zero-network; release helpers reside in `Scripts/` and operate only during manual release CI.
7. **Processing Polling**: Polls `GET /v1/builds` using an ES256 JWT until `processingState` completes (`VALID` / `COMPLETE`) and outputs `build_id` in `processed-build.json` and step summary.

## Honesty Doctrine & Fallback Policy

- If signing assets, certificates, or App Store Connect access are insufficient, the workflow fails closed with exact diagnostic logs.
- Never fake green or report TestFlight readiness without a real processed `build_id` from the ASC API.
- No public App Store submission is performed.

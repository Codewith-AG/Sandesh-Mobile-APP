# Sandesh Release & Self-Update Guide

This document outlines the architecture, setup, and standard operating procedures for the Sandesh app's self-update system and GitHub Actions CI/CD pipeline.

## 1. Architecture Overview

The Sandesh self-update system bypasses standard app stores and updates itself directly from a GitHub repository.

```text
[Sandesh App] 
     │
     ├─► [UpdateService] ─(checks API)─► [GitHub Releases API (Codewith-AG/Sandesh-Releases)]
     │                                           │
     │◄──(returns update.json)───────────────────┘
     │
     ├─► [Compares versionCode]
     │
     ├─► [Downloads APK via HttpClient]
     │
     ├─► [Validates SHA-256 hash]
     │
     └─► [Passes to Native PackageInstaller] ─► [Android OS installs update]
```

**Key Components:**
- **UpdateService:** Dart service orchestrating the check, download, and install.
- **UpdatePreferences:** Manages persistent state (e.g., last check time) using `SharedPreferences`.
- **Native PackageInstaller:** Android native code (Kotlin) that safely prompts the user and installs the downloaded APK.

## 2. GitHub Releases Repository

- **Repository:** `Codewith-AG/Sandesh-Releases`
- **Purpose:** Used strictly for binary distribution (Releases). It is public so the app can fetch updates without authentication.
- **Release Assets:** Each release contains two files:
  1. `sandesh-arm64.apk`
  2. `update.json`
- **Tag Format:** `v{versionName}+{versionCode}` (e.g., `v1.1.0+2`)

## 3. Required GitHub Actions Secrets

The following secrets must be added to the source repository (`Codewith-AG/Sandesh-Mobile-APP`):

| Secret Name | Description | Instructions |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded `.keystore` file | Run `base64 -w 0 sandesh-release.keystore` and paste the result. |
| `ANDROID_KEYSTORE_PASSWORD` | Password for the keystore | The `storePassword` from `key.properties`. |
| `ANDROID_KEY_ALIAS` | Alias of the signing key | e.g., `sandesh`. |
| `ANDROID_KEY_PASSWORD` | Password for the specific key | The `keyPassword` from `key.properties`. |
| `FLUTTER_ENV` | Contents of `.env` file | Paste the raw text of the production `.env`. |
| `RELEASE_PAT` | Personal Access Token (PAT) | A fine-grained PAT with **Contents: write** permissions strictly on `Codewith-AG/Sandesh-Releases`. Required for cross-repo publishing. |

## 4. Version Bump Procedure

When preparing a new release, you must update the version in `sandesh/pubspec.yaml`:

1. Locate the `version:` field.
2. Update the `versionName` (e.g., `1.0.0` -> `1.1.0`).
3. **CRITICAL:** Increment the `versionCode` (e.g., `+1` -> `+2`). Android requires the `versionCode` to be strictly increasing. You cannot reuse or decrease it.
4. Final format: `versionName+versionCode` (e.g., `1.1.0+2`).

## 5. Release Procedure

1. Ensure your code is pushed and merged into the `main` branch.
2. Go to the **Actions** tab in `Codewith-AG/Sandesh-Mobile-APP`.
3. Select the **Release Sandesh APK** workflow.
4. Click **Run workflow**.
5. Fill in the inputs:
   - **Release Notes:** A description of changes.
   - **Mandatory:** Check this box if users must update.
6. Run the workflow. It will automatically read the version from `pubspec.yaml`, build the APK, verify it is strictly newer, and publish it to the `Sandesh-Releases` repo.

## FOR AG — SIMPLE RELEASE STEPS

I do not code. Here is the exact, extremely simple procedure for you to release a new update of the app:

1. Ask AI to finish the new Sandesh changes.
2. Ask AI to bump the pubspec version (for example, if the current version is `1.0.0+1`, tell the AI to change it to `1.0.1+2`). The number after the `+` MUST go up.
3. Push/merge your code to the `main` branch.
4. Open the GitHub Actions tab in your repository.
5. Select the **Release Sandesh APK** workflow and run it.
6. Enter only the minimum required information (Release Notes and whether it's mandatory).
7. GitHub automatically reads the version, builds, signs, and publishes the new APK to `Sandesh-Releases`.
8. Users' Sandesh installations discover the new version automatically.

**Note:** The FIRST updater-enabled transition APK still needs to be installed manually by users who currently have an older version without the updater. After that manual update, all future releases will update automatically using this built-in updater system.

## 6. Signing Requirements

- Android requires that an app update is signed with the **exact same key** as the currently installed version.
- Ensure the keystore is backed up securely. If the keystore is lost, you will not be able to update existing users; they will have to manually uninstall and reinstall the app.
- To export your keystore for GitHub actions: `base64 -w 0 sandesh-release.keystore > keystore.b64` (use `-w 0` or `-b 0` depending on OS to disable wrapping).

## 7. How update.json Works

The CI/CD pipeline automatically generates an `update.json` file like this:
```json
{
  "packageName": "com.example.sandesh",
  "versionCode": 2,
  "versionName": "1.1.0",
  "apkAsset": "sandesh-arm64.apk",
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "mandatory": false,
  "releaseNotes": "Bug fixes"
}
```

- `versionCode`: Used by the app to determine if an update is available.
- `apkAsset`: The filename of the APK to download from the release assets.
- `sha256`: The app verifies the downloaded APK matches this hash before attempting installation.
- `mandatory`: If `true`, the UI should block the user until they update.

## 8. Testing a Release

To test locally before publishing:
1. Build the app using `flutter build apk --release`.
2. Install it on your device: `adb install build/app/outputs/flutter-apk/app-release.apk`.
3. Create a Draft or Pre-release in the GitHub repo with a higher version code.
4. Launch the app and verify the update prompt appears and installs successfully.

## 9. Rollback Limitations

- **Android prevents downgrades.** You cannot install an APK with a `versionCode` lower than the currently installed one without first uninstalling the app.
- If a bad release is deployed, you must fix the code, bump the `versionCode` (e.g., from `3` to `4`), and release a new version.

## 10. First Transition APK

Since the self-update system is new:
- Existing users must manually download and install the very first APK that contains the update logic.
- After this initial manual installation, the app will handle all future updates automatically.
- This transition APK must be signed with the exact same key as the current version they have installed.

## 11. Cross-Repository Publishing

- **Why a PAT?** The default `GITHUB_TOKEN` provided by Actions only has permissions for the repository where the workflow is running. Since we build in `Sandesh-Mobile-APP` but publish to `Sandesh-Releases`, we need explicit cross-repo permissions.
- **Creation:** Go to GitHub Settings -> Developer Settings -> Personal access tokens -> Fine-grained tokens. Give it access to `Codewith-AG/Sandesh-Releases` and grant `Contents: write`.

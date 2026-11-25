# iPhone from Windows: GitHub Actions → TestFlight

The files are prepared locally; they must be committed and pushed before GitHub
can run them. No Apple certificate, account, profile or upload is configured by
merely adding a workflow. The source prototype still needs its first Xcode build
and physical NFC/Wi-Fi acceptance.

## 1. Push the prototype and check compilation without an Apple account

1. In Android Studio Git or GitHub Desktop, commit and push the complete iPhone
   prototype, `tools/ios`, and `.github/workflows` to
   [jkaleba/SkyChat](https://github.com/jkaleba/SkyChat). Keep `.private` out of Git;
   it is ignored, along with `.p12`, `.p8` and provisioning profiles.
2. The workflow files must exist on the repository's **default branch** for the
   manual **Run workflow** button to appear. Merge your implementation branch
   there first if necessary.
3. Open [Actions](https://github.com/jkaleba/SkyChat/actions) → **iOS prototype** →
   **Run workflow** → select the branch containing the prototype → **Run workflow**.
4. GitHub supplies macOS, Flutter and Xcode, builds the iOS Simulator application,
   and runs the five Swift protocol tests. Fix any build/test errors before
   configuring distribution. This workflow requires no Apple secrets.

The Simulator build cannot be installed on a real iPhone. It verifies compilation
and native protocol logic, not NFC/radio interoperability.

## 2. Obtain Apple Developer access

Use an active Apple Developer Program membership, or a team account provided by
your employer/university. NFC Tag Reading is unavailable to a free Personal Team.
The standard individual membership is USD 99/year, with local pricing and some
institutional fee waivers. You need permission to manage Certificates,
Identifiers & Profiles; API team-key creation requires Account Holder or Admin.

- [Membership](https://developer.apple.com/programs/enroll/)
- [Supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

All remaining configuration can be done in a browser and PowerShell on Windows.

## 3. Register the application identifier and capabilities

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list).
2. Select **Identifiers → + → App IDs → App**.
3. Use a description such as `SkyChat` and an **Explicit** Bundle ID you control,
   for example `pl.jkaleba.skychat` if available. Save this exact identifier.
4. Enable **Near Field Communication Tag Reading** and **Hotspot Configuration**.
5. Register/save the App ID. If you change these capabilities later, regenerate
   the provisioning profile in step 6.

The signed workflow takes the registered Bundle ID and Team ID from your profile
and sets them only in the iOS Runner target on the temporary runner. You do not
have to edit Android package identifiers or commit signing settings.

## 4. Generate a certificate request on Windows

Open PowerShell in the SkyChat project folder. The helper uses OpenSSL from PATH
or the copy included with Git for Windows.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios\prepare-signing.ps1 -Step request
```

The execution-policy flag applies only to this invocation. The script creates:

- `.private/ios-signing/distribution.key`: private RSA key; keep it on your computer.
- `.private/ios-signing/SkyChat.certSigningRequest`: public certificate request for Apple.

If the files already exist, the script stops instead of replacing your key.

## 5. Create Apple Distribution and export P12

1. In the Apple portal choose **Certificates → + → Apple Distribution**.
2. Upload `SkyChat.certSigningRequest` from step 4.
3. Download the resulting `.cer`, for example to `Downloads/distribution.cer`.
4. On the same Windows computer, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios\prepare-signing.ps1 -Step export -CertificatePath "$env:USERPROFILE\Downloads\distribution.cer"
```

5. Choose a P12 password when prompted. Keep it for the GitHub secret
   `P12_PASSWORD`. The script creates `distribution.p12` and
   `.private/ios-signing/BUILD_CERTIFICATE_BASE64.txt` without printing credentials.

The Apple certificate must have been created from this same CSR/private key.
A certificate downloaded from someone else's request cannot be exported with
your private key.

## 6. Create the App Store Connect provisioning profile

1. Apple portal: **Profiles → + → Distribution → App Store Connect**.
2. Choose the explicit App ID from step 3.
3. Choose the Apple Distribution certificate created in step 5.
4. Name it `SkyChatTestFlight`, generate it, and download the `.mobileprovision`.
5. To copy its Base64 contents on Windows, adapt the downloaded filename:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Downloads\SkyChatTestFlight.mobileprovision")) | Set-Clipboard
```

Use this value as `BUILD_PROVISION_PROFILE_BASE64` in step 9. The workflow checks
the profile's expiration, App Store distribution type, NFC/Hotspot capabilities,
Bundle ID, team, and its match to the certificate/private key before building.

## 7. Create the App Store Connect app record

1. Open [App Store Connect](https://appstoreconnect.apple.com/).
2. **My Apps/Apps → + → New App**.
3. Choose iOS, name `SkyChat`, your primary language, and the **same Bundle ID**
   registered in step 3. SKU can be an internal identifier such as `skychat-ios`.
4. Create the record. You can use TestFlight without publishing the app publicly.

## 8. Create the upload API key

1. App Store Connect: **Users and Access → Integrations → App Store Connect API**.
2. If API access has not been enabled, the Account Holder requests it here first.
3. Under **Team Keys**, generate a key named `SkyChat GitHub`, with **App Manager**
   access. This workflow expects a team key, not an individual key.
4. Download the `.p8` once and save it outside Git. Copy the **Key ID** and
   **Issuer ID** shown by Apple.
5. Open the `.p8` in a text editor. Its complete text, including BEGIN/END lines
   and newlines, becomes `APP_STORE_CONNECT_API_KEY`. It is not Base64.

## 9. Add six GitHub environment secrets

Repository → **Settings → Environments → New environment** → name it exactly
`ios-testflight`. Inside that environment, use **Add environment secret**:

| Secret name | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Full contents of `.private/ios-signing/BUILD_CERTIFICATE_BASE64.txt` |
| `P12_PASSWORD` | Password selected during P12 export |
| `BUILD_PROVISION_PROFILE_BASE64` | Base64 profile copied in step 6 |
| `APP_STORE_CONNECT_API_KEY` | Complete plaintext `.p8` file contents |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from the team-key page |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from the team-key page |

To copy the certificate value without opening the file:

```powershell
Get-Content -LiteralPath .private/ios-signing/BUILD_CERTIFICATE_BASE64.txt -Raw | Set-Clipboard
```

Enter each value directly in GitHub's secret field. None belongs in a commit,
workflow YAML, issue, screenshot, or chat message. The signing workflow installs
credentials in temporary files/keychain and cleans them up after the job.

## 10. Build and upload

1. Open **Actions → iOS TestFlight → Run workflow**.
2. Select the implementation branch.
3. Leave **build_number** empty: the workflow generates a new numeric build number,
   including a new number for a rerun. If Apple already has higher numbers from
   another build system, supply your own unused, greater number.
4. Enable **Upload the signed build to App Store Connect for TestFlight** to send
   this build to Apple. With the checkbox off, it only builds and saves an IPA.
5. Click **Run workflow** and inspect the job. No public App Store release is
   performed; this upload only supplies a build for App Store Connect/TestFlight.

The workflow uses a macOS runner with a modern Xcode SDK, satisfying Apple's
current Xcode 26+/iOS 26+ upload requirement. The prototype's minimum device OS
remains iOS 15. The first remote run can still uncover Xcode/SDK integration
issues that Windows compilation cannot detect.

The IPA under **Artifacts** is App Store signed. Downloading it alone is not an
installation method for an arbitrary iPhone; use TestFlight for this workflow.

## 11. Install on iPhone

1. Wait until Apple finishes processing the build in the app's **TestFlight** tab.
2. If Apple displays **Missing Compliance**, complete its encryption information
   accurately. SkyChat uses cryptography; this workflow does not predeclare an
   exemption on your behalf. Resolve any pending account agreements as shown.
3. **Internal Testing → +**: create a group, e.g. `SkyChat Tests`.
4. Add your own App Store Connect user as an internal tester and select the build.
   Other internal testers must be eligible App Store Connect team users; for
   ordinary outside testers use the external-testing process and Apple's review.
5. Install **TestFlight** from the App Store on iPhone, accept the invitation and
   install SkyChat. No USB connection to the cloud Mac is required.
6. Install the new Android build on the other phone and follow
   [NFC pairing and chat acceptance](ios-prototype.md).

## Common failures

- **Run workflow missing:** commit the YAML on the default branch; enable Actions
  if disabled by repository policy.
- **Missing secret:** spelling and environment must match `ios-testflight`.
- **Capability absent:** update the App ID and regenerate/download the profile.
- **P12/profile mismatch:** use the certificate created from the local CSR/key,
  select that certificate when regenerating the profile, then update both secrets.
- **Duplicate build:** rerun for a new automatic number or supply a higher number.
- **App record not found:** App Store Connect Bundle ID must match the profile.
- **Build rejected by Apple:** read the upload diagnostic and App Store Connect
  processing status; a successful Xcode build alone does not guarantee acceptance.

References:

- [Apple signing on GitHub runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Flutter iOS build/upload](https://docs.flutter.dev/deployment/ios)
- [Apple App Store provisioning](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [App Store Connect API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Internal TestFlight testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)
- [Current SDK upload requirements](https://developer.apple.com/news/upcoming-requirements/)

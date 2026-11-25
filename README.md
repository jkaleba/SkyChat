# SkyChat

**Course:** Mobile Systems 2026/27 AGH University

For detailed architecture, setup instructions, and the original project description, see [description.md](description.md).

For the technologies, NFC payloads, Wi-Fi Direct setup, private authentication,
chat and call flows, see the [implementation guide](docs/implementation-guide.md).
The [source map](docs/source-map.md) lists the files and methods for each feature.

Pull requests run Android builds/tests and iOS Simulator checks. See
[required checks and merge protection](docs/github-checks.md) to require successful
checks before merging into `master` and understand GitHub Actions allowances.

Android keeps [encrypted saved conversations and drafts](docs/chat-history.md)
across app restarts. Open **Groups > Saved conversations** to read or delete
local history. Rejoining the same running chat restores its draft without
automatically sending messages or restoring private-group membership.

An [iPhone client prototype](docs/ios-prototype.md) adds NFC contact reading,
mutual contact confirmation, and NFC invitations to join an Android host over
ordinary Wi-Fi. It requires macOS/Xcode provisioning and physical iPhone/Android
acceptance; iOS compilation and radio interoperability are not established here.
The [Windows-to-TestFlight guide](docs/ios-github-actions.md) covers GitHub Actions,
Windows certificate generation, signing secrets and installing on iPhone.

Private groups now use one-time NFC contact verification, anonymous nearby group
labels, explicit host approval and contact-authenticated TLS 1.3, including resume
tokens. Both phones need this build. Group text is encrypted to the host, which
forwards messages; physical-phone acceptance remains pending. See
[private group security](docs/private-group-security.md).

On Android, [first launch](docs/first-run.md) offers a display name or Guest and
explains offline Wi-Fi use before opening group controls. Existing saved names
skip setup, and permissions remain tied to the actions that need them.

The Android [Groups screen](docs/group-entry.md) separates creating a group from
joining one. Nearby search, QR and supported NFC invitations are on the join
page; an active group puts opening the chat first.

## Weekly Updates

### Week 1
- Scaffolded the Flutter app with Kotlin Android and Swift iOS connectivity bridges.
- Added Android Wi-Fi Direct group creation/joining, QR code invitations, and NFC tap invitations.
- Implemented offline group text chat over TCP with host broadcasting and participant lists.

### Week 2
- Added resumable chat sessions with history replay, safe retries, and three-stage delivery receipts.
- Implemented NFC-only private groups, public DNS-SD group discovery, participant revocation, and Wi-Fi Direct connection recovery.
- Built BLE/GATT and local WebRTC Wi-Fi Direct audio feasibility labs.
- Added hardware-backed Keystore identities, encrypted NFC-verified contacts, and authenticated foreground voice calling.

### Week 3
- Integrated NFC contact calling screens and foreground call lifecycle.
- Reworked the UI to SkyChat branding with bottom navigation (`Groups`, `Contacts`, `Calls`) and added an Android foreground service with message notifications.
- Unified group discovery, advertised host usernames, added contact-ID-based dynamic naming with `(unknown)` labels, deduplicated rejoining participants, and added Current/Last connection status.

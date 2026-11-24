# SkyChat

**Course:** Mobile Systems 2026/27 AGH University

For detailed architecture, setup instructions, and the original project description, see [description.md](description.md).

For the technologies, NFC payloads, Wi-Fi Direct setup, private authentication,
chat and call flows, see the [implementation guide](docs/implementation-guide.md).
The [source map](docs/source-map.md) lists the files and methods for each feature.

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

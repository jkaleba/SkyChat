# Architecture

## Stack and boundaries

Flutter / Dart owns screens, themes, navigation, chat state, message models and
the TCP messaging layer and call controller. Kotlin owns Android Wi-Fi Direct,
NFC contact enrollment, Keystore identity and encrypted contact persistence.
Swift owns the iPhone client prototype (NFC reader, Keychain contacts and joining
an Android host as an ordinary Wi-Fi client). There is no cloud backend.

The app uses local Flutter plugins `packages/offline_connectivity` and
`packages/offline_audio` (shared with Transport Lab for P2P observation and WebRTC).
Flutter registers its Kotlin and Swift implementations automatically. Native code
does not belong in widgets, and shared chat logic does not belong in Kotlin.

The connectivity bridge follows Flutter's platform-channel architecture:
https://docs.flutter.dev/platform-integration/platform-channels

## Current implementation

- Standard Flutter Android and iOS application hosts.
- Shared Material 3 home screen with light and dark themes.
- Local plugin with a working getCapabilities method on both platforms.
- Android checks whether Wi-Fi Direct hardware is advertised by the device.
- Swift implements an iPhone NFC/Wi-Fi client prototype; see
  [iPhone setup and acceptance](ios-prototype.md). Physical acceptance is pending.
- Android implements create/discover/join/disconnect and reports
  implementationReady=true. iOS reports implementationReady=true and
  wifiDirectSupported=false: it reads NFC invitations and joins as an ordinary
  Wi-Fi client, and does not host or use Android discovery. This flag means the adapter is implemented, not that a
  connection is established or that messaging exists.
- ActivityAware handles runtime permission requests. The engine owns the receiver
  and P2P channel; activity resume refreshes system connection state. Detaching
  releases listeners and attempts group cleanup. Explicit disconnect is preferred.
- An EventChannel carries snapshots. The actual group-owner address comes from
  WifiP2pInfo, not an assumed subnet. Action success only acknowledges acceptance;
  connected state requires groupFormed and a non-null group-owner address.
- Requests have a 15-second callback timeout. Connecting is rechecked for about
  60 seconds to catch missing broadcasts and rejected invitations. It can also
  be cancelled from the UI. Callback revisions discard obsolete operation results.
- Shared message and participant models and a message transport interface.
- ChatSessionController owns conversation history, drafts, outgoing message states
  and native connection coordination outside HomeScreen. TcpMessageTransport owns
  sockets, the resume handshake, host replay/acceptance caches and ordering cursors.
  The controller starts chat on a connected native snapshot using the actual host
  address and TCP port 45871. Duplicate snapshots do not restart chat.
- Client network loss suspends sockets without clearing session state. A restored
  connected snapshot resumes automatically; TCP-only loss offers Retry chat.
  Retry message preserves its request ID. Replay reconciles uncertain sends with
  host-accepted messages. No automatic resend of uncertain sends is performed.
- Host departure or a changed host session ends the conversation. Explicit new
  chat clears the live history/draft/outbox; rejoining never silently sends them
  to a different group. Android separately archives messages and drafts in a
  Keystore-encrypted local store. Network credentials and live session state
  remain scoped to the process; archives never restore group access or resend.
  See chat-protocol.md for protocol v3, bounded replay and retry limitations.
- Public host QR invitations use group network credentials fetched on explicit request.
  Android 10+ joins with WifiP2pConfig.Builder SSID/passphrase; discovery remains
  available on older versions. mobile_scanner uses bundled ML Kit so first scan
  does not require Internet. qr_flutter renders a black-on-white QR in either theme.
- Optional Android NFC uses a non-payment HostApduService and reader mode, not
  Android Beam. A separate NfcInvitationController handles activity lifecycle,
  timeouts and cancellation. InvitationApdu is a pure Kotlin protocol with JVM
  tests. Both QR and NFC return the same validated GroupInvitation and require
  the same confirmation before joinInvitation. No NFC chat transport is added.
- Private groups require NFC-verified contacts, TLS 1.3 and explicit host approval
  for each live chat. Resume requires a fresh contact proof and a matching member
  token; removal revokes both membership and the token. See private-group-security.md.
- PublicGroupDiscovery registers app-specific DNS-SD records. Public records may
  name the host; private version-4 records carry only a random per-group label,
  with no name, contact fingerprint or credentials. Nearby entries expire after
  60 seconds. Advertisements are untrusted hints, not authenticated identities.

## Next implementation steps

Contacts/calling extension: [contacts-and-calls.md](contacts-and-calls.md).
C2 adds durable contacts and a separate mutual NFC verification flow. C3 uses
`CallController` and signed directed signaling on the existing chat connection,
with P2P-only WebRTC media outside the TCP chat queue. Contact signing keys and
the AES-GCM store key stay in Android Keystore; only public contact data reaches
Dart. Private chat uses authenticated TLS to the host; public chat remains plaintext.
The host forwards and can read group text. Its replay journal remains in memory;
Android separately retains [encrypted local archives](chat-history.md). The audio plugin
observes the existing group and never removes it. C3 is foreground host/client
calling; integrated hardware acceptance remains pending.
BLE invitations and accepted-call temporary Wi-Fi Direct setup are future C4 work.
Contacts, group membership, Wi-Fi ownership and call consent remain separate.
Background calling and group push-to-talk remain later milestones.

The canonical sequence is in [roadmap.md](roadmap.md). Session recovery is
implemented with automated coverage. Host acceptance remains distinct from
recipient delivery or read receipts. Protocol v3 adds identity-bound client
acknowledgements and bounded delivery snapshots sent only to the message sender.
See delivery-receipts.md for three-stage checks and resume behavior. State uses memory only.

Run the two/three-phone Wi-Fi Direct, chat and NFC checks and record device/OS
versions and outcomes. Partial results are recorded in offline-connection-recovery.md
and discovery-join-recovery.md; the complete interoperability gate remains open.
Automated recovery tests do not satisfy that hardware gate.

Authenticated encryption, durable storage and background operation follow.
App-specific public discovery and NFC-only private admission are implemented;
see group-modes.md for their limits and hardware acceptance checks.

The Android host leaving ends the group in the first prototype. Host migration,
multi-hop forwarding and background operation are separate milestones.

## Future iPhone support

The Flutter GUI is shared. The [iPhone client prototype](ios-prototype.md) adds
the Swift side of the same plugin. NFC pairs contacts in two taps, then a separate
NFC group invitation carries Wi-Fi credentials and the actual host address.
An iPhone attempts to join the Android group as an ordinary Wi-Fi client. Test
on actual devices early; OEM interoperability is not established by source code.

Shared Dart TCP code can then exchange the same messages with the Android host.
The native connection method may differ, and user interaction may be necessary.
Adding Swift does not itself guarantee interoperability.

Build and test iOS on macOS with Xcode. Windows can edit the shared UI and Swift
source, but cannot compile or validate the iOS application.

## Toolchain

Flutter 3.35.7 is the pinned baseline for this scaffold (Dart 3.9).
Use the generated Flutter Android toolchain rather than independent Compose/KMP
Gradle configuration. The downloaded .tools/flutter SDK is ignored by Git.

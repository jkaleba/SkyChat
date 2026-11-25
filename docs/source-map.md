# SkyChat source map

Use this map to locate the implementation of NFC, Wi-Fi Direct, discovery,
authentication, chat and calls. The [technology and flow guide](implementation-guide.md)
explains how these pieces interact, including the two separate NFC protocols.

## Repository layout

```text
SkyChat/
|-- lib/                              Flutter application
|   |-- main.dart                     Entry point
|   |-- app/                          Material app and theme
|   |-- core/
|   |   |-- background/               Android service and notification wrapper
|   |   |-- calling/                  Call state and authenticated signaling
|   |   |-- contacts/                 Native contacts and signing wrapper
|   |   |-- messaging/                Session state, TCP and private TLS
|   |   `-- models/                   Messages, participants and receipts
|   `-- features/
|       |-- home/                     Groups, discovery and app navigation
|       |-- chat/                     Chat UI and private membership decisions
|       |-- contacts/                 Contact list and NFC pairing UI
|       |-- calling/                  Incoming and active call UI
|       `-- invitations/              QR reader and retained NFC invitation UI
|-- packages/
|   |-- offline_connectivity/         Local Flutter connectivity plugin
|   |   |-- lib/                      Dart wrapper and connection models
|   |   |-- android/src/main/kotlin/   Android P2P, NFC, contacts and security
|   |   |-- android/src/main/res/xml/  NFC HCE AID registration
|   |   |-- android/src/test/kotlin/   Native JVM protocol and state tests
|   |   |-- ios/Classes/              iPhone NFC/Wi-Fi client and contact proofs
|   |   `-- test/                     Dart bridge and invitation tests
|   `-- offline_audio/                Shared WebRTC audio plugin
|       |-- lib/                      Media lifecycle and ICE filtering
|       `-- android/src/main/kotlin/   Existing P2P interface observation
|-- android/                          Android application host and build
|-- ios/                              iOS application scaffold
|-- assets/images/                    Branding assets
|-- test/                             App, socket, security and widget tests
|-- tools/transport_lab/               Separate BLE and audio experiment app
|-- docs/                             Architecture, protocols and device checks
|-- README.md                         Project entry point and documentation links
|-- description.md                    Original project description and setup
|-- pubspec.yaml                      Application dependencies and assets
`-- pubspec.lock                      Resolved Dart package versions
```

`.tools/` contains the local toolchain. `build/`, `.dart_tool/` and Gradle caches
are generated output rather than implementation sources. Android package names
and channel identifiers retain `offlinegroupmessenger` even though the UI is
branded SkyChat.

## Start here for each feature

| Task | Start in Flutter | Follow into the implementation |
| --- | --- | --- |
| Understand application startup | [main.dart](../lib/main.dart), [app.dart](../lib/app/app.dart) | [HomeScreen](../lib/features/home/home_screen.dart) owns the session, call controller and native state subscription. |
| Change create, discover or join behavior | [HomeScreen](../lib/features/home/home_screen.dart), [OfflineConnectivity](../packages/offline_connectivity/lib/offline_connectivity.dart) | `OfflineConnectivityPlugin.onMethodCall` and `execute` in the native plugin below. |
| Find NFC contact pairing | [ContactsScreen and ContactPairingScreen](../lib/features/contacts/contacts_screen.dart), [ContactRepository](../lib/core/contacts/contact_repository.dart) | `ContactsBridge` -> `NfcContactsController` -> `ContactPairing` and `ContactApdu`. |
| Find NFC group invitation transfer | [NfcInvitationScreen](../lib/features/invitations/nfc_invitation_screen.dart) | `NfcInvitationController`, `NfcInvitationService`, `InvitationApdu`. The screen currently has no caller in `HomeScreen`. |
| Change public QR invitations | [HomeScreen](../lib/features/home/home_screen.dart), [ScanInvitationScreen](../lib/features/invitations/scan_invitation_screen.dart) | [GroupInvitation](../packages/offline_connectivity/lib/src/group_invitation.dart), native `getInvitation` and `joinInvitation`. |
| Find nearby app group discovery | [HomeScreen](../lib/features/home/home_screen.dart) | `PublicGroupDiscovery`, `PublicGroupRecord`, `ServiceDiscoverySetup`; both group modes use these classes. |
| Find private group authentication | [private_channel.dart](../lib/core/messaging/private_channel.dart), [tcp_message_transport.dart](../lib/core/messaging/tcp_message_transport.dart) | `PrivateChannelCertificate`, `ContactsBridge`, `ContactBook.signPrivateChannel` and `verifyPrivateChannel`. |
| Change legacy-host notices or removal UI | [private_membership_panel.dart](../lib/features/chat/private_membership_panel.dart), [chat_screen.dart](../lib/features/chat/chat_screen.dart) | Transport `waitingForApproval`, `removePrivateMember`; controller `removePrivateMember`. |
| Find message sending and recovery | [ChatSessionController](../lib/core/messaging/chat_session_controller.dart) | [TcpMessageTransport](../lib/core/messaging/tcp_message_transport.dart). |
| Find delivery checkmarks | [chat_screen.dart](../lib/features/chat/chat_screen.dart), [message_delivery.dart](../lib/core/models/message_delivery.dart) | Transport `_accept`, `_publishDelivery` and `received` handling in `_receive`. |
| Find voice calling | [CallController](../lib/core/calling/call_controller.dart), [CallScreen](../lib/features/calling/call_screen.dart) | [LocalAudioSession](../packages/offline_audio/lib/src/local_audio_session.dart), native `P2pObserver`. |
| Find service, notifications or username storage | [BackgroundService](../lib/core/background/background_service.dart), [ContactRepository](../lib/core/contacts/contact_repository.dart) | Android `MainActivity` and `SkyChatBackgroundService`, linked below. |
| Find BLE | [Transport Lab main](../tools/transport_lab/lib/main.dart) | Lab-only `BleLab.kt`, linked below. BLE is not the production group transport. |

## Flutter state and transport files

| File | Responsibility and useful symbols |
| --- | --- |
| [home_screen.dart](../lib/features/home/home_screen.dart) | Groups/Contacts/Calls navigation; `_load` subscribes to connectivity, `_buildPeerCard` joins nearby groups, `_confirmInvitation` confirms credential joins, `_syncBackgroundService` starts service support. |
| [chat_session_controller.dart](../lib/core/messaging/chat_session_controller.dart) | Keeps history, draft and outbox across navigation/socket loss. Follow `configureGroup`, `prepareJoin`, `prepareNearbyJoin`, `updateConnection`, `retry`, `sendDraft`, `retryMessage`, `leave` and `beginNewSession`. |
| [chat_history_repository.dart](../lib/core/history/chat_history_repository.dart) | Serialized local archive saves, loading/retry, deletion, retention and the Android history channel. |
| [saved_conversation.dart](../lib/core/history/saved_conversation.dart) | Versioned archive models, strict decoding and bounded size accounting. |
| [saved_chats_screen.dart](../lib/features/history/saved_chats_screen.dart) | Saved conversation list/detail, preserved drafts, storage error recovery and confirmed local deletion. |
| [tcp_message_transport.dart](../lib/core/messaging/tcp_message_transport.dart) | Chat v3 implementation: sockets, frame parsing, participant identities, TLS handshake integration, automatic verified-contact admission, broadcasting, receipts, replay, request deduplication and directed call routing. |
| [private_channel.dart](../lib/core/messaging/private_channel.dart) | TLS 1.3 client setup, host `SecurityContext` setup and certificate SHA-256 fingerprints. |
| [message_transport.dart](../lib/core/messaging/message_transport.dart) | Small transport interface: host, connect, send, close and incoming stream. |
| [chat_message.dart](../lib/core/models/chat_message.dart) | Accepted message model, canonical ID, group, sender, contact ID, timestamp and sequence. |
| [participant.dart](../lib/core/models/participant.dart) | Participant ID, display name, optional persistent contact ID and call capability. |
| [message_delivery.dart](../lib/core/models/message_delivery.dart) | Immutable delivery target/receipt state and one/two/three-check calculation. |
| [contact_repository.dart](../lib/core/contacts/contact_repository.dart) | Typed contact snapshots; pairing start/status/approve/stop; rename/block/delete/reset; private-channel and call sign/verify methods; saved-name resolution. |
| [call_controller.dart](../lib/core/calling/call_controller.dart) | Verified online presence, signed directed control frames, invite/answer/end, call races, foreground handling and media ownership. |
| [background_service.dart](../lib/core/background/background_service.dart) | Platform-channel wrapper for notification permission, service start/stop, message notifications and moving the task to background. |
| [user_profile.dart](../lib/core/profile/user_profile.dart) | Local profile contract, name validation and native setup channel with legacy-adapter fallback. |
| [first_run_gate.dart](../lib/features/onboarding/first_run_gate.dart) | First-run name/Guest choice, offline-use guidance, save/load retry and deferred home-screen construction. |

Android group entry is described in [group navigation](group-entry.md).
`HomeScreen` keeps live create/join routes in sync with its connection and chat
state; shared builders render status, host invitations, saved conversations and
nearby results. Native discovery and admission remain in the connectivity plugin.

Within `TcpMessageTransport`, these methods form useful reading routes:

- Server startup: `startHost` -> `_secureIncoming` for private TLS -> `_acceptSocket`.
- Client startup: `connect` -> private `private_open`/`private_host` exchange or
  public `_sendHello` -> `_listen` -> `_receive`.
- Private proof exchange: `_openPrivateChannel`, `_authenticatePrivateHost`,
  `_hello`, then `ContactRepository`'s native signing/verifying calls.
- Admission: `_hello` -> bound NFC proof and current contact verification ->
  `_completeHello` -> welcome, roster, replay and synced frames.
- Message delivery: `send` -> `_accept` -> `_broadcast` -> `_receive` receipts ->
  `_publishDelivery`.
- Recovery and removal: `_completeHello`, `_lost`, `_stop`, `resetSession`,
  `removePrivateMember`.
- Calls: `sendCall`, `_routeCall`, `_allowCall`; these frames do not enter history.

## Native connectivity and Wi-Fi Direct files

The Kotlin files below are under
`packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/`.

| File | Responsibility and useful symbols |
| --- | --- |
| [OfflineConnectivityPlugin.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/OfflineConnectivityPlugin.kt) | Plugin registration, `WifiP2pManager` channel, permissions, broadcasts and lifecycle. `onMethodCall` validates commands; `execute` creates/joins/disconnects; `readConnection` and `readHostInterface` obtain authoritative state/address; `emit` publishes snapshots and updates advertisements; `getInvitation` fetches current credentials. |
| [ConnectionSetup.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ConnectionSetup.kt) | Separates native action acceptance from formed-group success; callback and overall setup deadlines; stale-operation guards. |
| [OfflineGroupCredentials.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/OfflineGroupCredentials.kt) | Generates random, temporary SSID and passphrase for API 29+ group creation. |
| [PublicGroupDiscovery.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/PublicGroupDiscovery.kt) | DNS-SD advertisement, scanning cycles, result expiry and stopping. Handles both public and private groups. |
| [PublicGroupRecord.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/PublicGroupRecord.kt) | Defines service instance/type, public v3/private v4 TXT fields, filtering and anonymous private labels. |
| [ServiceDiscoverySetup.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ServiceDiscoverySetup.kt) | Serializes native service discovery steps, bootstraps on-demand P2P and retries BUSY responses with bounded delays. |
| [PeerPresenceGate.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/PeerPresenceGate.kt) | Revalidates a selected host in Android's peer table before address-based joining. Avoids flushing that table by stopping discovery at the wrong moment. |

The Dart boundary is [offline_connectivity.dart](../packages/offline_connectivity/lib/offline_connectivity.dart).
State/capability parsing is in
[connection_state.dart](../packages/offline_connectivity/lib/src/connection_state.dart),
and invitation parsing is in
[group_invitation.dart](../packages/offline_connectivity/lib/src/group_invitation.dart).

## Native NFC and contact security files

These use the same Kotlin directory as the connectivity files above.

| File | Responsibility |
| --- | --- |
| [ContactsBridge.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactsBridge.kt) | Implements the contacts method channel, runs storage/signature work off the main thread and prevents concurrent contact/invitation NFC sessions. |
| [NfcContactsController.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/NfcContactsController.kt) | Foreground contact pairing, reader/HCE selection, ISO-DEP connection, confirmation polling, timeout and cancellation. |
| [NfcContactService.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/NfcContactService.kt) | Contact HCE service and temporary `NfcContactSession`; dispatches APDUs to the pairing protocol. |
| [ContactApdu.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactApdu.kt) | Pure Kotlin contact APDU framing: SELECT, request allocation/chunk writes, execution and response chunk reads. |
| [ContactPairing.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactPairing.kt) | Identity hello/proof/confirm state machine, transcript/code generation, local approval, receipt validation and verified transition. |
| [ContactCrypto.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactCrypto.kt) | Public key encoding, fingerprints, nonces and Nimbus ES256 JWS signing/verifying. |
| [ContactBook.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactBook.kt) | Contact records and trust transitions; signing/verifying private-channel proofs and call control; enforcing verified/unblocked peers. |
| [ContactVault.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactVault.kt) | Android Keystore aliases, encrypted contact file, atomic writes, reset and process-wide contact book. |
| [ChatHistoryBridge.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/ChatHistoryBridge.kt) | Serialized history channel, separate Keystore key, encrypted atomic file in no-backup storage and explicit reset. |
| [HistoryCipher.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/HistoryCipher.kt) | Bounded AES-GCM envelope, authenticated format version and tamper rejection. |
| [PrivateChannelCertificate.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/PrivateChannelCertificate.kt) | Generates temporary software TLS key/certificate and returns PEM plus fingerprint to Dart. |
| [NfcInvitationController.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/NfcInvitationController.kt) | Retained group invitation reader/sharer; foreground lifecycle, 60-second sharing, 30-second reading and cleanup. |
| [NfcInvitationService.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/NfcInvitationService.kt) | Invitation HCE service and process-memory `NfcInvitationStore`; unlocked/interactive checks and payload expiry. |
| [InvitationApdu.kt](../packages/offline_connectivity/android/src/main/kotlin/com/offlinegroupmessenger/offline_connectivity/InvitationApdu.kt) | Pure Kotlin invitation SELECT/READ BINARY protocol, AID, chunking, bounds and status words. |

The HCE registration is in
[the connectivity Android manifest](../packages/offline_connectivity/android/src/main/AndroidManifest.xml)
and the AID definitions are
[nfc_contact_service.xml](../packages/offline_connectivity/android/src/main/res/xml/nfc_contact_service.xml)
and [nfc_invitation_service.xml](../packages/offline_connectivity/android/src/main/res/xml/nfc_invitation_service.xml).
Change an AID consistently in its Kotlin protocol and XML registration.

## Voice and application host files

| File | Responsibility |
| --- | --- |
| [offline_audio.dart](../packages/offline_audio/lib/offline_audio.dart) | Public audio API, microphone constraints, empty ICE server configuration, peer creation and bounded media cleanup. |
| [local_audio_session.dart](../packages/offline_audio/lib/src/local_audio_session.dart) | One accepted call's media lifecycle, offer/answer, buffered ICE, deadlines, mute, speaker and teardown. |
| [p2p_candidates.dart](../packages/offline_audio/lib/src/p2p_candidates.dart) | Validates actual IPv4 subnet, accepts only eligible UDP host candidates and strips inline SDP candidates. |
| [OfflineAudioPlugin.kt](../packages/offline_audio/android/src/main/kotlin/com/offlinegroupmessenger/offline_audio/OfflineAudioPlugin.kt) | Enables WebRTC Wi-Fi Direct monitoring and exposes the audio method channel. |
| [P2pObserver.kt](../packages/offline_audio/android/src/main/kotlin/com/offlinegroupmessenger/offline_audio/P2pObserver.kt) | Reads the existing group's actual interface, local/host address and prefix. Does not create, join or remove groups. |
| [MainActivity.kt](../android/app/src/main/kotlin/com/offlinegroupmessenger/offline_group_messenger/MainActivity.kt) | Android Flutter host; background/notification channel, notification permission and username SharedPreferences. |
| [UserProfileSetup.kt](../android/app/src/main/kotlin/com/offlinegroupmessenger/offline_group_messenger/UserProfileSetup.kt) | Native display-name normalization and protocol-compatible bounds. |
| [SkyChatBackgroundService.kt](../android/app/src/main/kotlin/com/offlinegroupmessenger/offline_group_messenger/SkyChatBackgroundService.kt) | Foreground service notification and received-message notifications. Chat sockets remain in Dart. |
| [App manifest](../android/app/src/main/AndroidManifest.xml) | Application/activity declaration, camera and notification permissions, `remoteMessaging` service and backup setting. |
| [Audio manifest](../packages/offline_audio/android/src/main/AndroidManifest.xml) | Microphone/audio permissions. |
| [Swift connectivity plugin](../packages/offline_connectivity/ios/Classes/OfflineConnectivityPlugin.swift) | iPhone NFC invitations, client-only Wi-Fi association, authoritative host reachability and connection events. |
| [iPhone contact vault](../packages/offline_connectivity/ios/Classes/ContactVault.swift) | Device-only Keychain persistence, Android-compatible P-256/SPKI/JWS and private TLS proof validation. |
| [iPhone contact pairing](../packages/offline_connectivity/ios/Classes/ContactPairing.swift) | Reader-side mutual NFC proof and confirmation state across two taps. |
| [iPhone NFC reader](../packages/offline_connectivity/ios/Classes/NFCReader.swift) | Core NFC lifecycle and bounded Android-compatible ISO 7816 APDU exchanges. |

## Platform channel reference

| Channel | Type | Dart caller | Native implementation |
| --- | --- | --- | --- |
| `com.offlinegroupmessenger/connectivity` | Method | `OfflineConnectivity` | `OfflineConnectivityPlugin` |
| `com.offlinegroupmessenger/connectivity/events` | Event | `OfflineConnectivity.states` | `OfflineConnectivityPlugin` snapshots |
| `com.offlinegroupmessenger/contacts` | Method | `ContactRepository` | `ContactsBridge` |
| `com.offlinegroupmessenger/history` | Method | `AndroidChatHistoryStorage` | `ChatHistoryBridge` |
| `com.offlinegroupmessenger/audio` | Method | `readP2pNetwork` | `OfflineAudioPlugin` and `P2pObserver` |
| `com.skychat/background` | Method | `BackgroundService` and username methods | `MainActivity` |
| `com.skychat/profile` | Method | `AndroidUserProfileStore` | `MainActivity` serial background queue |

These channels connect Flutter and Kotlin inside one phone. They are not network
ports or protocols exchanged between phones. Port 45871 belongs to the chat
server; WebRTC selects eligible local UDP media ports dynamically.

## Automated coverage and device checks

| Behavior | Relevant tests |
| --- | --- |
| Native connection state, deadlines and discovery setup | [ConnectionSetupTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/ConnectionSetupTest.kt), [PeerPresenceGateTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/PeerPresenceGateTest.kt), [ServiceDiscoverySetupTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/ServiceDiscoverySetupTest.kt), [PublicGroupRecordTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/PublicGroupRecordTest.kt), [OfflineGroupCredentialsTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/OfflineGroupCredentialsTest.kt) |
| NFC contact protocol and trust | [ContactPairingTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactPairingTest.kt), [ContactBookTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/ContactBookTest.kt), [contacts_test.dart](../test/contacts_test.dart) |
| Invitation APDU and validation | [InvitationApduTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/InvitationApduTest.kt), [package invitation tests](../packages/offline_connectivity/test/group_invitation_test.dart), [package NFC tests](../packages/offline_connectivity/test/nfc_invitation_test.dart), [app NFC tests](../test/nfc_invitation_test.dart), [QR tests](../test/qr_invitation_test.dart) |
| Private TLS, proofs and approval | [PrivateChannelTest.kt](../packages/offline_connectivity/android/src/test/kotlin/com/offlinegroupmessenger/offline_connectivity/PrivateChannelTest.kt), [private_channel_test.dart](../test/private_channel_test.dart), [private_group_transport_test.dart](../test/private_group_transport_test.dart), [private_membership_panel_test.dart](../test/private_membership_panel_test.dart) |
| Chat framing, resumption and send deduplication | [tcp_message_transport_test.dart](../test/tcp_message_transport_test.dart), [session_recovery_test.dart](../test/session_recovery_test.dart), [chat_session_controller_test.dart](../test/chat_session_controller_test.dart), [connection_flow_test.dart](../test/connection_flow_test.dart) |
| Receipts and revocation | [delivery_receipts_test.dart](../test/delivery_receipts_test.dart), [private_membership_test.dart](../test/private_membership_test.dart), [private_group_test.dart](../test/private_group_test.dart) |
| Call authentication, routing, UI and cleanup | [call_controller_test.dart](../test/call_controller_test.dart), [call_routing_test.dart](../test/call_routing_test.dart), [call_screen_test.dart](../test/call_screen_test.dart), [local_audio_session_test.dart](../test/local_audio_session_test.dart) |
| Service and message notifications | [background_notifications_test.dart](../test/background_notifications_test.dart) |

For software checks, use the local Flutter SDK from the repository root:

```powershell
.\.tools\flutter\bin\flutter.bat analyze
.\.tools\flutter\bin\flutter.bat test
```

For native connectivity unit tests, run from `android/` with a configured JDK:

```powershell
.\gradlew.bat :offline_connectivity:testDebugUnitTest --console=plain
```

Socket/JVM/widget tests exercise protocol and application behavior. They do not
validate physical NFC antenna alignment, OEM Wi-Fi Direct negotiation, actual
radio capacity or background survival. Device procedures are in
[wifi-direct-testing.md](wifi-direct-testing.md), [nfc-testing.md](nfc-testing.md)
and [private-group-security.md](private-group-security.md). Use the current
Contacts UI and private admission flow described in the implementation guide
when older milestone procedures differ.

## Transport Lab and existing design documents

The separate [Transport Lab](../tools/transport_lab/README.md) has its own app
entry point, Android host and tests. Its
[BleLab.kt](../tools/transport_lab/android/app/src/main/kotlin/com/offlinegroupmessenger/offline_transport_lab/BleLab.kt)
implements BLE advertisement, scanning and GATT echo experiments.
[local_signaling.dart](../tools/transport_lab/lib/local_signaling.dart) uses port
45872 for laboratory signaling, and
[audio_lab.dart](../tools/transport_lab/lib/audio_lab.dart) provides experiment
orchestration. The shared production media adapter is in `packages/offline_audio`.

Existing documents provide deeper milestone detail:

- [architecture.md](architecture.md): layer boundaries and platform direction.
- [connectivity-contract.md](connectivity-contract.md): connectivity methods,
  snapshots and errors.
- [private-group-security.md](private-group-security.md): current private
  authentication, automatic admission and security limits.
- [chat-protocol.md](chat-protocol.md): frame semantics and recovery.
- [delivery-receipts.md](delivery-receipts.md): receipt targeting and checkmarks.
- [contact-security.md](contact-security.md): contact enrollment and key storage.
- [call-signaling.md](call-signaling.md): signed control messages and call lifecycle.
- [discovery-join-recovery.md](discovery-join-recovery.md): Android discovery/join
  behavior and device observations.
- [transport-lab.md](transport-lab.md): experiment scope and acceptance gates.
- [roadmap.md](roadmap.md): milestones and outstanding hardware checks.

Some of these retain historical sections about NFC-only private invitations,
plaintext-only chat, older deadlines or absent background services. The current
implementation guide distinguishes those earlier designs from the present code.

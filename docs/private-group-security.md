# Private group access and encrypted transport

Current implementation, 2026-11-25. This supersedes the NFC-invitation-only private
group design. Physical Android acceptance remains required.

## Joining

1. Verify contacts once through the existing mutual NFC flow, including comparison
   and confirmation on both phones. NFC exchanges public identity keys, not group
   membership. Android Keystore retains the identity private keys.
2. Create a private Wi-Fi Direct group. Android 10+ uses random SSID/password,
   2.4 GHz, and non-persistent group creation. Network joining still uses WPS PBC.
3. Discovery publishes only app/protocol/mode and a random per-group label (`sid`).
   Private records use discovery version 4 and omit username and contact fingerprint.
   Select a private group from the nearby list. Its host must be a verified contact;
   that identity is checked inside the encrypted connection, not trusted from DNS-SD.
4. The client proves its NFC contact identity. A currently verified, unblocked
   contact joins automatically after the network connection. No participant
   identity, resume token, roster, retained history, messages or call relay access
   is granted before contact authentication. There is no second chat approval.
5. Any verified contact that connects can enter unless removed from this live
   group. Clients retry or resume while their membership remains valid. Older
   hosts can still send `approval_pending`; clients show a compatibility notice.

## Transport and authentication

Private TCP connections require TLS 1.3, implemented by Dart's standard
`SecureSocket`. There is no plaintext fallback. A software P-256 TLS key and
self-signed certificate are created in memory for each hosted chat. Bouncy Castle
generates the certificate; it does not replace the TLS stack. The ephemeral key is
separate from the non-exportable Android Keystore contact identity.

Because there is no public certificate authority offline, the self-signed TLS
certificate is provisionally accepted only for an anonymous challenge exchange.
Before releasing its name, identity proof or resume credentials, the client verifies
a host ES256 JWS using an NFC-pinned contact key. The proof covers its fresh random
256-bit challenge, SHA-256 of the exact TLS certificate, role and chat group ID.
The client pins the verified host for subsequent resumes of this conversation.

The client then signs the host's independent fresh 256-bit challenge, the same
certificate fingerprint, group ID, client role and intended host identity. The host
verifies it against a currently verified, unblocked NFC contact. Proofs have a
dedicated `ogm-private-channel-v1` scope; the native verifier rejects a wrong key,
role, recipient, challenge, certificate or group. Existing call-control signatures
remain separate. Optional TLS ALPN is advertised but not used as authentication;
some Dart platforms do not expose a selected ALPN protocol.

All subsequent private frames, including admission decisions, resume tokens,
messages, receipts, roster updates and call signaling, stay inside TLS. Resume
requires a fresh contact proof and a token belonging to that same contact and
group. A token alone cannot replace the identity proof. Removing a member revokes
its resume identity and excludes its contact from this hosted group, including
fresh sessions. Starting a new hosted group resets this exclusion. A
blocked/deleted contact cannot authenticate again, including in subsequent groups.

## Boundaries

- This is authenticated encryption between each client and the host. The host
  forwards and can read group text. It is not group end-to-end encryption.
- Public groups retain their existing plaintext chat protocol and QR/NFC options.
  Public discovery records remain version 3; both phones need the updated app for
  private discovery and private TLS. Legacy private NFC invitations do not bypass
  contact authentication.
- Anonymous application advertisements do not hide Wi-Fi radio activity, device
  addresses or the existence of a nearby group. A per-group label is linkable while
  that group exists. An active device that joins the Wi-Fi network can request a
  TLS host proof, but cannot read private chat without contact authentication.
- Contact verification survives app restarts. Group exclusions, resume tokens and
  TLS keys remain in memory. A host restart ends the old conversation. Local
  encrypted history does not restore group membership; see [history](chat-history.md).
- Application membership revocation does not evict the device from Wi-Fi itself.
  Network abuse and radio availability remain separate concerns.
- The channel binding and admission protocol have automated coverage; no external
  security audit or physical-phone acceptance is claimed.

## Validation

Flutter socket tests cover automatic admission without pre-authentication data,
unknown contacts, exclusion reset for a new group, authenticated resume, missed-message replay,
member removal, blocked peers, unknown hosts, wrong-certificate proofs, plaintext
downgrade attempts and a stolen token presented by another verified contact.
Widget tests cover the absence of another host decision and older-host notices.
Native tests exercise real ES256 proofs,
context substitution, pinned identities, blocking, and ephemeral certificate/key
generation. Existing chat, delivery, NFC and calling tests remain regression checks.

The wire-observer test confirms message text, authentication frames and resume
credentials are not present as plaintext in the forwarded TLS bytes.

On two physical Android phones: pair contacts once, discover an anonymous private
group, accept the Android network invitation and verify automatic chat entry.
Check that unknown/blocked contacts receive no data, send both ways, call in both
directions, disconnect/rejoin, remove an offline member and try a fresh session.
Repeat after creating a new group. Inspect discovery on a
third unpaired phone for absence of usernames and stable contact fingerprints.

# Private group access and encrypted transport

Current implementation, 2026-11-23. This supersedes the NFC-invitation-only private
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
4. The client requests admission. The host sees its locally saved contact name and
   chooses **Approve join** or **Decline join**, on Home or Chat. No participant
   identity, resume token, roster, retained history, messages or call relay access
   is granted before approval. Pending requests expire after 60 seconds.
5. Approval applies to this contact in this live chat group. A new hosted chat
   starts with no approvals. Clients can retry or resume an approved membership
   without another host decision while that membership remains valid.

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
both its resume identity and group approval; a new admission requires another
explicit host approval. A blocked/deleted contact cannot authenticate again.

## Boundaries

- This is authenticated encryption between each client and the host. The host
  forwards and can read group text. It is not group end-to-end encryption.
- Public groups retain their existing plaintext chat protocol and QR/NFC options.
  Public discovery records remain version 3; both phones need the updated app for
  private discovery and private TLS. Legacy private NFC invitations do not bypass
  the new authentication or approval requirements.
- Anonymous application advertisements do not hide Wi-Fi radio activity, device
  addresses or the existence of a nearby group. A per-group label is linkable while
  that group exists. An active device that joins the Wi-Fi network can request a
  TLS host proof, but cannot read private chat without contact trust and approval.
- Contact verification survives app restarts. Group grants, resume tokens, TLS
  keys and chat history remain in memory. A host restart ends the old conversation.
- Application membership revocation does not evict the device from Wi-Fi itself.
  Network abuse and radio availability remain separate concerns.
- The channel binding and admission protocol have automated coverage; no external
  security audit or physical-phone acceptance is claimed.

## Validation

Flutter socket tests cover pending admission without data exposure, approval and
decline, grant reset for a new group, authenticated resume, missed-message replay,
member removal, blocked peers, unknown hosts, wrong-certificate proofs, plaintext
downgrade attempts and a stolen token presented by another approved contact.
Widget tests cover both host decisions. Native tests exercise real ES256 proofs,
context substitution, pinned identities, blocking, and ephemeral certificate/key
generation. Existing chat, delivery, NFC and calling tests remain regression checks.

Workspace verification: all 100 Flutter tests and 43 Android connectivity unit tests
passed, Flutter analysis reported no issues, and the Android debug APK built.
The wire-observer test confirms message text, authentication frames and resume
credentials are not present as plaintext in the forwarded TLS bytes.

On two physical Android phones: pair contacts once, discover an anonymous private
group, verify no messages arrive before approval, approve/decline from both host
screens, send both ways, call in both directions, disconnect/rejoin, remove an
offline member, and repeat after creating a new group. Inspect discovery on a
third unpaired phone for absence of usernames and stable contact fingerprints.

# Saved conversations on Android

Android saves local copies of chat messages, delivery-check snapshots, uncertain
outgoing messages and drafts. Open **Groups > Saved conversations** after an app
restart to read them or copy a draft. Viewing an archive never joins a network,
restores group membership or sends a message.

After explicitly joining the same running conversation, the saved draft is
restored only after the existing chat handshake succeeds and confirms its group
ID. Private archive IDs also bind that group to its authenticated host contact
identity, so another host or a public group cannot claim the private draft by
reusing the same group ID. A draft already edited in the current session takes precedence. A draft
matching an unconfirmed send carries a warning that the previous message may
already have arrived. Neither draft restoration nor loading history retries a
send. A restarted host creates a new conversation; an older draft remains in its
archive instead of being transferred to that new group.

The live session, host replay journal, participant identities, admission state,
Wi-Fi credentials, TLS keys, ordering counters and resume tokens still belong to
the running process. None of those credentials is serialized by the archive.
Private groups continue to require the existing NFC contact authentication and
host approval. This feature does not change the chat wire protocol or iOS.

## Storage and retention

- The Android bridge uses AES-256-GCM with a fresh 96-bit nonce and an
  authenticated versioned envelope. Its separate, non-exported key lives in
  Android Keystore; contact keys are untouched.
- Ciphertext is stored in `noBackupFilesDir/chat-history-v1.enc`, outside Android
  backup, using `AtomicFile`. A single worker serializes disk/Keystore operations.
  An existing archive whose key is missing is never replaced with a fresh key.
- Dart stores schema version 1 and keeps the most recently changed conversations
  first, independently of wall-clock changes or equal timestamps. Replayed
  message IDs are deduplicated; accepted messages follow host sequence order.
- Retention is at most 30 conversations, 500 confirmed messages/notices and 50
  unconfirmed outgoing entries per conversation. Conservative JSON-size accounting
  removes the oldest conversations before an 8 MiB plaintext payload budget is
  exceeded. This may evict history before the actual encoded payload reaches
  8 MiB. The native envelope adds 32 bytes.
- Saves are coalesced at roughly 300 ms intervals without waiting for traffic to
  stop. The app also requests a flush on lifecycle changes and disposal. A sudden
  process kill can lose the latest batch that has not completed its disk write.
- Failed reads and unknown formats preserve the original file and block writes.
  Recent live changes are buffered in memory (at most 4096 changes) until a
  successful retry or explicit reset. Storage problems are shown in Groups,
  saved history and the live chat. There is no plaintext fallback.
- Saved drafts are not sent automatically. Saved uncertain messages remain
  explicitly unconfirmed and are not converted into new outgoing requests.

Deleting a saved conversation removes its stored copy; deleting all saved
history also removes the separate history key. Both require confirmation and
are ordered after earlier saves. The current live chat, contacts, group access
and copies on other phones are unaffected. New messages in an active chat can
create a new archive after deletion. Failed deletion remains visible and can be
retried. App uninstall/data clearing removes local archives; there is no cloud
recovery or export in this implementation.

## Validation

Flutter tests cover restart/readback, drafts restricted to the matching group,
no implicit connection or resend, unknown/read-failed archives, retry, message
deduplication and ordering, bounded retention, continuous-traffic saves and
deletion racing a save/startup read. Widget tests exercise navigation, viewing
drafts, uncertain delivery, confirmed/cancelled deletion and failed-deletion
recovery. JVM tests check cipher round trips, fresh nonces, tampered data/nonces,
wrong keys, unsupported versions and size limits.

Physical Android acceptance is still required:

1. Chat on two phones in both public and private groups. Leave a draft, wait for
   saving, force-stop the client, then reopen and check its saved conversation.
2. Verify that reading the archive does not grant private membership or connect
   to Wi-Fi. Rejoin the same running host and check the restored draft without
   sending it. Rejoin a different/new host session and verify it is not copied.
3. Check uncertain delivery after interruption. Reopening must not resend it.
4. Delete one archive, restart and confirm it stays deleted. Repeat with all
   saved history and check that NFC contacts still work. New messages in a
   currently active chat should be saved as new local history.
5. Verify read/write failures on a device or emulator and inspect app-private
   storage to confirm that message text is absent from the encrypted file.

Implementation: `lib/core/history`, `lib/features/history`, the existing session
controller, and Android `ChatHistoryBridge`/`HistoryCipher`. The existing Android
PR workflow runs these Flutter and JVM tests and builds the debug APK.

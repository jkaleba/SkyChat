# Android first launch

A fresh Android installation opens a short welcome screen before constructing
the connection screen. Users can choose a display name or explicitly continue
as **Guest**. The screen explains direct Wi-Fi, normal "No internet" notices,
public/private group joining and the permissions requested by individual actions.
It does not request camera, microphone, nearby-device or notification access.

The name is stored in the existing private `skychat_prefs.username` preference,
shared with Contacts and Android group discovery. A valid saved nickname means
setup is already complete, so upgrading users keep their name and skip welcome.
The Guest choice is saved too. No new account, identity reset or network request
is involved; saved conversations and NFC contacts are untouched.

`com.skychat/profile` handles `load` and `complete` on an engine-owned serial
background task queue. A completion reply follows a successful preference commit.
Failed reads offer retry; failed saves keep the typed name and stay on the form.
The UI blocks duplicate submissions. The selected name reaches the chat
transport before connectivity initialization, instead of briefly using a device
model or Guest while another asynchronous preference read finishes.

Names are trimmed, must be non-empty and fit the existing protocol's 32 UTF-16
code-unit limit. Both Dart and native Android reject control characters and
multiline names. Normal Unicode names remain supported. The older background
channel's name API remains available for Contacts. Unsupported native setup
adapters fall back to the previous entry flow; actual iOS entry is unchanged.

Tests cover new and existing profiles, Guest, reload after setup, native write
acknowledgement, storage failures/retry, invalid names, duplicate submissions,
large text on a small viewport and initial transport naming. Existing group/QR
tests explicitly represent users whose setup is already complete. Android CI
runs app-module profile tests alongside the connectivity module tests under the
same required `Android build and tests` check.

Physical acceptance uses a fresh emulator/test installation for welcome and an
existing installation with a saved nickname for upgrade behavior. Verify the
name after restarting, Contacts editing, preserved history/contacts, keyboard
scrolling, and permission prompts only when the relevant action is selected.

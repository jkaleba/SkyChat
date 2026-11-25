# Android group navigation

The Groups tab starts with two actions: **Create a group** and **Join a group**.
Saved conversations remain available below those actions. The home screen does
not start discovery, open the camera or read NFC automatically.

Create opens the public/private choice. Public is still the default; choosing
Private keeps the existing verified-contact and host-approval requirements.
The choices wrap on narrow screens and with large text. Connection permissions
are requested by Android when the user starts the relevant operation.

Join opens a separate, live page with nearby search and the invitation methods
supported by the phone. QR requires QR joining support; NFC requires NFC reading
and invitation joining support. Opening the page alone starts none of them.
Search results and a remembered private group's Rejoin action appear here.
The remembered entry still checks availability when joining; it does not claim
the host is nearby. Group QR and NFC invitations still require confirmation
before joining. The Contacts tab remains the place to verify private contacts.

The join page follows connection updates. Starting a connection hides other join
methods. A connected group offers **Open chat**, host invitation sharing and
disconnect controls. Home prioritizes the current chat and hides new create/join
actions while connecting, connected or disconnecting. After disconnect, the last
conversation remains accessible and the create/join choices return.

Host IP is available under **Connection details** on Android. Expanding it does
not reveal Wi-Fi passwords or invitation tokens. Public QR codes retain their
explicit show/hide controls and disappear on disconnect, including when a late
native response arrives. Host teardown still requires confirmation.

Connection status, host sharing, saved conversations, recent chat and nearby
results use shared builders across the relevant screens. Native Android
discovery, connection, encryption and admission code is unchanged. A synchronous
operation guard ignores a second tap while a native request is pending and
still allows cancellation before the native reply arrives. The
existing iOS prototype entry flow remains available.

Widget tests cover idle navigation, capability gating, explicit search/stop,
connection cancellation, duplicate joining, NFC confirmation, current chat,
expanded technical details and a narrow screen with 200% text and rotation.
The group, QR, remembered-private-group and iOS regression tests use the new
Android navigation where applicable.

On physical phones, verify public discovery and QR joining, verified private
joining and approval, rejoining after leaving, host disconnect confirmation,
saved-conversation access, and back navigation while searching and connected.
Repeat with large text and the keyboard/system permission dialogs open.

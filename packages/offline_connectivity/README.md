# Offline Connectivity

Private Flutter plugin used by the app in this repository. Kotlin implements
Wi-Fi Direct permissions, create/discover/join/disconnect, state events, and
foreground NFC invitation sharing (HCE) / reading (ISO-DEP). NFC is optional;
devices without it can still use QR or nearby discovery for public groups.
Private groups require NFC-verified contacts, advertise anonymous group labels,
and require host approval inside authenticated TLS. Public discovery filters out generic Wi-Fi peers. Network and admission
credentials are never included in discovery records or state events.
Swift implements an iPhone reader/client prototype: two-tap NFC contact pairing,
device-only Keychain identities and NFC invitation joining through ordinary
Wi-Fi. The additional `startIosNfcSharing` host action supplies the real GO address;
private version-3 invitations convey no membership token. Existing Android
discovery, P2P joining and version-1/2 invitation paths remain unchanged.
Messaging is implemented separately in the shared Dart TCP layer. See
[iPhone setup and outstanding hardware checks](../../docs/ios-prototype.md).

See ../../docs/connectivity-contract.md for the shared channel contract.

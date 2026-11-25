# iPhone client prototype

The iPhone prototype joins an existing Android-hosted group. Flutter screens,
chat messages, delivery receipts and private TLS use the shared Dart code. It
does not host groups, implement Android Wi-Fi Direct discovery, make voice calls,
or promise background message delivery. Keep SkyChat open on both phones.

Source implementation and automated Flutter/Android checks are separate from
iOS compilation and physical-device acceptance. This Windows workspace cannot
run Xcode. Run the native protocol tests on a Mac using Xcode and Simulator.
Simulator tests cannot establish NFC/radio interoperability.

## Build on a Mac

1. Use Flutter 3.35.7, Xcode, CocoaPods, and an iPhone with iOS 15 or newer and NFC
   ISO 7816 tag-reading support. Use a physical Android phone supporting NFC HCE
   and Wi-Fi Direct. Install this build on Android as well: older invitations do
   not contain the actual host IP required by iPhone.
2. Run `flutter pub get`, then `cd ios && pod install`, and open
   `ios/Runner.xcworkspace` in Xcode.
3. Select your development team and a registered bundle identifier. Enable
   **Near Field Communication Tag Reading** and **Hotspot Configuration** for
   the Runner App ID and provisioning profile. `Runner.entitlements` already
   declares TAG reading and Hotspot Configuration. No HCE/card-emulation
   entitlement or Wi-Fi Aware capability is used on iPhone.
4. Build with `flutter build ios --debug` or run on the connected iPhone using
   `flutter run`. For compilation without device provisioning, use
   `flutter build ios --simulator --debug`. Run RunnerTests in Xcode to check
   P-256/JWS, transcript encoding, mutual confirmation and TLS proof binding.

## Pair contacts by NFC

1. Keep both apps open, phones unlocked, and NFC enabled on Android.
2. Android: **Contacts → Share contact**. iPhone: **Contacts → Add contact**.
3. Hold the top of iPhone near Android's NFC antenna until the system NFC sheet
   closes. The first tap exchanges identities and proves possession of both
   private keys. It saves a pending contact, not a verified contact.
4. Separate the phones and compare the complete displayed verification code.
   Confirm only if it matches on both phones. Confirm on Android first, then on
   iPhone. The iPhone confirmation opens a second NFC scan.
5. Tap the same phones again and keep them together until confirmation completes.
   Both screens must show the verified/saved state. Finish within the Android
   session's existing 60-second limit; otherwise restart on both phones.

iPhone is always the reader, Android always the HCE sharer. iPhone cannot expose
the Flutter confirmation button while the system NFC sheet is covering it, hence
the second tap. This uses the existing Android proof/confirmation protocol;
selecting the NFC application again does not reset Android's pairing approval.
Core NFC's optional SELECT Le=00 byte is accepted by both Android APDU handlers.

iPhone stores its P-256 software identity and contacts in device-only Keychain
storage, accessible while unlocked. It does not claim a non-exportable Secure
Enclave key. A Keychain access/corruption error fails closed; only an explicit
contact reset replaces identity. Blocking/deleting/resetting contacts retains
the existing trust semantics. Reinstall behavior must be tested because iOS
Keychain items can survive app removal.

## Join the chat by NFC

1. Android: create a **Private** group and keep its host open.
2. Android: choose **Invite iPhone by NFC**. Sharing expires after 60 seconds and
   stops on navigation away, backgrounding, or group loss.
3. iPhone: **Groups → Join group by NFC**, then tap Android again.
4. Confirm the group invitation in SkyChat and accept iOS's Wi-Fi join prompt.
   Allow **Local Network** access. The iPhone joins Android's group as an ordinary
   Wi-Fi client, not as an Android Wi-Fi Direct peer.
5. SkyChat probes the actual invited host on TCP port 45871 through Wi-Fi before
   reporting network connection. It does not guess `192.168.49.1`, scan subnets,
   or fall back to internet/mobile data to discover a host.
6. The shared private TLS handshake verifies the host's NFC-pinned identity,
   certificate-bound challenge, group ID and then the client's proof. Android's
   host must choose **Approve join** before messages, roster, or history arrive.
7. Send text both ways and check receipts. Network association alone is not chat
   admission. A public group may also be invited, retaining its existing public
   plaintext chat semantics.

The new `startIosNfcSharing` action is separate from Android's existing NFC and
QR invitation methods. It adds the real GO `hostAddress`; private invitations use
version 3 with no admission token. Wi-Fi credentials do not grant private group
membership. Android's existing discovery, creation, joining, contact proof,
TLS and host approval paths remain in place. Version 3 is an iPhone prototype
invitation, not a replacement for Android's existing version 1/2 invitation flow.

## Physical acceptance still required

- Check iPhone NFC access with the provisioned App ID; missing capability/profile
  is a configuration failure, not proof that peer NFC is unsupported.
- Run both taps with Unicode names and check identical comparison codes. Reject
  a code, cancel either scan, let it expire, interrupt a tap, and retry. A pending
  contact must never authenticate a private chat. Repeat after restarting apps.
- Test whether each Android group owner accepts iPhone as a legacy Wi-Fi client.
  This is the main hardware gate: source code cannot guarantee OEM behavior.
- Disable mobile data and disconnect any router. Verify NFC invitation, iOS Wi-Fi
  association, host approval, text both ways and receipts without internet.
- Deny Local Network/Wi-Fi permission, cancel joining, disconnect during joining,
  end the host group, and move out of range. No false chat-ready state is allowed.
- Decline admission; block/delete a contact; remove an offline member; retry after
  creating a new group. Capture traffic to verify private frames stay encrypted.
- Background/lock iPhone and return. `joinOnce` may drop its Wi-Fi association;
  rejoin explicitly by NFC as needed. No always-on offline receiving is promised.
- Confirm existing Android↔Android pairing, discovery, QR, private admission and
  calls still work. The prototype does not validate those radios through mocks.

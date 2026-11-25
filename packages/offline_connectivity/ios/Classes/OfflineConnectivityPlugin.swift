import CoreNFC
import Flutter
import Network
import NetworkExtension
import UIKit

public class OfflineConnectivityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let nfc = NFCReader()
    private var vault: ContactVault?
    private var pairing: ContactPairing?
    private var pairingExpiry: DispatchWorkItem?
    private var sink: FlutterEventSink?
    private var status = "idle"
    private var host: String?
    private var privateGroup = false
    private var configuredSSID: String?
    private var generation = 0
    private var pendingJoin: FlutterResult?
    private var probe: NWConnection?
    private var joinTimeout: DispatchWorkItem?
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = OfflineConnectivityPlugin()
        registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(
            name: "com.offlinegroupmessenger/connectivity", binaryMessenger: registrar.messenger()))
        FlutterMethodChannel(name: "com.offlinegroupmessenger/contacts", binaryMessenger: registrar.messenger())
            .setMethodCallHandler { [weak instance] call, result in instance?.contacts(call, result: result) }
        // iOS only shares username preferences with this Android channel.
        // It does not emulate an Android foreground service.
        FlutterMethodChannel(name: "com.skychat/background", binaryMessenger: registrar.messenger())
            .setMethodCallHandler { call, result in
                if call.method == "getUsername" { result(UserDefaults.standard.string(forKey: "skychat.username") ?? UIDevice.current.name) }
                else if call.method == "setUsername", let args = call.arguments as? [String: Any], let name = args["name"] as? String {
                    do { UserDefaults.standard.set(try ContactWire.name(name), forKey: "skychat.username"); result(nil) }
                    catch { result(FlutterError(code: "invalid_name", message: error.localizedDescription, details: nil)) }
                } else { result(FlutterMethodNotImplemented) }
            }
        FlutterEventChannel(name: "com.offlinegroupmessenger/connectivity/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
        instance.pathMonitor.pathUpdateHandler = { [weak instance] path in
            guard let instance = instance, instance.status == "connected", path.status != .satisfied else { return }
            instance.disconnect()
        }
        instance.pathMonitor.start(queue: .main)
    }
    deinit { pathMonitor.cancel(); probe?.cancel(); joinTimeout?.cancel(); pairingExpiry?.cancel() }
    private func contactsVault() throws -> ContactVault {
        if let vault = vault { return vault }
        let opened = try ContactVault(); vault = opened; return opened
    }
    private func snapshot() -> [String: Any] {
        var state: [String: Any] = ["status": status, "wifiEnabled": pathMonitor.currentPath.status == .satisfied, "permissionGranted": status == "connected",
                                   "isHost": false, "privateGroup": privateGroup, "peers": []]
        if let host = host { state["hostAddress"] = host }
        return state
    }
    private func emit() { sink?(snapshot()) }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; emit(); return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getCapabilities":
            result(["platform": "ios", "wifiDirectSupported": false, "implementationReady": true,
                    "canJoinQr": false, "canJoinNfc": NFCTagReaderSession.readingAvailable, "canShareNfc": false,
                    "description": "Join an Android-hosted group by NFC. Keep SkyChat open while chatting."])
        case "getState": result(snapshot())
        case "disconnect": disconnect(); result(nil)
        case "stopNfc": nfc.cancel(); result(nil)
        case "readNfcInvitation": readInvitation(result)
        case "joinInvitation":
            do {
                guard let args = call.arguments as? [String: Any] else { throw SkyChatError.invalid("Missing invitation.") }
                let invitation = try IOSGroupInvitation(args)
                if invitation.privateGroup { try require(try contactsVault().records.values.contains { $0.state == "verified" }, "Add the host to Contacts by NFC first.") }
                try join(invitation, result: result)
            } catch { result(FlutterError(code: "join_failed", message: error.localizedDescription, details: nil)) }
        default:
            result(FlutterError(code: "unsupported", message: "This iPhone prototype joins Android groups by NFC; hosting, nearby discovery and calls are not available.", details: nil))
        }
    }
    private func readInvitation(_ result: @escaping FlutterResult) {
        guard status == "idle" else { result(FlutterError(code: "busy", message: "Disconnect before reading another group.", details: nil)); return }
        stopPairing()
        var payload: String?
        do {
            try nfc.start(message: "Ask Android to open Invite iPhone by NFC, then hold this iPhone near it.", operation: { [weak self] tag in
                guard let self = self else { return }
                let header = try await self.nfc.send(NFCReader.invitationSelect, to: tag)
                let bytes = try await self.nfc.readPayload(header: header, maximum: 2048, tag: tag)
                _ = try IOSGroupInvitation(ContactWire.object(bytes))
                guard let text = String(data: bytes, encoding: .utf8) else { throw SkyChatError.invalid("Invalid invitation.") }
                payload = text
            }, completion: { error in
                if let error = error { result(FlutterError(code: "nfc_failed", message: error.localizedDescription, details: nil)) }
                else { result(payload) }
            })
        } catch { result(FlutterError(code: "nfc_unavailable", message: error.localizedDescription, details: nil)) }
    }
    private func contacts(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "snapshot": result(try contactsVault().snapshot())
            case "pairingStart":
                try require(args["reader"] as? Bool == true, "On Android choose Share contact; on iPhone choose Add contact.")
                stopPairing()
                let created = try ContactPairing(vault: contactsVault(), name: args["name"] as? String ?? "")
                pairing = created
                let expiry = DispatchWorkItem { [weak self, weak created] in
                    guard let self = self, let created = created, self.pairing === created else { return }
                    if created.status["state"] as? String != "verified" {
                        created.stop("Pairing expired. Start again on both phones."); self.nfc.cancel()
                    }
                }
                pairingExpiry = expiry; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: expiry)
                try scanContact(created, confirmation: false)
                result(nil)
            case "pairingStatus": result(pairing?.status)
            case "pairingApprove":
                guard let pairing = pairing else { throw SkyChatError.invalid("Read the contact first.") }
                try pairing.approve(); try scanContact(pairing, confirmation: true); result(nil)
            case "pairingStop": stopPairing(); result(nil)
            case "rename", "block", "delete":
                if call.method != "rename" { stopPairing() }
                guard let id = args["id"] as? String else { throw SkyChatError.invalid("Missing contact.") }
                try contactsVault().change(id, action: call.method, name: args["name"] as? String); result(nil)
            case "reset": stopPairing(); try ContactVault.reset(); vault = nil; result(nil)
            case "signPrivateChannel":
                guard let body = args["body"] as? [String: Any] else { throw SkyChatError.invalid("Missing proof context.") }
                result(try contactsVault().signPrivateChannel(body))
            case "verifyPrivateChannel":
                guard let token = args["token"] as? String, let expected = args["expected"] as? [String: Any] else { throw SkyChatError.invalid("Missing host proof.") }
                result(try contactsVault().verifyPrivateChannel(token, expected: expected))
            default: result(FlutterMethodNotImplemented)
            }
        } catch {
            if call.method == "pairingStart" || call.method == "pairingApprove" {
                pairing?.stop(error.localizedDescription)
            }
            result(FlutterError(code: "contacts_unavailable", message: error.localizedDescription, details: nil))
        }
    }
    private func stopPairing() {
        pairingExpiry?.cancel(); pairingExpiry = nil
        pairing?.stop(); nfc.cancel()
    }
    private func scanContact(_ contact: ContactPairing, confirmation: Bool) throws {
        try nfc.start(message: confirmation ? "Confirm the code on Android too, then tap the same phone again to save the contact." :
            "On Android open Contacts → Share contact, then hold this iPhone near it.", operation: { [weak self, weak contact] tag in
                guard let self = self, let contact = contact else { return }
                try contact.checkActive()
                _ = try await self.nfc.send(NFCReader.contactSelect, to: tag)
                if !confirmation {
                    let hello = try contact.hello()
                    let host = try await self.nfc.exchange(hello, tag: tag)
                    let proof = try contact.receiveHostProof(host)
                    let ready = try await self.nfc.exchange(proof, tag: tag)
                    try require(ready["type"] as? String == "ready")
                } else {
                    while true {
                        let poll = try contact.poll()
                        let reply = try await self.nfc.exchange(poll, tag: tag)
                        if try contact.receiveConfirmation(reply) { break }
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }, completion: { [weak self, weak contact] error in
                guard let contact = contact, self?.pairing === contact else { return }
                if let error = error { contact.stop(error.localizedDescription) }
            })
    }
    private func join(_ invitation: IOSGroupInvitation, result: @escaping FlutterResult) throws {
        try require(status == "idle", "Disconnect before joining another group.")
        nfc.cancel(); generation += 1
        let token = generation
        pendingJoin = result; configuredSSID = invitation.ssid
        status = "connecting"; privateGroup = invitation.privateGroup; host = nil; emit()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, self.pendingJoin != nil else { return }
            self.failJoin("Connection timed out. Keep the Android host open, allow Local Network access and retry.")
        }
        joinTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        let config = NEHotspotConfiguration(ssid: invitation.ssid, passphrase: invitation.passphrase, isWEP: false)
        config.joinOnce = true
        NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.generation == token, self.pendingJoin != nil else {
                    // An old system prompt may complete after cancellation.
                    // Clean it up without removing a newer join to the same SSID.
                    if self.configuredSSID != invitation.ssid {
                        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: invitation.ssid)
                    }
                    return
                }
                if let error = error as NSError?, !(error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                    self.failJoin("Could not join Android Wi-Fi. Accept the system prompt and keep both phones nearby."); return
                }
                // Use the actual Android GO address and only the Wi-Fi interface.
                let parameters = NWParameters.tcp; parameters.requiredInterfaceType = .wifi
                let probe = NWConnection(host: NWEndpoint.Host(invitation.host), port: 45871, using: parameters)
                self.probe = probe
                probe.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.generation == token, self.pendingJoin != nil else { return }
                    switch state {
                    case .ready:
                        self.joinTimeout?.cancel(); self.joinTimeout = nil
                        let completion = self.pendingJoin; self.pendingJoin = nil
                        self.probe = nil; probe.cancel()
                        self.host = invitation.host; self.status = "connected"; self.emit(); completion?(nil)
                    case .failed:
                        self.failJoin("Joined Wi-Fi but cannot reach SkyChat. Keep the Android group open and allow Local Network access.")
                    default: break
                    }
                }
                probe.start(queue: .main)
            }
        }
    }
    private func failJoin(_ message: String) {
        let completion = pendingJoin; pendingJoin = nil
        disconnect(); completion?(FlutterError(code: "join_failed", message: message, details: nil))
    }
    private func disconnect() {
        generation += 1
        joinTimeout?.cancel(); joinTimeout = nil; probe?.cancel(); probe = nil
        let completion = pendingJoin; pendingJoin = nil
        if let ssid = configuredSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
        configuredSSID = nil; host = nil; status = "idle"; privateGroup = false; emit()
        completion?(FlutterError(code: "cancelled", message: "Connection cancelled.", details: nil))
    }
    public func applicationDidEnterBackground(_ application: UIApplication) {
        stopPairing()
        if status == "connecting" { disconnect() }
    }
}

struct IOSGroupInvitation {
    let ssid: String
    let passphrase: String
    let host: String
    let privateGroup: Bool
    init(_ map: [String: Any]) throws {
        privateGroup = map["privateGroup"] as? Bool == true
        guard let name = map["networkName"] as? String, let password = map["passphrase"] as? String,
              let host = map["hostAddress"] as? String else {
            throw SkyChatError.invalid("This invitation has no host address. Update SkyChat on Android and share it again.")
        }
        try require(map["app"] as? String == "offline-group-messenger" && map["transport"] as? String == "wifi-direct" &&
            map["version"] as? Int == (privateGroup ? 3 : 1))
        try require(name.range(of: "^DIRECT-[a-zA-Z0-9]{2}", options: .regularExpression) != nil && name.utf8.count <= 32 &&
            !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
        try require((8...63).contains(password.utf8.count) && password.unicodeScalars.allSatisfy { (32...126).contains($0.value) })
        try require(map["admissionToken"] == nil)
        // No guessed gateway, hostnames, public IPs, loopback or multicast.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        try require(parts.count == 4 && octets.count == 4 && zip(parts, octets).allSatisfy { String($0.0) == String($0.1) })
        try require(octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254))
        ssid = name; passphrase = password; self.host = host
    }
}

import CryptoKit
import Foundation
import Security

enum SkyChatError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

func require(_ condition: Bool, _ message: String = "Contact verification failed.") throws {
    if !condition { throw SkyChatError.invalid(message) }
}

enum ContactWire {
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkyChatError.invalid("Invalid contact message.")
        }
        return value
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) throws -> Data {
        try require(!text.isEmpty && text.utf8.count <= 32_000 &&
            text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == text else {
            throw SkyChatError.invalid("Invalid contact encoding.")
        }
        return data
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func publicKey(_ key: String) throws -> P256.Signing.PublicKey {
        let bytes = try decode(key)
        let result = try P256.Signing.PublicKey(derRepresentation: bytes)
        try require(result.derRepresentation == bytes)
        return result
    }
    static func fingerprint(_ key: String) throws -> String {
        hash(try publicKey(key).derRepresentation)
    }
    static func name(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try require((1...32).contains(result.utf16.count) &&
            !result.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }, "Use a name of 1–32 characters.")
        return result
    }
    static func hex(_ value: Any?, count: Int) -> Bool {
        guard let value = value as? String else { return false }
        return value.count == count && value.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil
    }
    static func randomNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        try require(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return encode(Data(bytes))
    }
    static func verify(_ token: String, key: String) throws -> [String: Any] {
        try require(token.utf8.count <= 24_000)
        let parts = token.components(separatedBy: ".")
        try require(parts.count == 3)
        let header = try object(decode(parts[0]))
        try require(Set(header.keys) == ["alg", "typ"] && header["alg"] as? String == "ES256" &&
            header["typ"] as? String == "ogm-contact-v1")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        try require(try publicKey(key).isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        return try object(decode(parts[1]))
    }
}

struct ContactRecord: Codable {
    let id: String
    let key: String
    var name: String
    var state: String
    var transcript: String?
    var approved: Bool?

    var map: [String: Any] { ["id": id, "key": key, "name": name, "state": state] }
}

/// Device-only Keychain storage. Prototype keys are P-256 software keys protected
/// by Keychain, not advertised as non-exportable Secure Enclave identities.
final class ContactVault {
    private struct Stored: Codable {
        let version: Int
        let privateKey: Data
        let contacts: [String: ContactRecord]
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SkyChat") + ".contacts",
         kSecAttrAccount as String: "identity-v1"]
    }
    private let privateKey: P256.Signing.PrivateKey
    private let inMemory: Bool
    private(set) var records: [String: ContactRecord]
    var key: String { ContactWire.encode(privateKey.publicKey.derRepresentation) }
    var id: String { ContactWire.hash(privateKey.publicKey.derRepresentation) }

    init() throws {
        inMemory = false
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            privateKey = P256.Signing.PrivateKey()
            records = [:]
            try persist(records)
        } else {
            try require(status == errSecSuccess, "Unlock this iPhone to access contacts.")
            guard let data = item as? Data else { throw SkyChatError.invalid("Contact storage is unavailable.") }
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            try require(stored.version == 1 && stored.contacts.count <= 256)
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: stored.privateKey)
            records = stored.contacts
            for (id, entry) in records {
                try require(id == entry.id && id != self.id && id == ContactWire.fingerprint(entry.key))
                try require(["pending", "verified", "blocked"].contains(entry.state))
                try require(try ContactWire.name(entry.name) == entry.name)
            }
        }
    }
    /// Isolated protocol tests never read, replace or delete a user's Keychain.
    init(ephemeralKey: P256.Signing.PrivateKey) {
        privateKey = ephemeralKey; records = [:]; inMemory = true
    }
    static func reset() throws {
        let status = SecItemDelete(query as CFDictionary)
        try require(status == errSecSuccess || status == errSecItemNotFound)
    }
    private func persist(_ next: [String: ContactRecord]) throws {
        try require(next.count <= 256, "Contact limit reached.")
        if inMemory { return }
        let data = try JSONEncoder().encode(Stored(version: 1, privateKey: privateKey.rawRepresentation, contacts: next))
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess, "Cannot save contacts securely.")
        } else { try require(status == errSecSuccess, "Cannot save contacts securely.") }
    }
    private func update(_ entry: ContactRecord?, id: String) throws {
        var next = records
        next[id] = entry
        try persist(next)
        records = next
    }
    func snapshot() -> [String: Any] {
        ["identity": id, "contacts": records.values.sorted { $0.id < $1.id }.map { $0.map }]
    }
    func pending(key: String, name: String, transcript: String) throws {
        let peer = try ContactWire.fingerprint(key)
        try require(peer != id && ContactWire.hex(transcript, count: 64) && records[peer]?.state != "blocked")
        if records[peer]?.state == "verified" { return }
        try update(ContactRecord(id: peer, key: key, name: ContactWire.name(name), state: "pending",
                                 transcript: transcript, approved: false), id: peer)
    }
    func approve(_ id: String, transcript: String) throws {
        guard var entry = records[id] else { throw SkyChatError.invalid("Unknown contact.") }
        try require(entry.state != "blocked")
        if entry.state == "verified" { return }
        try require(entry.transcript == transcript)
        entry.approved = true
        try update(entry, id: id)
    }
    func verified(_ id: String, transcript: String) throws {
        guard var entry = records[id] else { throw SkyChatError.invalid("Unknown contact.") }
        try require(entry.state != "blocked")
        if entry.state == "verified" { return }
        try require(entry.transcript == transcript && entry.approved == true)
        entry.state = "verified"; entry.transcript = nil; entry.approved = nil
        try update(entry, id: id)
    }
    func change(_ id: String, action: String, name: String? = nil) throws {
        guard var entry = records[id] else { throw SkyChatError.invalid("Unknown contact.") }
        if action == "delete" { try update(nil, id: id); return }
        if action == "rename" { entry.name = try ContactWire.name(name ?? "") }
        else if action == "block" { entry.state = "blocked"; entry.transcript = nil; entry.approved = nil }
        else { throw SkyChatError.invalid("Unsupported contact action.") }
        try update(entry, id: id)
    }
    func sign(_ body: [String: Any]) throws -> String {
        let header = ContactWire.encode(try ContactWire.json(["alg": "ES256", "typ": "ogm-contact-v1"]))
        let data = try ContactWire.json(body)
        try require(data.count <= 18_000)
        let input = header + "." + ContactWire.encode(data)
        let signature = try privateKey.signature(for: Data(input.utf8))
        return input + "." + ContactWire.encode(signature.rawRepresentation)
    }
    func signPrivateChannel(_ body: [String: Any]) throws -> String {
        // iPhone is a client only; it cannot claim the host role in this prototype.
        guard let to = body["to"] as? String else { throw SkyChatError.invalid("Missing host identity.") }
        try require(body["role"] as? String == "client" && records[to]?.state == "verified")
        try require(ContactWire.hex(body["nonce"], count: 64) && ContactWire.hex(body["certificate"], count: 64) &&
            ContactWire.hex(body["group"], count: 32))
        return try sign(["scope": "ogm-private-channel-v1", "from": id, "to": to,
                         "role": "client", "nonce": body["nonce"]!,
                         "certificate": body["certificate"]!, "group": body["group"]!])
    }
    func verifyPrivateChannel(_ token: String, expected: [String: Any]) throws -> String {
        let parts = token.components(separatedBy: ".")
        try require(token.utf8.count <= 24_000 && parts.count == 3)
        let untrusted = try ContactWire.object(ContactWire.decode(parts[1]))
        guard let from = untrusted["from"] as? String, let contact = records[from], contact.state == "verified" else {
            throw SkyChatError.invalid("Verify the host contact by NFC first.")
        }
        let payload = try ContactWire.verify(token, key: contact.key)
        try require(Set(payload.keys) == ["scope", "from", "to", "role", "nonce", "certificate", "group"])
        try require(payload["scope"] as? String == "ogm-private-channel-v1" && payload["from"] as? String == from &&
            payload["role"] as? String == "host" && payload["to"] as? String == "")
        for field in ["role", "nonce", "certificate", "group"] {
            try require(payload[field] as? String != nil && payload[field] as? String == expected[field] as? String)
        }
        if let pinned = expected["from"] as? String { try require(pinned == from) }
        return from
    }
}

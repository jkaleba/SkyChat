import Foundation

/// Reader half of the existing Android protocol. NFC proximity never grants trust
/// without proof of possession, matching comparison codes and both approvals.
final class ContactPairing {
    private let vault: ContactVault
    private let local: [String: String]
    private var remote: [String: String]?
    private var transcript: String?
    private var proven = false
    private var approved = false
    private var complete = false
    private var stopped = false
    private var problem: String?
    let deadline = ProcessInfo.processInfo.systemUptime + 60

    init(vault: ContactVault, name: String) throws {
        self.vault = vault
        local = ["key": vault.key, "name": try ContactWire.name(name), "nonce": try ContactWire.randomNonce()]
    }
    var status: [String: Any] {
        var result: [String: Any] = ["state": complete ? "verified" : stopped ? "stopped" : proven ? "confirm" : "waiting",
                                     "approved": approved, "requiresRetap": true]
        if let name = remote?["name"] { result["name"] = name }
        if let transcript = transcript {
            let code = Array(transcript.prefix(32))
            result["code"] = stride(from: 0, to: code.count, by: 4).map { String(code[$0..<$0 + 4]) }.joined(separator: " ")
        }
        if let problem = problem { result["error"] = problem }
        return result
    }
    func checkActive() throws {
        try require(!stopped && ProcessInfo.processInfo.systemUptime < deadline, "Pairing expired. Start again on both phones.")
    }
    func stop(_ reason: String? = nil) {
        if complete { return }
        stopped = true; problem = reason
    }
    func hello() throws -> [String: Any] {
        try checkActive()
        return ["type": "hello", "identity": local]
    }
    func receiveHostProof(_ message: [String: Any]) throws -> [String: Any] {
        try checkActive()
        guard let peer = message["identity"] as? [String: String], let token = message["proof"] as? String else {
            throw SkyChatError.invalid("Invalid NFC identity proof.")
        }
        try require(message["type"] as? String == "proof" && Set(peer.keys) == ["key", "name", "nonce"])
        try require(try ContactWire.decode(peer["nonce"]!).count == 32)
        try require(try ContactWire.name(peer["name"]!) == peer["name"]!)
        let id = try ContactWire.fingerprint(peer["key"]!)
        try require(id != vault.id && vault.records[id]?.state != "blocked")
        try require(remote == nil || remote == peer)
        remote = peer
        let fields = ["ogm-nfc-contact-v1", local["key"]!, local["name"]!, local["nonce"]!,
                      peer["key"]!, peer["name"]!, peer["nonce"]!]
        transcript = ContactWire.hash(try ContactWire.json(["fields": fields]))
        try verify(token, kind: "proof")
        try vault.pending(key: peer["key"]!, name: peer["name"]!, transcript: transcript!)
        proven = true
        return ["type": "proof", "proof": try sign("proof")]
    }
    private func sign(_ kind: String) throws -> String {
        guard let transcript = transcript else { throw SkyChatError.invalid("Missing NFC proof.") }
        return try vault.sign(["kind": kind, "transcript": transcript, "role": "reader"])
    }
    private func verify(_ token: String, kind: String) throws {
        let payload = try ContactWire.verify(token, key: remote!["key"]!)
        try require(NSDictionary(dictionary: payload).isEqual(to: ["kind": kind, "transcript": transcript!, "role": "host"]))
    }
    func approve() throws {
        try checkActive()
        try require(proven)
        guard let remote = remote, let transcript = transcript else { throw SkyChatError.invalid("Read the contact first.") }
        try vault.approve(ContactWire.fingerprint(remote["key"]!), transcript: transcript)
        approved = true
    }
    func poll() throws -> [String: Any] {
        try checkActive()
        try require(proven)
        return ["type": "confirm", "receipt": approved ? try sign("confirm") as Any : NSNull()]
    }
    func receiveConfirmation(_ message: [String: Any]) throws -> Bool {
        try checkActive()
        try require(approved && message["type"] as? String == "confirm")
        if let receipt = message["receipt"] as? String {
            try verify(receipt, kind: "confirm")
            try vault.verified(ContactWire.fingerprint(remote!["key"]!), transcript: transcript!)
            complete = true
        }
        return complete
    }
}

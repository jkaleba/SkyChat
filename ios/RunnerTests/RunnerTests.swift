import CryptoKit
import XCTest
@testable import offline_connectivity

class RunnerTests: XCTestCase {

  private func firstTap() throws -> (ContactVault, ContactVault, ContactPairing, String, [String: Any]) {
    let reader = ContactVault(ephemeralKey: P256.Signing.PrivateKey())
    let host = ContactVault(ephemeralKey: P256.Signing.PrivateKey())
    let pairing = try ContactPairing(vault: reader, name: "iPhone")
    let local = try pairing.hello()["identity"] as! [String: String]
    let identity = ["key": host.key, "name": "Android", "nonce": try ContactWire.randomNonce()]
    // The fixed array order is the Android ContactPairing wire contract.
    let fields = ["ogm-nfc-contact-v1", local["key"]!, local["name"]!, local["nonce"]!,
                  identity["key"]!, identity["name"]!, identity["nonce"]!]
    let transcript = ContactWire.hash(try ContactWire.json(["fields": fields]))
    let hostProof: [String: Any] = ["type": "proof", "identity": identity,
      "proof": try host.sign(["kind": "proof", "transcript": transcript, "role": "host"])]
    let readerProof = try pairing.receiveHostProof(hostProof)
    let proof = try ContactWire.verify(readerProof["proof"] as! String, key: reader.key)
    XCTAssertEqual(proof["transcript"] as? String, transcript)
    XCTAssertEqual(proof["role"] as? String, "reader")
    try host.pending(key: reader.key, name: "iPhone", transcript: transcript)
    return (reader, host, pairing, transcript, hostProof)
  }

  private func completePair() throws -> (ContactVault, ContactVault) {
    let (reader, host, pairing, transcript, _) = try firstTap()
    try pairing.approve()
    try host.approve(reader.id, transcript: transcript)
    let poll = try pairing.poll()
    let receipt = try ContactWire.verify(poll["receipt"] as! String, key: reader.key)
    XCTAssertEqual(receipt["kind"] as? String, "confirm")
    try host.verified(reader.id, transcript: transcript)
    XCTAssertTrue(try pairing.receiveConfirmation(["type": "confirm", "receipt":
      host.sign(["kind": "confirm", "transcript": transcript, "role": "host"])]))
    return (reader, host)
  }

  func testFirstTapAndOneApprovalNeverCreateAVerifiedContact() throws {
    let (reader, host, pairing, transcript, _) = try firstTap()
    XCTAssertEqual(reader.records[host.id]?.state, "pending")
    try pairing.approve()
    XCTAssertEqual(reader.records[host.id]?.state, "pending")
    XCTAssertFalse(try pairing.receiveConfirmation(["type": "confirm", "receipt": NSNull()]))
    let attacker = ContactVault(ephemeralKey: P256.Signing.PrivateKey())
    let forged = try attacker.sign(["kind": "confirm", "transcript": transcript, "role": "host"])
    XCTAssertThrowsError(try pairing.receiveConfirmation(["type": "confirm", "receipt": forged]))
    XCTAssertEqual(reader.records[host.id]?.state, "pending")
    let (verifiedReader, verifiedHost) = try completePair()
    XCTAssertEqual(verifiedReader.records[verifiedHost.id]?.state, "verified")
    XCTAssertEqual(verifiedHost.records[verifiedReader.id]?.state, "verified")
  }

  func testProofFromAnOldTapCannotAuthenticateANewPairing() throws {
    let (reader, _, _, _, oldProof) = try firstTap()
    let next = try ContactPairing(vault: reader, name: "iPhone")
    XCTAssertThrowsError(try next.receiveHostProof(oldProof))
    XCTAssertFalse(reader.records.values.contains { $0.state == "verified" })
  }

  func testPrivateTlsProofIsBoundToCertificateChallengeGroupAndContactTrust() throws {
    let (reader, host) = try completePair()
    let expected: [String: Any] = ["role": "host", "nonce": String(repeating: "a", count: 64),
      "certificate": String(repeating: "b", count: 64), "group": String(repeating: "c", count: 32)]
    var body = expected
    body["scope"] = "ogm-private-channel-v1"; body["from"] = host.id; body["to"] = ""
    let token = try host.sign(body)
    XCTAssertEqual(try reader.verifyPrivateChannel(token, expected: expected), host.id)
    for field in ["nonce", "certificate", "group", "role", "from"] {
      var wrong = expected; wrong[field] = "wrong"
      XCTAssertThrowsError(try reader.verifyPrivateChannel(token, expected: wrong))
    }
    var client = expected; client["role"] = "client"; client["to"] = host.id
    let signed = try reader.signPrivateChannel(client)
    XCTAssertEqual(try ContactWire.verify(signed, key: reader.key)["to"] as? String, host.id)
    XCTAssertThrowsError(try reader.signPrivateChannel(expected))
    try reader.change(host.id, action: "block")
    XCTAssertThrowsError(try reader.verifyPrivateChannel(token, expected: expected))
    XCTAssertThrowsError(try reader.signPrivateChannel(client))
  }

  func testTranscriptJsonMatchesAndroidIncludingUnicodeAndSlashes() throws {
    let fields = ["ogm-nfc-contact-v1", "key", "A/B Żółw 👋", "nonce", "hostkey", "Host", "nonce"]
    XCTAssertEqual(String(data: try ContactWire.json(["fields": fields]), encoding: .utf8),
      #"{"fields":["ogm-nfc-contact-v1","key","A/B Żółw 👋","nonce","hostkey","Host","nonce"]}"#)
  }

  func testInvitationRequiresAnActualLocalHostAndNoAdmissionToken() throws {
    let map: [String: Any] = ["app": "offline-group-messenger", "transport": "wifi-direct", "version": 3,
      "privateGroup": true, "networkName": "DIRECT-ab-Test", "passphrase": "test-password-123", "hostAddress": "192.168.49.1"]
    XCTAssertEqual(try IOSGroupInvitation(map).host, "192.168.49.1")
    for host in ["127.0.0.1", "example.com", "8.8.8.8", "192.168.49.999", "192.168.049.1"] {
      var wrong = map; wrong["hostAddress"] = host
      XCTAssertThrowsError(try IOSGroupInvitation(wrong))
    }
    var wrong = map; wrong["hostAddress"] = nil
    XCTAssertThrowsError(try IOSGroupInvitation(wrong))
    wrong = map; wrong["admissionToken"] = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try IOSGroupInvitation(wrong))
  }

}

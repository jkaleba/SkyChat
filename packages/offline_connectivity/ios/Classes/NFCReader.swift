import CoreNFC
import Foundation

/// Reads Android HCE services without using iPhone card emulation.
final class NFCReader: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var operation: (@MainActor (NFCISO7816Tag) async throws -> Void)?
    private var completion: ((Error?) -> Void)?
    private var reading = false
    private var generation = 0

    func start(message: String, operation: @escaping @MainActor (NFCISO7816Tag) async throws -> Void,
               completion: @escaping (Error?) -> Void) throws {
        try require(session == nil, "Finish or cancel the current NFC scan first.")
        try require(NFCTagReaderSession.readingAvailable, "NFC reading requires a supported physical iPhone.")
        self.operation = operation; self.completion = completion; reading = false
        guard let created = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
            self.operation = nil; self.completion = nil
            throw SkyChatError.invalid("Cannot start NFC. Check the signing entitlements.")
        }
        generation += 1
        session = created; created.alertMessage = message; created.begin()
    }
    func cancel() {
        generation += 1
        let current = session; let callback = completion
        session = nil; operation = nil; completion = nil; reading = false
        current?.invalidate()
        callback?(SkyChatError.invalid("NFC scan cancelled. Start again when ready."))
    }
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard self.session === session else { return }
        generation += 1
        let callback = completion
        self.session = nil; operation = nil; completion = nil; reading = false
        callback?(SkyChatError.invalid("NFC scan ended. Keep both phones unlocked and try again."))
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard self.session === session, !reading else { return }
        guard tags.count == 1, case .iso7816(let tag) = tags[0] else {
            session.alertMessage = "Hold the top of the iPhone near one Android phone with NFC sharing open."
            session.restartPolling(); return
        }
        reading = true
        let token = generation
        Task { @MainActor in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.connect(to: tags[0]) { error in
                        if let error = error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: Void()) }
                    }
                }
                try require(self.generation == token && self.session === session)
                try await self.operation?(tag)
                try require(self.generation == token && self.session === session)
                self.finish(session: session, error: nil)
            } catch {
                if self.generation == token && self.session === session { self.finish(session: session, error: error) }
            }
        }
    }
    private func finish(session: NFCTagReaderSession, error: Error?) {
        let callback = completion
        self.session = nil; operation = nil; completion = nil; reading = false
        if error == nil { session.alertMessage = "NFC exchange complete. Return to SkyChat."; session.invalidate() }
        else { session.invalidate(errorMessage: "NFC exchange failed. Retry with both phones unlocked.") }
        callback?(error)
    }
    @MainActor func send(_ command: Data, to tag: NFCISO7816Tag) async throws -> Data {
        let token = generation
        try require(session != nil)
        guard let apdu = NFCISO7816APDU(data: command) else { throw SkyChatError.invalid("Invalid NFC command.") }
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error = error { continuation.resume(throwing: error) }
                else if sw1 != 0x90 || sw2 != 0 { continuation.resume(throwing: SkyChatError.invalid("Android NFC service refused the exchange.")) }
                else { continuation.resume(returning: data) }
            }
        }
        try require(session != nil && generation == token && reply.count <= 200)
        return reply
    }
    static let contactSelect = Data([0, 0xA4, 4, 0, 9, 0xF0, 0x4F, 0x46, 0x46, 0x4C, 0x49, 0x4E, 0x45, 2])
    static let invitationSelect = Data([0, 0xA4, 4, 0, 9, 0xF0, 0x4F, 0x46, 0x46, 0x4C, 0x49, 0x4E, 0x45, 1])
    static func command(_ code: UInt8, offset: Int, length: Int) -> Data {
        Data([0, code, UInt8((offset >> 8) & 255), UInt8(offset & 255), UInt8(length)])
    }
    @MainActor func exchange(_ value: [String: Any], tag: NFCISO7816Tag) async throws -> [String: Any] {
        let data = try ContactWire.json(value)
        try require((1...8192).contains(data.count))
        _ = try await send(Self.command(0x10, offset: data.count, length: 0), to: tag)
        for offset in stride(from: 0, to: data.count, by: 200) {
            let count = min(200, data.count - offset)
            _ = try await send(Self.command(0x20, offset: offset, length: count) + data.subdata(in: offset..<offset + count), to: tag)
        }
        let header = try await send(Self.command(0x30, offset: 0, length: 0), to: tag)
        return try ContactWire.object(await readPayload(header: header, maximum: 8192, tag: tag))
    }
    @MainActor func readPayload(header: Data, maximum: Int, tag: NFCISO7816Tag) async throws -> Data {
        try require(header.count == 2)
        let size = Int(header[0]) * 256 + Int(header[1])
        try require((1...maximum).contains(size))
        var bytes = Data()
        for offset in stride(from: 0, to: size, by: 200) {
            let count = min(200, size - offset)
            let chunk = try await send(Self.command(0xB0, offset: offset, length: count), to: tag)
            try require(chunk.count == count)
            bytes.append(chunk)
        }
        return bytes
    }
}

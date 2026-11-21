import Foundation

// Xiaomi wearable protocol over BLE V1 (service FE95: 0051 command read, 0052 command write,
// 0053 activity data), used by the Mi Band 8 and the Xiaomi Watch S1 Active. Byte layouts and
// their Gadgetbridge citations are in docs/BLE-V1.md. Platform independent, like MiProtocol.swift,
// so it can be tested on the Mac.

/// AES-CCM for one V1 session (docs/BLE-V1.md section 8).
struct MiV1Cipher {
    let keys: MiAuth.SessionKeys

    /// nonce4 ‖ 00 00 00 00 ‖ counter (u32 LE).
    static func nonce(_ base: Data, counter: UInt32) -> Data {
        var out = Data(base)
        out.append(contentsOf: [0, 0, 0, 0])
        out.append(contentsOf: [UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF),
                                UInt8((counter >> 16) & 0xFF), UInt8(counter >> 24)])
        return out
    }

    /// Phone to watch, with the message's counter.
    func encrypt(_ plaintext: Data, counter: UInt16) -> Data {
        MiCrypto.ccmEncrypt(key: keys.encryptionKey, nonce: Self.nonce(keys.encryptionNonce, counter: UInt32(counter)),
                            plaintext: plaintext)
    }

    /// Watch to phone, always with counter 0. Nil when the tag doesn't match.
    func decrypt(_ ciphertextAndTag: Data) -> Data? {
        MiCrypto.ccmDecrypt(key: keys.decryptionKey, nonce: Self.nonce(keys.decryptionNonce, counter: 0),
                            ciphertextAndTag: ciphertextAndTag)
    }
}

/// One V1 characteristic (docs/BLE-V1.md sections 5-7): one outgoing message in flight at a time,
/// chunked messages split and joined, acknowledgements. It does no I/O: each call returns the
/// values to write to this same characteristic and what happened.
struct MiV1Channel {
    enum Event: Equatable {
        /// A complete incoming message, decrypted.
        case message(Data)
        /// The watch accepted (true) or refused (false) the message in flight.
        case acknowledged(Bool)
        /// An encrypted incoming message that could not be decrypted (its byte count): the tag did
        /// not match, or it came before the session keys.
        case undecryptable(Int)
        /// Something the protocol doesn't expect here, for the log.
        case unexpected(String)
    }

    struct Output: Equatable {
        var writes: [Data] = []
        var events: [Event] = []

        mutating func append(_ other: Output) {
            writes += other.writes
            events += other.events
        }
    }

    /// Bytes per write, the 2-byte chunk field included (iOS: maximumWriteValueLength). BLE
    /// guarantees at least 20.
    var maxWrite: Int
    /// The session's keys, set once the watch's HMAC checks out; incoming encrypted messages are
    /// decrypted from then on. Outgoing ones are encrypted only after `authenticated()`.
    var cipher: MiV1Cipher?
    private(set) var encrypts = false
    /// The counter of the next encrypted outgoing message.
    private(set) var counter: UInt16 = 1

    private enum InFlight {
        case single
        case chunked(body: [UInt8], sliceSize: Int)
    }

    private var queue: [Data] = []
    private var inFlight: InFlight?

    /// Slices expected for the chunked message being received; 0 when none is.
    private var expectedSlices = 0
    private var incomingEncrypted = false
    private var slices: [Int: Data] = [:]

    init(maxWrite: Int = 244) {
        self.maxWrite = maxWrite
    }

    /// A chunked message is partly received: the caller asks for the missing slices
    /// (`requestMissing()`) when none arrives for 5 s.
    var isReceiving: Bool { expectedSlices > 0 }

    private var writeSize: Int { max(maxWrite, 20) }

    /// The watch confirmed authentication: encrypt from now on, count from 1, and drop whatever
    /// was queued, in flight or partly received.
    mutating func authenticated() {
        encrypts = true
        counter = 1
        queue = []
        inFlight = nil
        expectedSlices = 0
        slices = [:]
    }

    /// Queues one message. It is written at once unless another is in flight.
    mutating func send(_ message: Data) -> Output {
        queue.append(message)
        return sendNext()
    }

    /// Handles one notification from this characteristic.
    mutating func receive(_ value: Data) -> Output {
        var out = Output()
        let b = [UInt8](value)
        guard b.count >= 3 else {
            out.events.append(.unexpected("short value \(Self.hex(b))"))
            return out
        }
        let chunk = Int(b[0]) | Int(b[1]) << 8
        if chunk != 0 {
            receiveSlice(chunk, Data(b[2...]), &out)
            return out
        }
        let type = b[2]
        guard type <= 3, b.count >= (type == 0 ? 6 : 4) else {
            out.events.append(.unexpected("control \(Self.hex(b))"))
            return out
        }
        switch type {
        case 0:
            // A chunked message follows: enc, slice count.
            if expectedSlices > 0 {
                out.events.append(.unexpected("chunked start with \(slices.count) of \(expectedSlices) slices pending"))
            }
            incomingEncrypted = b[3] == 1
            expectedSlices = Int(b[4]) | Int(b[5]) << 8
            slices = [:]
            out.writes.append(Data([0, 0, 1, 1]))
        case 1:
            chunkAcknowledgement(b[3], Array(b[4...]), &out)
        case 2:
            // Single-write message: acknowledge first, then the body.
            out.writes.append(Data([0, 0, 3, 0]))
            deliver(Data(b[4...]), encrypted: b[3] == 1, &out)
        default:
            // Acknowledgement of our single-write message.
            guard case .single? = inFlight else {
                out.events.append(.unexpected("acknowledgement \(Self.hex(b)) with no single message in flight"))
                return out
            }
            inFlight = nil
            out.events.append(.acknowledged(b[3] == 0))
            out.append(sendNext())
        }
        return out
    }

    /// No slice arrived for a while: ask again for the missing ones, as many as fit in one write.
    mutating func requestMissing() -> Output {
        var out = Output()
        guard expectedSlices > 0 else { return out }
        let missing = (1...expectedSlices).filter { slices[$0] == nil }
        guard !missing.isEmpty else { return out }
        var write = Data([0, 0, 1, 5])
        for index in missing.prefix((writeSize - 4) / 2) { write.append(Self.u16(index)) }
        out.writes.append(write)
        return out
    }

    // MARK: sending

    private mutating func sendNext() -> Output {
        var out = Output()
        guard inFlight == nil, !queue.isEmpty else { return out }
        let message = queue.removeFirst()
        var body = message
        var ctr: UInt16?
        if encrypts, let cipher {
            ctr = counter
            body = cipher.encrypt(message, counter: counter)
            counter &+= 1
        }
        if body.count + 6 <= writeSize {
            var write = Data([0, 0, 2, ctr == nil ? 2 : 1])
            if let ctr { write.append(Self.u16(Int(ctr))) }
            write.append(body)
            inFlight = .single
            out.writes.append(write)
        } else {
            let whole = (ctr.map { [UInt8](Self.u16(Int($0))) } ?? []) + [UInt8](body)
            let sliceSize = writeSize - 2
            let count = (whole.count + sliceSize - 1) / sliceSize
            inFlight = .chunked(body: whole, sliceSize: sliceSize)
            out.writes.append(Data([0, 0, 0, ctr == nil ? 0 : 1]) + Self.u16(count))
        }
        return out
    }

    private mutating func chunkAcknowledgement(_ subtype: UInt8, _ rest: [UInt8], _ out: inout Output) {
        guard case .chunked(let body, let sliceSize)? = inFlight else {
            out.events.append(.unexpected("chunk acknowledgement \(subtype) with no chunked message in flight"))
            return
        }
        let count = (body.count + sliceSize - 1) / sliceSize
        func slice(_ index: Int) -> Data {
            let start = (index - 1) * sliceSize
            return Self.u16(index) + Data(body[start..<min(start + sliceSize, body.count)])
        }
        switch subtype {
        case 1:
            // Ready: every slice, numbered from 1.
            for index in stride(from: 1, through: count, by: 1) { out.writes.append(slice(index)) }
        case 0, 2:
            inFlight = nil
            out.events.append(.acknowledged(subtype == 0))
            out.append(sendNext())
        case 5:
            let wanted = stride(from: 0, to: rest.count - 1, by: 2).map { Int(rest[$0]) | Int(rest[$0 + 1]) << 8 }
            let valid = wanted.filter { $0 >= 1 && $0 <= count }
            guard !valid.isEmpty else {
                out.events.append(.unexpected("resend request \(Self.hex(rest)) for \(count) slices"))
                return
            }
            for index in valid { out.writes.append(slice(index)) }
        default:
            out.events.append(.unexpected("chunk acknowledgement subtype \(subtype)"))
        }
    }

    // MARK: receiving

    private mutating func receiveSlice(_ index: Int, _ bytes: Data, _ out: inout Output) {
        guard index <= expectedSlices else {
            out.events.append(.unexpected("slice \(index) of \(expectedSlices)"))
            return
        }
        slices[index] = bytes
        guard slices.count == expectedSlices else { return }
        out.writes.append(Data([0, 0, 1, 0]))
        var joined = Data()
        for i in 1...expectedSlices { joined.append(slices[i] ?? Data()) }
        expectedSlices = 0
        slices = [:]
        deliver(joined, encrypted: incomingEncrypted, &out)
    }

    private func deliver(_ body: Data, encrypted: Bool, _ out: inout Output) {
        guard encrypted else {
            out.events.append(.message(body))
            return
        }
        guard let plaintext = cipher?.decrypt(body) else {
            out.events.append(.undecryptable(body.count))
            return
        }
        out.events.append(.message(plaintext))
    }

    // MARK: helpers

    private static func u16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

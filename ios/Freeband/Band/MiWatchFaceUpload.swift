import CommonCrypto
import Foundation

/// Mi Band 8 watch-face upload payloads (BLE V1, FE95/0055).
/// BLE V1 channel framing is handled separately by MiV1Channel.
enum MiWatchFaceUpload {
    static let dataType: UInt64 = 16
    static let defaultChunkSize = 2048

    enum Failure: Error, Equatable {
        case emptyFile
        case invalidChunkSize
        case invalidResumeOffset
        case tooManyParts
    }

    static func installCommand(faceID: String, size: Int) -> Data {
        var start = PBWriter()
        start.string(1, faceID)
        start.varint(2, UInt64(size))
        var watchface = PBWriter()
        watchface.message(6, start)
        var command = PBWriter()
        command.varint(1, 4)
        command.varint(2, 4)
        command.message(6, watchface)
        return command.data
    }

    static func uploadRequest(size: Int, md5: Data) -> Data {
        var request = PBWriter()
        request.varint(1, dataType)
        request.bytes(2, md5)
        request.varint(3, UInt64(size))
        var upload = PBWriter()
        upload.message(1, request)
        var command = PBWriter()
        command.varint(1, 22)
        command.varint(2, 0)
        command.message(24, upload)
        return command.data
    }

    /// Builds [00, type, md5, sizeLE, file-from-resume, crc32LE] and
    /// wraps it in BLE V1 data parts: [total u16 LE, index u16 LE, payload].
    static func parts(file: Data, chunkSize: Int = defaultChunkSize,
                      resumePosition: Int = 0) throws -> [Data] {
        guard !file.isEmpty else { throw Failure.emptyFile }
        guard chunkSize > 4 else { throw Failure.invalidChunkSize }
        guard resumePosition >= 0 && resumePosition <= file.count else { throw Failure.invalidResumeOffset }

        let digest = md5(file)
        var body = Data([0, UInt8(dataType)])
        body.append(digest)
        appendUInt32LE(UInt32(file.count), to: &body)
        body.append(contentsOf: file.dropFirst(resumePosition))
        appendUInt32LE(crc32(body), to: &body)

        // BLE V1 has no additional per-part link overhead; the four-byte
        // total/index prefix is included in the negotiated chunk size.
        let payloadSize = chunkSize - 4
        let total = (body.count + payloadSize - 1) / payloadSize
        guard total <= Int(UInt16.max) else { throw Failure.tooManyParts }
        var result: [Data] = []
        result.reserveCapacity(total)
        for index in 0..<total {
            let lower = index * payloadSize
            let upper = min(lower + payloadSize, body.count)
            var part = Data()
            appendUInt16LE(UInt16(total), to: &part)
            appendUInt16LE(UInt16(index + 1), to: &part)
            part.append(contentsOf: body[lower..<upper])
            result.append(part)
        }
        return result
    }

    static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

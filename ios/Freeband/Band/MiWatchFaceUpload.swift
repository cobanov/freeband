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


    static func parseFile(_ data: Data) throws -> ImportedWatchFace {
        guard data.count >= 0xA8 else { throw ParseFailure.headerTooShort }
        guard data.count <= 16 * 1024 * 1024 else { throw ParseFailure.fileTooLarge }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == [0x5A, 0xA5, 0x34, 0x12] else {
            throw ParseFailure.invalidMagic
        }
        let faceCount = Int(bytes[0x1C]) | (Int(bytes[0x1D]) << 8)
        guard faceCount == 2 else { throw ParseFailure.missingAlwaysOnFace(faceCount) }

        func headerString(_ range: Range<Int>) -> String? {
            let raw = Data(bytes[range])
            let trimmed = raw.prefix { $0 != 0 }
            guard !trimmed.isEmpty else { return nil }
            return String(data: Data(trimmed), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let id = headerString(0x28..<0x31), id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }) else {
            throw ParseFailure.invalidID
        }
        let name = headerString(0x68..<0xA4) ?? "Imported watch face"
        return ImportedWatchFace(id: id, name: name, data: data, faceCount: faceCount)
    }


    enum ParseFailure: Error, LocalizedError {
        case headerTooShort
        case fileTooLarge
        case invalidMagic
        case invalidID
        case missingAlwaysOnFace(Int)

        var errorDescription: String? {
            switch self {
            case .headerTooShort: return "The file is shorter than a Mi Band 8 watch-face header."
            case .fileTooLarge: return "The watch-face file is larger than the 16 MB safety limit."
            case .invalidMagic: return "This file does not have a recognized Xiaomi watch-face signature."
            case .invalidID: return "The watch-face ID in the file is missing or invalid."
            case .missingAlwaysOnFace(let count):
                return "This file contains \(count) face style(s). Mi Band 8 requires both the normal and always-on styles."
            }
        }
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


struct ImportedWatchFace: Equatable, Identifiable {
    let id: String
    let name: String
    let data: Data
    let faceCount: Int
}

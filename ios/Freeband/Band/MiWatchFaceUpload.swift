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
        return ImportedWatchFace(id: id, name: name, data: data, faceCount: faceCount, preview: preview(data))
    }


    /// Decodes the main preview image block into PNG for the import screen.
    /// Unsupported preview encodings simply produce no preview; the BIN itself remains untouched.
    private static func preview(_ data: Data) -> MiWatchFacePreview? {
        let b = [UInt8](data)
        guard b.count >= 0x24 else { return nil }
        func u16(_ o: Int) -> Int {
            Int(b[o]) | (Int(b[o + 1]) << 8)
        }
        func u32(_ o: Int) -> Int? {
            let value = UInt64(b[o]) | (UInt64(b[o + 1]) << 8) |
                (UInt64(b[o + 2]) << 16) | (UInt64(b[o + 3]) << 24)
            return value <= UInt64(Int.max) ? Int(value) : nil
        }
        guard let offset = u32(0x20), offset > 0, offset + 12 <= b.count else { return nil }
        let sign = Int(b[offset])
        let width = u16(offset + 4)
        let height = u16(offset + 6)
        guard width > 0, height > 0, width <= 512, height <= 512,
              let payloadLength = u32(offset + 8), payloadLength > 0,
              payloadLength <= b.count - offset - 12 else { return nil }

        var pixels = Array(b[(offset + 12)..<(offset + 12 + payloadLength)])
        var bytesPerPixel: Int
        if pixels.count >= 8 && Array(pixels[0..<4]) == [0xE0, 0x21, 0xA5, 0x5A] {
            let info = UInt32(pixels[4]) | (UInt32(pixels[5]) << 8) |
                (UInt32(pixels[6]) << 16) | (UInt32(pixels[7]) << 24)
            bytesPerPixel = Int(info & 0x0F)
            let decodedLength = Int(info >> 4)
            guard (1...4).contains(bytesPerPixel), decodedLength > 0, decodedLength <= 8 * 1024 * 1024 else { return nil }
            let encoded = Array(pixels.dropFirst(8))
            if sign == 0x10 || bytesPerPixel == 1 {
                guard let decoded = decodeRLE20(encoded, expected: decodedLength) else { return nil }
                pixels = decoded
            } else {
                guard let decoded = decodeRLE10(encoded, expected: decodedLength, bytesPerPixel: bytesPerPixel) else { return nil }
                pixels = decoded
            }
        } else {
            bytesPerPixel = sign == 14 ? 1 : (sign == 6 ? 3 : (sign == 3 ? 2 : 4))
        }

        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        func put(_ index: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
            let p = index * 4
            rgba[p] = UInt8((UInt16(red) * UInt16(alpha)) / 255)
            rgba[p + 1] = UInt8((UInt16(green) * UInt16(alpha)) / 255)
            rgba[p + 2] = UInt8((UInt16(blue) * UInt16(alpha)) / 255)
            rgba[p + 3] = alpha
        }

        if sign == 14 {
            guard pixels.count >= pixelCount else { return nil }
            for i in 0..<pixelCount {
                let gray = pixels[i]
                put(i, gray, gray, gray, 255)
            }
        } else if sign == 9 {
            let paletteBytes = 64
            guard pixels.count >= paletteBytes + (pixelCount + 1) / 2 else { return nil }
            for i in 0..<pixelCount {
                let packed = pixels[paletteBytes + i / 2]
                let paletteIndex = i % 2 == 0 ? Int(packed >> 4) : Int(packed & 0x0F)
                let p = paletteIndex * 4
                put(i, pixels[p + 2], pixels[p + 1], pixels[p], pixels[p + 3])
            }
        } else if sign == 0x10 || sign == 10 || bytesPerPixel == 1 {
            guard pixels.count >= 1024 + pixelCount else { return nil }
            for i in 0..<pixelCount {
                let p = 1024 + i
                let palette = Int(pixels[p]) * 4
                put(i, pixels[palette + 2], pixels[palette + 1], pixels[palette], pixels[palette + 3])
            }
        } else if bytesPerPixel == 4 {
            guard pixels.count >= pixelCount * 4 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 4
                put(i, pixels[p + 2], pixels[p + 1], pixels[p], pixels[p + 3])
            }
        } else if bytesPerPixel == 3 {
            guard pixels.count >= pixelCount * 3 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 3
                let lo = UInt16(pixels[p])
                let hi = UInt16(pixels[p + 1])
                let red = UInt8((hi >> 3) << 3)
                let green = UInt8((((hi & 7) << 3) | (lo >> 5)) << 2)
                let blue = UInt8((lo & 31) << 3)
                put(i, red, green, blue, pixels[p + 2])
            }
        } else {
            guard pixels.count >= pixelCount * 2 else { return nil }
            for i in 0..<pixelCount {
                let p = i * 2
                let lo = UInt16(pixels[p])
                let hi = UInt16(pixels[p + 1])
                let red = UInt8((hi >> 3) << 3)
                let green = UInt8((((hi & 7) << 3) | (lo >> 5)) << 2)
                let blue = UInt8((lo & 31) << 3)
                put(i, red, green, blue, 255)
            }
        }

        return MiWatchFacePreview(width: width, height: height, rgba: Data(rgba))
    }

    private static func decodeRLE10(_ input: [UInt8], expected: Int, bytesPerPixel: Int) -> [UInt8]? {
        var output = [UInt8]()
        output.reserveCapacity(expected)
        var cursor = 0
        while cursor < input.count && output.count < expected {
            let control = Int(input[cursor])
            cursor += 1
            let count = control & 0x7F
            guard count > 0 else { return nil }
            if control & 0x80 == 0 {
                guard cursor + bytesPerPixel <= input.count else { return nil }
                let pixel = Array(input[cursor..<(cursor + bytesPerPixel)])
                cursor += bytesPerPixel
                for _ in 0..<count { output.append(contentsOf: pixel) }
            } else {
                let length = count * bytesPerPixel
                guard cursor + length <= input.count else { return nil }
                output.append(contentsOf: input[cursor..<(cursor + length)])
                cursor += length
            }
            if output.count > expected { return nil }
        }
        return output.count == expected ? output : nil
    }

    private static func decodeRLE20(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var output = [UInt8]()
        output.reserveCapacity(expected)
        var cursor = 0
        while cursor < input.count && output.count < expected {
            let control = Int(input[cursor])
            cursor += 1
            let count = control & 0x7F
            guard count > 0 else { return nil }
            if control & 0x80 != 0 {
                guard cursor + count <= input.count else { return nil }
                output.append(contentsOf: input[cursor..<(cursor + count)])
                cursor += count
            } else {
                guard cursor < input.count else { return nil }
                let value = input[cursor]
                cursor += 1
                output.append(contentsOf: repeatElement(value, count: count))
            }
            if output.count > expected { return nil }
        }
        return output.count == expected ? output : nil
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
    let preview: MiWatchFacePreview?
}

struct MiWatchFacePreview: Equatable {
    let width: Int
    let height: Int
    /// Premultiplied RGBA pixels, row-major.
    let rgba: Data
}

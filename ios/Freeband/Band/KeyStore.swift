import Foundation
import Security
import SQLite3

/// One device entry from Mi Fitness's VirtualDevice_registerList.
struct BandKey: Equatable {
    let name: String
    let mac: String?
    let hex: String

    /// Never shows the key itself, only its last four characters.
    var masked: String { String(repeating: "•", count: 8) + hex.suffix(4) }

    var data: Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}

enum KeyLoader {
    enum Failure: LocalizedError {
        case noManifest, unreadable(String), noKeys(String)

        var errorDescription: String? {
            switch self {
            case .noManifest: return String(localized: "No VirtualDevice_registerList/manifest.sqlite in the chosen folder.")
            case .unreadable(let why): return String(localized: "Couldn't read manifest.sqlite: \(why)")
            case .noKeys(let diagnostics): return String(localized: "No encryptKey found. Details: \(diagnostics)")
            }
        }
    }

    /// Accepts the Mi Fitness folder (or any folder above the manifest, or the manifest itself)
    /// and returns every device key found in the registerList_* entries.
    static func load(from url: URL) throws -> [BandKey] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var manifests: [URL] = []
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let file = walker?.nextObject() as? URL {
                if file.lastPathComponent == "manifest.sqlite",
                   file.deletingLastPathComponent().lastPathComponent == "VirtualDevice_registerList" {
                    manifests.append(file)
                }
            }
        } else if url.lastPathComponent == "manifest.sqlite" {
            manifests = [url]
        }
        guard !manifests.isEmpty else { throw Failure.noManifest }

        var keys: [BandKey] = []
        var diagnostics: [String] = []
        for manifest in manifests {
            let (found, notes) = try readManifest(manifest)
            diagnostics.append(notes)
            for key in found where !keys.contains(key) {
                keys.append(key)
            }
        }
        guard !keys.isEmpty else {
            throw Failure.noKeys("\(manifests.count) manifest; " + diagnostics.joined(separator: " | "))
        }
        return keys
    }

    /// The manifest is a YYKVStorage cache: a value sits in `inline_data`, or, when it is large,
    /// in `data/<filename>` next to manifest.sqlite. The entry name carries the Xiaomi server
    /// region (registerList_de, registerList_sg, ...). The database is copied with its WAL files
    /// to a temporary folder before it is opened. Diagnostics never contain key material.
    private static func readManifest(_ manifest: URL) throws -> ([BandKey], String) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: manifest.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: work.appendingPathComponent("manifest.sqlite" + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open(work.appendingPathComponent("manifest.sqlite").path, &db) == SQLITE_OK else {
            throw Failure.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        func rows(_ sql: String) throws -> [[Any?]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.unreadable(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var out: [[Any?]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(statement)).map { i -> Any? in
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, i))
                    case SQLITE_BLOB:
                        guard let bytes = sqlite3_column_blob(statement, i) else { return Data() }
                        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
                    case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, i))
                    default: return nil
                    }
                })
            }
            return out
        }

        let entries = try rows("select key, inline_data, filename from manifest where key like 'registerList%'")
        guard !entries.isEmpty else {
            let names = try rows("select key from manifest limit 15").compactMap { $0[0] as? String }
            return ([], "no registerList entry; entries: \(names)")
        }

        var keys: [BandKey] = []
        var notes: [String] = []
        for entry in entries {
            let name = entry[0] as? String ?? "?"
            var blob = entry[1] as? Data ?? Data()
            var source = "inline \(blob.count)B"
            if blob.isEmpty, let file = entry[2] as? String, !file.isEmpty {
                let path = manifest.deletingLastPathComponent().appendingPathComponent("data").appendingPathComponent(file)
                blob = (try? Data(contentsOf: path)) ?? Data()
                source = "data/ file \(blob.count)B"
            }
            let found = parseRegisterList(blob)
            keys += found
            notes.append("\(name): \(source), bplist=\(blob.starts(with: Data("bplist".utf8))), key=\(found.count)")
        }
        return (keys, notes.joined(separator: "; "))
    }

    /// Finds device dictionaries with an encryptKey in a keyed archive (custom class objects or
    /// NSDictionary), a plain plist, or JSON.
    static func parseRegisterList(_ blob: Data) -> [BandKey] {
        let root = (try? PropertyListSerialization.propertyList(from: blob, format: nil))
            ?? (try? JSONSerialization.jsonObject(with: blob))
        guard let root else { return [] }

        let objects = (root as? [String: Any])?["$objects"] as? [Any]
        func deref(_ value: Any?) -> Any? {
            guard let value else { return nil }
            if let objects, let index = uidIndex(value) {
                guard index < objects.count, (objects[index] as? String) != "$null" else { return nil }
                return objects[index]
            }
            return value
        }
        func text(_ value: Any?) -> String? {
            switch deref(value) {
            case let s as String: return s
            case let d as Data: return d.map { String(format: "%02x", $0) }.joined()
            case let wrapped as [String: Any]:
                return text(wrapped["NS.string"]) ?? text(wrapped["NS.bytes"]) ?? text(wrapped["NS.data"])
            default: return nil
            }
        }

        var dictionaries: [[String: Any]] = []
        if let objects {
            for case let object as [String: Any] in objects {
                if let names = object["NS.keys"] as? [Any], let values = object["NS.objects"] as? [Any] {
                    var dict: [String: Any] = [:]
                    for (name, value) in zip(names, values) {
                        if let name = text(name) { dict[name] = value }
                    }
                    dictionaries.append(dict)
                } else {
                    dictionaries.append(object)
                }
            }
        } else {
            func walk(_ node: Any) {
                if let dict = node as? [String: Any] {
                    dictionaries.append(dict)
                    dict.values.forEach(walk)
                } else if let list = node as? [Any] {
                    list.forEach(walk)
                }
            }
            walk(root)
        }

        var keys: [BandKey] = []
        for dict in dictionaries {
            guard let field = dict.keys.first(where: { $0.lowercased().replacingOccurrences(of: "_", with: "") == "encryptkey" }),
                  var hex = text(dict[field])?.lowercased() else { continue }
            if hex.hasPrefix("0x") { hex.removeFirst(2) }
            guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { continue }
            let key = BandKey(name: text(dict["name"]) ?? text(dict["deviceName"]) ?? "(isimsiz)",
                              mac: text(dict["mac"]) ?? text(dict["randomMac"]) ?? text(dict["bleMac"]),
                              hex: hex)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// NSKeyedArchiver references are CFKeyedArchiverUID values, which Swift only exposes
    /// through their description: "<CFKeyedArchiverUID 0x…>{value = 12}".
    private static func uidIndex(_ value: Any) -> Int? {
        let text = String(describing: value)
        guard text.contains("CFKeyedArchiverUID"),
              let range = text.range(of: #"value = (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst("value = ".count))
    }
}

/// Secrets live only in this app's Keychain on the phone: one auth key per band and the hub
/// token. Items are device-only and never sync to iCloud.
enum Vault {
    private static let service = "dev.cobanov.freeband"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// Candidate keys for a band, the one that last authenticated first. Mi Fitness can keep an
    /// old binding's key next to the new one after a band is reset and paired again.
    static func bandKeys(_ bandID: UUID) -> [String] {
        let account = "band-key-\(bandID.uuidString)"
        guard let stored = get(account) else { return [] }
        return stored.split(separator: ",").map(String.init).filter { $0.count == 32 }
    }

    static func setBandKeys(_ keys: [String], for bandID: UUID) {
        var unique: [String] = []
        for key in keys.map({ $0.lowercased() }) where !unique.contains(key) { unique.append(key) }
        if unique.isEmpty { removeBandKey(bandID) } else { set(unique.joined(separator: ","), for: "band-key-\(bandID.uuidString)") }
    }

    static func bandKey(_ bandID: UUID) -> String? { bandKeys(bandID).first }
    static func removeBandKey(_ bandID: UUID) { remove("band-key-\(bandID.uuidString)") }

}

extension BandKey {
    /// Mi Fitness can list one band several times (old and new bindings, several caches):
    /// one group per MAC, or per name when there is no MAC.
    static func groupedByBand(_ keys: [BandKey]) -> [[BandKey]] {
        var order: [String] = []
        var groups: [String: [BandKey]] = [:]
        for key in keys {
            let id = key.macSuffix ?? key.name.trimmingCharacters(in: .whitespaces).lowercased()
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(key)
        }
        return order.compactMap { groups[$0] }
    }

    /// A "Pro" name wins (a Band 10 is never called Pro), then the longest.
    static func bestName(_ group: [BandKey]) -> String {
        let names = group.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.first { $0.localizedCaseInsensitiveContains("pro") } ?? names.max { $0.count < $1.count } ?? "Xiaomi Smart Band 10"
    }

    init(hex: String) {
        self.init(name: "", mac: nil, hex: hex)
    }

    /// Last four hex digits of the MAC, as in the band's advertised name.
    var macSuffix: String? {
        guard let mac else { return nil }
        let hex = mac.uppercased().filter(\.isHexDigit)
        return hex.count >= 4 ? String(hex.suffix(4)) : nil
    }
}

import Foundation

/// One installed watch face as reported by Command{4,0}.
struct WatchFace: Identifiable, Equatable {
    let id: String
    let name: String
    let isActive: Bool
    let canDelete: Bool
}

/// Watch-face protobuf messages (docs/CAPABILITIES.md section 13.2).
enum MiWatchFaceProtocol {
    static func listCommand() -> Data {
        var command = PBWriter()
        command.varint(1, 4)
        command.varint(2, 0)
        return command.data
    }

    static func setCommand(id: String) -> Data {
        actionCommand(subtype: 1, id: id)
    }

    static func deleteCommand(id: String) -> Data {
        actionCommand(subtype: 2, id: id)
    }

    static func readList(from command: PBMessage) -> [WatchFace]? {
        guard let watchface = command.message(6),
              let list = watchface.message(1) else { return nil }

        return list.messages(1).compactMap { item in
            guard let idData = item.blobs[1],
                  let id = String(data: idData, encoding: .utf8),
                  !id.isEmpty else { return nil }

            let name = item.blobs[2].flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Watch face \(id)"

            return WatchFace(
                id: id,
                name: name,
                isActive: item.varints[3] == 1,
                canDelete: item.varints[4] == 1
            )
        }
    }

    static func acknowledgement(from command: PBMessage) -> Bool? {
        command.message(6)?.varints[4].map { $0 != 0 }
    }

    private static func actionCommand(subtype: UInt64, id: String) -> Data {
        var watchface = PBWriter()
        watchface.string(2, id)

        var command = PBWriter()
        command.varint(1, 4)
        command.varint(2, subtype)
        command.message(6, watchface)
        return command.data
    }
}

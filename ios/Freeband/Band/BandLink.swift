import CoreBluetooth
import Foundation

/// What a session needs to find and unlock one band.
struct BandTarget {
    let id: UUID
    let name: String
    let mac: String?
    let macSuffix: String?
    /// Candidate auth keys, tried in order until the band's HMAC matches.
    let keys: [Data]
}

/// One BLE session with a band at a time: find it (iOS connection or advertisement), open an
/// SPP v2 session on FE95/005E/005F, authenticate as an iOS companion, read battery and live
/// stats, then always hand the channel back (unsubscribe 005E, release the connection) so
/// Mi Fitness keeps working. Protocol details: findings.md, sections 4–6.
final class BandLink: NSObject, ObservableObject {
    /// `send` authenticates, sends the given protobuf commands encrypted, then lets go.
    enum Purpose: Equatable { case check, sync, live, send([Data]) }

    /// How a session ended. A sync is complete only when every listed file arrived; anything
    /// less is partial (what arrived is kept) and does not count as a successful sync.
    enum Outcome: Equatable {
        case complete
        case partial(String)
        case failed(LinkError)

        var isSuccess: Bool { self == .complete }

        var label: String {
            switch self {
            case .complete: return "complete"
            case .partial(let reason): return "partial: \(reason)"
            case .failed(let error): return "failed: \(error.code)"
            }
        }
    }

    /// Why a session failed. `message` is one localized sentence for the UI.
    enum LinkError: Error, Equatable {
        /// The band answered but refused the session: Mi Fitness holds the channel.
        case bandHeldByMiFitness
        case bluetoothOff
        case unauthorized
        case bluetoothUnsupported
        case bluetoothNotReady
        /// The key did not match the band's HMAC (every candidate tried).
        case wrongKey
        /// Not connected to iOS and not advertising.
        case notFound
        /// No answer before authentication completed.
        case timeout
        case disconnected
        case connectFailed
        /// The band does not expose FE95/005E/005F.
        case channelUnavailable
        /// Subscribing to 005E failed.
        case channelRefused
        /// The session ended (stopped) before the band was read.
        case notRead

        var code: String {
            switch self {
            case .bandHeldByMiFitness: return "band_held_by_mi_fitness"
            case .bluetoothOff: return "bluetooth_off"
            case .unauthorized: return "unauthorized"
            case .bluetoothUnsupported: return "bluetooth_unsupported"
            case .bluetoothNotReady: return "bluetooth_not_ready"
            case .wrongKey: return "wrong_key"
            case .notFound: return "not_found"
            case .timeout: return "timeout"
            case .disconnected: return "disconnected"
            case .connectFailed: return "connect_failed"
            case .channelUnavailable: return "channel_unavailable"
            case .channelRefused: return "channel_refused"
            case .notRead: return "not_read"
            }
        }

        var message: String {
            switch self {
            case .bandHeldByMiFitness: return String(localized: "The band refused the connection. Close Mi Fitness and try again.")
            case .bluetoothOff: return BandLink.message(for: .poweredOff)
            case .unauthorized: return BandLink.message(for: .unauthorized)
            case .bluetoothUnsupported: return BandLink.message(for: .unsupported)
            case .bluetoothNotReady: return BandLink.message(for: .unknown)
            case .wrongKey: return String(localized: "The key doesn't match this band. Sync the band in Mi Fitness, then read the key again.")
            case .notFound: return String(localized: "Band not found. Make sure it's on your wrist, nearby and charged.")
            case .timeout: return String(localized: "The band didn't answer. Close Mi Fitness and try again.")
            case .disconnected: return String(localized: "The connection dropped. Bring the band closer and try again.")
            case .connectFailed: return String(localized: "Couldn't connect to the band. Turn Bluetooth off and on, then try again.")
            case .channelUnavailable: return String(localized: "This band doesn't offer the Bluetooth channel Freeband uses.")
            case .channelRefused: return String(localized: "The band didn't open its data channel. Try again.")
            case .notRead: return String(localized: "Couldn't read the band.")
            }
        }

        static func bluetooth(_ state: CBManagerState) -> LinkError {
            switch state {
            case .poweredOff: return .bluetoothOff
            case .unauthorized: return .unauthorized
            case .unsupported: return .bluetoothUnsupported
            default: return .bluetoothNotReady
            }
        }
    }

    enum Phase: Equatable {
        case idle, searching, connecting, authenticating, reading, live, done
        /// The session ended with part of the data (see Outcome.partial).
        case partial(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .searching, .connecting, .authenticating, .reading, .live: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return ""
            case .searching: return String(localized: "Searching…")
            case .connecting: return String(localized: "Connecting…")
            case .authenticating: return String(localized: "Verifying…")
            case .reading: return String(localized: "Reading…")
            case .live: return String(localized: "Live")
            case .done: return String(localized: "Synced")
            case .partial(let reason): return reason
            case .failed(let message): return message
            }
        }
    }

    static let fe95 = CBUUID(string: "FE95")
    static let rxUUID = CBUUID(string: "005E")
    static let txUUID = CBUUID(string: "005F")
    static let liveLimit: TimeInterval = 120
    static let syncWindow: TimeInterval = 12
    /// Upper bound for a sync that also fetches activity files.
    static let fileSyncLimit: TimeInterval = 120

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bandID: UUID?
    @Published private(set) var stats: MiAuth.LiveStats?
    @Published private(set) var battery: Int?
    @Published private(set) var log: [String] = []
    /// Bands iOS holds a connection to right now (no session needed to know this).
    @Published private(set) var nearby: Set<UUID> = []
    @Published private(set) var bluetooth: CBManagerState = .unknown

    /// Every observation, on the main queue.
    var onSample: ((UUID, SampleDraft) -> Void)?
    /// Once per session, on the main queue.
    var onFinish: ((UUID, Outcome) -> Void)?
    /// How the last session ended.
    @Published private(set) var lastOutcome: Outcome?
    /// After authentication: which candidate key worked and the band's own Bluetooth name.
    var onIdentified: ((UUID, Int, String?) -> Void)?
    /// Past activity files already stored need not be fetched again (today's always are).
    var hasActivityFile: ((UUID, String) -> Bool)?
    /// A complete, CRC-checked activity file; `today` when it came from the band's today list.
    var onActivityFile: ((UUID, ActivityFileID, Data, Bool) -> Void)?

    /// Firmware, serial and model, read after authentication.
    var onDeviceInfo: ((UUID, MiAuth.DeviceInfo) -> Void)?
    /// Worn / charging / asleep, read after authentication and pushed by the band when it changes.
    @Published private(set) var deviceState: MiAuth.DeviceState?

    /// Activity files fetched / requested in this sync.
    @Published private(set) var fileProgress: (done: Int, total: Int)?

    private var central: CBCentralManager!
    private var target: BandTarget?
    private var purpose = Purpose.sync
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var buffer: [UInt8] = []
    private var writeQueue: [Data] = []
    private var seq: UInt8 = 0
    /// Data frames by sequence number, kept so a NACK can resend them; the UInt8 key bounds it to 256.
    private var sentFrames: [UInt8: Data] = [:]
    private var phoneNonce = Data()
    private var keys: MiAuth.SessionKeys?
    private var active = false
    private var authed = false
    private var finishing = false
    private var realtimeOn = false

    // activity-file sync (docs/ACTIVITY.md): list today, list past, then one file at a time
    private enum FileStage { case idle, listingToday, listingPast, fetching, done }
    private var fileStage = FileStage.idle
    private var todayIDs: [ActivityFileID] = []
    private var fileQueue: [ActivityFileID] = []
    private var currentFile: ActivityFileID?
    private var currentRetried = false
    private var assembler = ActivityAssembler()
    private var fileToken = 0
    private var run = 0
    private var keyIndex = 0
    private var pendingStart: (() -> Void)?
    /// Files that arrived complete (CRC-checked) in this sync, by the id each one carries.
    private var receivedFiles: Set<ActivityFileID> = []
    /// The files this sync asked for; only these count toward a complete sync.
    private var requestedFiles: Set<ActivityFileID> = []
    /// The file list did not arrive in time; the sync went on without files.
    private var fileListMissing = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: control

    func start(_ target: BandTarget, purpose: Purpose) {
        guard !phase.isBusy else { return }
        run += 1
        let thisRun = run
        self.target = target
        self.purpose = purpose
        bandID = target.id
        stats = nil
        battery = nil
        log = []
        peripheral = nil
        rx = nil
        tx = nil
        buffer = []
        writeQueue = []
        seq = 0
        sentFrames = [:]
        keys = nil
        phoneNonce = Data()
        authed = false
        finishing = false
        realtimeOn = false
        keyIndex = 0
        deviceState = nil
        fileStage = .idle
        todayIDs = []
        fileQueue = []
        currentFile = nil
        fileProgress = nil
        receivedFiles = []
        requestedFiles = []
        fileListMissing = false
        active = true
        note("start: \(target.name), \(target.keys.count) key(s)")

        after(25, thisRun) { [weak self] in
            guard let self, self.active, !self.authed else { return }
            self.fail(.timeout)
        }

        switch central.state {
        case .poweredOn:
            locate(thisRun)
        case .unknown, .resetting:
            phase = .searching
            pendingStart = { [weak self] in self?.locate(thisRun) }
        default:
            fail(.bluetooth(central.state))
        }
    }

    /// Ends live or sync early; what was read so far is kept.
    func stop() {
        guard active else { return }
        note("stopped by user")
        finish()
    }

    /// Cheap check, no session: which of these bands is connected to the phone at the moment.
    func refreshNearby(_ bands: [(id: UUID, suffix: String?)]) {
        guard central.state == .poweredOn else {
            nearby = []
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.fe95]).compactMap { $0.name?.uppercased() }
        nearby = Set(bands.compactMap { band in
            guard let suffix = band.suffix, connected.contains(where: { $0.hasSuffix(suffix) }) else { return nil }
            return band.id
        })
    }

    // MARK: finding the band

    private func locate(_ thisRun: Int) {
        guard run == thisRun, active else { return }
        phase = .searching
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.fe95])
        if let match = connected.first(where: { nameMatches($0.name) }) {
            note("connected in iOS: \(match.name ?? "?")")
            connect(match)
            return
        }
        note("not connected in iOS, scanning for adverts")
        central.scanForPeripherals(withServices: nil, options: nil)
        after(12, thisRun) { [weak self] in
            guard let self, self.phase == .searching else { return }
            self.central.stopScan()
            self.fail(.notFound)
        }
    }

    private func nameMatches(_ name: String?) -> Bool {
        guard let suffix = target?.macSuffix, let name else { return false }
        return name.uppercased().hasSuffix(suffix)
    }

    /// MiBeacon service data under FE95 carries the MAC (reversed) when frame-control bit 4 is set.
    static func beaconMAC(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 11, b[0] & 0x10 != 0 else { return nil }
        return b[5...10].reversed().map { String(format: "%02X", $0) }.joined()
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        phase = .connecting
        central.connect(p, options: nil)
    }

    // MARK: session

    private func startSession() {
        phase = .authenticating
        note("→ SessionConfig")
        send(MiFrame.encode(kind: MiFrame.kindSessionConfig, seq: 0, payload: MiFrame.startSessionPayload))
    }

    private func startAuth() {
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        phoneNonce = nonce
        note("→ auth 1/2")
        sendCommand(MiAuth.nonceCommand(phoneNonce: nonce), encrypted: false)
    }

    private func didAuthenticate() {
        authed = true
        if let id = target?.id { onIdentified?(id, keyIndex, peripheral?.name) }
        // Every session keeps the band's clock and time zone right (Mi Fitness may be gone) and
        // reads what the band is and how it is worn.
        sendCommand(MiAuth.clockCommand(is24Hour: MiAuth.phoneUses24Hour), encrypted: true)
        sendCommand(MiAuth.systemGet(2), encrypted: true)
        sendCommand(MiAuth.systemGet(78), encrypted: true)
        if case .send(let commands) = purpose {
            phase = .reading
            note("auth ok → sending \(commands.count) command(s)")
            for command in commands { sendCommand(command, encrypted: true) }
            let thisRun = run
            after(2.0, thisRun) { [weak self] in self?.finish() }
            return
        }
        phase = purpose == .live ? .live : .reading
        // A sync that reconnected for its next file (reconnectForNextFile) carries on fetching.
        let resuming = purpose == .sync && fileStage == .fetching
        note(resuming ? "auth ok → next file" : "auth ok → battery + live stats")
        sendCommand(MiAuth.batteryCommand(), encrypted: true)
        sendCommand(MiAuth.realtimeCommand(start: true), encrypted: true)
        realtimeOn = true
        if resuming {
            fetchNextFile()
            return  // the first connection's time limit still runs
        }
        if purpose == .sync {
            fileStage = .listingToday
            note("→ today's file list")
            sendCommand(MiAuth.activityListCommand(today: true), encrypted: true)
            let listRun = run
            after(10, listRun) { [weak self] in
                guard let self, self.fileStage == .listingToday || self.fileStage == .listingPast else { return }
                self.note("no file list, continuing without files")
                self.fileListMissing = true
                self.fileStage = .done
                self.finishSyncIfDone()
            }
        }
        let thisRun = run
        let window = purpose == .live ? Self.liveLimit : (purpose == .sync ? Self.fileSyncLimit : Self.syncWindow)
        after(window, thisRun) { [weak self] in
            guard let self, self.active else { return }
            self.note("time limit reached (\(Int(window)) s)")
            self.finish()
        }
    }

    private func handle(_ command: PBMessage) {
        let type = command.varints[1] ?? 0
        let subtype = command.varints[2] ?? 0
        switch (type, subtype) {
        case (MiAuth.commandTypeAuth, MiAuth.subtypeNonce):
            guard let verify = command.message(3)?.message(31),
                  let watchNonce = verify.blobs[1], let watchHmac = verify.blobs[2] else {
                fail(.bandHeldByMiFitness)
                return
            }
            guard let target, keyIndex < target.keys.count else { return }
            guard let result = MiAuth.confirmCommand(authKey: target.keys[keyIndex], phoneNonce: phoneNonce,
                                                     watchNonce: watchNonce, watchHmac: watchHmac,
                                                     deviceName: "Freeband") else {
                if keyIndex + 1 < target.keys.count {
                    retryWithNextKey()
                } else {
                    fail(.wrongKey)
                }
                return
            }
            keys = result.keys
            note("→ auth 2/2")
            sendCommand(result.command, encrypted: false)

        case (MiAuth.commandTypeAuth, MiAuth.subtypeAuth):
            didAuthenticate()

        case (2, 1):
            guard let level = MiAuth.batteryLevel(command) else { return }
            battery = Int(level)
            emit(.battery(Int(level)))
            if purpose == .check, stats != nil { finish() }

        case (8, 47):
            guard let live = MiAuth.liveStats(command) else { return }
            stats = live
            emit(.live(live))
            switch purpose {
            case .check where battery != nil: finish()
            case .sync where live.heartRate > 10: finishSyncIfDone()
            default: break
            }

        case (8, 1) where fileStage == .listingToday:
            todayIDs = ActivityFileID.list(MiAuth.activityFileIDBytes(command))
            note("← today \(todayIDs.count) file(s); → past list")
            fileStage = .listingPast
            sendCommand(MiAuth.activityListCommand(today: false), encrypted: true)

        case (8, 2) where fileStage == .listingPast:
            let past = ActivityFileID.list(MiAuth.activityFileIDBytes(command))
            let id = target?.id
            let wanted = past.filter { file in
                guard let id, let has = hasActivityFile else { return true }
                return !has(id, file.hex)
            }
            requestedFiles = Set(todayIDs + wanted)
            fileQueue = requestedFiles.sorted()
            note("← past \(past.count) file(s), \(wanted.count) new; \(fileQueue.count) to request")
            fileProgress = (0, fileQueue.count)
            fileStage = .fetching
            fetchNextFile()

        case (8, 3), (8, 5):
            break

        case (2, 2):
            if let info = MiAuth.deviceInfo(command), let id = target?.id {
                note("← device: \(info.model), firmware \(info.firmware)")
                onDeviceInfo?(id, info)
            }

        case (2, 78), (2, 79):
            if let state = MiAuth.deviceState(command) { deviceState = state }

        case (2, 3):
            note("← clock set (status \(command.varints[100] ?? 0))")

        default:
            note("← \(type)/\(subtype) not handled")
        }
    }

    // MARK: activity files

    private func fetchNextFile() {
        guard active, fileStage == .fetching else { return }
        guard !fileQueue.isEmpty else {
            fileStage = .done
            currentFile = nil
            note("files done")
            finishSyncIfDone()
            return
        }
        let file = fileQueue.removeFirst()
        currentFile = file
        currentRetried = false
        requestCurrentFile()
    }

    private func requestCurrentFile() {
        guard let file = currentFile else { return }
        assembler = ActivityAssembler()
        sendCommand(MiAuth.activityFetchCommand(file.data), encrypted: true)
        armFileTimer()
    }

    /// 5 s per chunk; one retry, then the file is skipped for this sync. A Redmi Watch 5 Active can
    /// stop answering file requests on a connection, so the rest of the queue gets a fresh one.
    private func armFileTimer() {
        fileToken += 1
        let token = fileToken
        after(5, run) { [weak self] in
            guard let self, self.fileToken == token, self.fileStage == .fetching, let file = self.currentFile else { return }
            if !self.currentRetried {
                self.currentRetried = true
                self.note("file \(file.hex) did not answer, retrying")
                self.requestCurrentFile()
                return
            }
            self.note("file \(file.hex) skipped")
            self.advanceFileProgress()
            if self.fileQueue.isEmpty {
                self.fetchNextFile()
            } else {
                self.note("reconnecting for the \(self.fileQueue.count) remaining file(s)")
                self.reconnectForNextFile()
            }
        }
    }

    private func receiveActivityChunk(_ packet: Data) {
        guard fileStage == .fetching, let file = currentFile else { return }
        switch assembler.add(packet) {
        case .needMore:
            armFileTimer()
        case .complete(let data):
            fileToken += 1
            // A file opens with its own id. The Redmi Watch 5 Active answers earlier requests late,
            // so file the data under that id (as Gadgetbridge does), not under the one awaited;
            // that one is still owed, so its timer restarts.
            let got = ActivityFileID(data.prefix(7)) ?? file
            let queued = fileQueue.contains(got)
            fileQueue.removeAll { $0 == got }
            if receivedFiles.insert(got).inserted, let id = target?.id {
                onActivityFile?(id, got, data, todayIDs.contains(got))
            }
            if got == file || queued { advanceFileProgress() }
            if got == file {
                fetchNextFile()
            } else {
                note("← file \(got.hex) arrived while waiting for \(file.hex)")
                assembler = ActivityAssembler()
                armFileTimer()
            }
        case .failed(let reason):
            fileToken += 1
            note("file \(file.hex) corrupt: \(reason)")
            advanceFileProgress()
            fetchNextFile()
        }
    }

    private func advanceFileProgress() {
        if let progress = fileProgress { fileProgress = (progress.done + 1, progress.total) }
    }

    /// A sync ends once its files are in and a heart-rate reading has arrived (or the limit hits).
    private func finishSyncIfDone() {
        guard purpose == .sync else { return }
        let filesDone = fileStage == .done || fileStage == .idle
        if filesDone, (stats?.heartRate ?? 0) > 10 { finish() }
        if filesDone, fileStage == .done, stats != nil {
            // files finished; give the pulse a few seconds, then end anyway
            let thisRun = run
            after(8, thisRun) { [weak self] in
                guard let self, self.active, self.purpose == .sync else { return }
                self.finish()
            }
        }
    }

    private func emit(_ draft: SampleDraft) {
        guard let id = target?.id else { return }
        onSample?(id, draft)
    }

    /// The band rejected this key: drop the session and start again with the next candidate.
    private func retryWithNextKey() {
        keyIndex += 1
        note("key did not match, trying key \(keyIndex + 1)")
        reconnect()
    }

    /// A fresh session for the rest of the file queue: a Redmi Watch 5 Active can stop answering file
    /// requests on a connection. A skipped file stays on the device, unacknowledged (docs/ACTIVITY.md
    /// 2.6), and comes with the next sync.
    private func reconnectForNextFile() {
        fileToken += 1
        let token = fileToken
        currentFile = nil
        realtimeOn = false
        reconnect()
        // The start timeout only covers the first connection; the next file request moves the token.
        after(20, run) { [weak self] in
            guard let self, self.fileToken == token else { return }
            self.fail(.timeout)
        }
    }

    /// Drops the session and opens a new one within the same run; sync state is kept.
    private func reconnect() {
        if let p = peripheral {
            if let rx, rx.isNotifying { p.setNotifyValue(false, for: rx) }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        rx = nil
        tx = nil
        buffer = []
        writeQueue = []
        seq = 0
        sentFrames = [:]
        keys = nil
        phoneNonce = Data()
        let thisRun = run
        after(1.0, thisRun) { [weak self] in self?.locate(thisRun) }
    }

    /// Stops the live stream, then releases the channel.
    private func finish() {
        guard active, !finishing else { return }
        finishing = true
        if authed, realtimeOn { sendCommand(MiAuth.realtimeCommand(start: false), encrypted: true) }
        let thisRun = run
        after(0.4, thisRun) { [weak self] in
            guard let self else { return }
            let outcome = self.authed ? self.completion() : .failed(.notRead)
            self.release()
            switch outcome {
            case .complete: self.phase = .done
            case .partial(let reason): self.phase = .partial(reason)
            case .failed(let error): self.phase = .failed(error.message)
            }
            self.note("result: \(outcome.label)")
            self.lastOutcome = outcome
            if let id = self.target?.id { self.onFinish?(id, outcome) }
        }
    }

    /// An authenticated session: complete unless it was a sync whose file list never came or
    /// whose files did not all arrive (skipped, corrupt, or cut off by the time limit or a stop).
    private func completion() -> Outcome {
        guard purpose == .sync else { return .complete }
        if fileListMissing || fileStage == .idle || fileStage == .listingToday || fileStage == .listingPast {
            return .partial(String(localized: "Couldn't get the file list. Records come with the next sync.", comment: "Partial sync"))
        }
        let total = requestedFiles.count
        let received = receivedFiles.intersection(requestedFiles).count
        if received < total {
            return .partial(String(localized: "\(received) of \(total) files received. The rest come with the next sync.", comment: "Partial sync"))
        }
        return .complete
    }

    private func fail(_ error: LinkError) {
        guard active else { return }
        note("error: \(error.code)")
        if authed, purpose == .sync {
            // Files already stored still need their records sent, so end as a partial sync.
            realtimeOn = false
            finish()
            return
        }
        release()
        phase = .failed(error.message)
        lastOutcome = .failed(error)
        if let id = target?.id { onFinish?(id, .failed(error)) }
    }

    /// Hands the channel back to Mi Fitness.
    private func release() {
        active = false
        pendingStart = nil
        writeQueue = []
        if central.isScanning { central.stopScan() }
        if let p = peripheral {
            if let rx, rx.isNotifying { p.setNotifyValue(false, for: rx) }
            central.cancelPeripheralConnection(p)
        }
        note("channel released")
    }

    // MARK: frames

    private func sendCommand(_ protobuf: Data, encrypted: Bool) {
        var body = protobuf
        if encrypted, let keys { body = MiCrypto.ctr(key: keys.encryptionKey, protobuf) }
        let payload = Data([0x01, encrypted ? 0x02 : 0x01]) + body
        let frame = MiFrame.encode(kind: MiFrame.kindData, seq: seq, payload: payload)
        sentFrames[seq] = frame
        send(frame)
        seq &+= 1
    }

    private func send(_ frame: Data) {
        guard let p = peripheral else { return }
        let size = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < frame.count {
            writeQueue.append(frame.subdata(in: offset..<min(offset + size, frame.count)))
            offset += size
        }
        pump()
    }

    private func pump() {
        guard let p = peripheral, let tx else { return }
        while !writeQueue.isEmpty, p.canSendWriteWithoutResponse {
            p.writeValue(writeQueue.removeFirst(), for: tx, type: .withoutResponse)
        }
    }

    private func receive(_ chunk: Data) {
        guard active else { return }
        buffer.append(contentsOf: chunk)
        for packet in MiFrame.drain(&buffer) {
            switch packet.kind {
            case MiFrame.kindSessionConfig:
                if phoneNonce.isEmpty { startAuth() }
            case MiFrame.kindData:
                send(MiFrame.encode(kind: MiFrame.kindAck, seq: packet.seq, payload: Data()))
                decode(packet)
            case MiFrame.kindNack:
                // The NACK carries the seq the device expects next: resend what was sent from there
                // on, as Gadgetbridge's SPP path does (XiaomiSppProtocolV2.onNack; its BLE path only logs).
                let resend = MiFrame.resendSeqs(next: seq, nack: packet.seq)
                note(resend.isEmpty ? "← NACK \(packet.seq), nothing pending" : "← NACK \(packet.seq), resending \(resend.count)")
                for s in resend {
                    if let frame = sentFrames[s] { send(frame) }
                }
            default:
                break
            }
        }
    }

    private func decode(_ packet: MiFrame.Packet) {
        guard packet.payload.count >= 2 else { return }
        let channel = packet.payload[0] & 0x0F
        let opcode = packet.payload[1]
        var body = Data(packet.payload.dropFirst(2))
        if opcode == 2 {
            guard let keys else { return }
            body = MiCrypto.ctr(key: keys.decryptionKey, body)
        }
        if channel == 5 {
            receiveActivityChunk(body)
            return
        }
        guard channel == 1, let command = PBMessage(body) else { return }
        if command.varints[1] == 2, command.varints[2] == 110 {
            // Unknown everywhere (docs/CAPABILITIES.md §16); keep the bytes for decoding later.
            note("← 2/110 \(body.count) bytes: \(body.map { String(format: "%02x", $0) }.joined())")
        }
        handle(command)
    }

    // MARK: helpers

    private func after(_ seconds: TimeInterval, _ thisRun: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.run == thisRun else { return }
            work()
        }
    }

    private func note(_ text: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
    }

    static func message(for state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return String(localized: "Bluetooth is off. Turn it on in Control Centre.")
        case .unauthorized: return String(localized: "Freeband can't use Bluetooth. Allow it in Settings › Freeband.")
        case .unsupported: return String(localized: "This device doesn't support Bluetooth LE.")
        default: return String(localized: "Bluetooth isn't ready. Try again in a moment.")
        }
    }
}

extension BandLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetooth = central.state
        if central.state == .poweredOn, let start = pendingStart {
            pendingStart = nil
            start()
        } else if active, central.state != .poweredOn, central.state != .unknown, central.state != .resetting {
            fail(.bluetooth(central.state))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .searching, let target else { return }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        var match = nameMatches(advertisedName)
        if !match, let beacon = serviceData?[Self.fe95], let mac = Self.beaconMAC(beacon),
           let wanted = target.mac?.uppercased().filter(\.isHexDigit) {
            match = mac == wanted
        }
        guard match else { return }
        note("found advertising (\(RSSI) dBm)")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active, peripheral == self.peripheral else { return }
        note("connected")
        peripheral.discoverServices([Self.fe95])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active, peripheral == self.peripheral else { return }
        fail(.connectFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active, peripheral == self.peripheral else { return }
        fail(.disconnected)
    }
}

extension BandLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.fe95 }) else {
            fail(.channelUnavailable)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active else { return }
        rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
        tx = service.characteristics?.first { $0.uuid == Self.txUUID }
        guard let rx, tx != nil else {
            fail(.channelUnavailable)
            return
        }
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, characteristic.uuid == Self.rxUUID else { return }
        if error != nil {
            fail(.channelRefused)
        } else if characteristic.isNotifying, keys == nil {
            // keys, not `authed`: a reconnect for the next file keeps `authed` but drops the keys.
            startSession()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxUUID, let value = characteristic.value else { return }
        receive(value)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}

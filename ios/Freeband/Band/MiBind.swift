import CryptoKit
import Foundation

/// First pairing ("bind") in local mode: the phone and the band agree on the 16-byte auth key
/// without the vendor app or its server. Written from docs/BIND.md; section numbers refer to it.
/// No I/O: plaintext protobuf commands in, commands and results out. Untried on a band.
enum MiBind {
    static let commandType: UInt64 = 1
    static let idStart: UInt64 = 17
    static let idVerify: UInt64 = 18
    static let idConfirm: UInt64 = 19
    static let idResult: UInt64 = 25

    static let verifyModeServer: UInt64 = 1
    static let verifyModeLocal: UInt64 = 2
    /// OOB modes: 0 none, 1 numeric comparison, 2 dynamic code, 3 button on the band.
    static let oobButton: UInt64 = 3
    static let supportedOOB: Set<UInt64> = [0, 2, 3]

    static let errorAlreadyBound: UInt64 = 1
    static let errorCancel: UInt64 = 6
    static let errorVerify: UInt64 = 7

    struct Config {
        /// Any stable string for the owner; the band gets its MD5 first and the string at the end.
        var userID: String
        /// Stored next to the auth key and sent again at every login (section 6).
        var appDeviceID: String
        /// This phone's name. Left out of the first command when empty, as the vendor app does.
        var deviceName: String
        /// Appended to both proofs when not empty (section 3); the vendor app's is empty.
        var dynamicCode = ""

        /// Both ids: 1 to 64 bytes, no NUL.
        var isValid: Bool {
            [userID, appDeviceID].allSatisfy { (1...64).contains($0.utf8.count) && !$0.utf8.contains(0) }
        }
    }

    /// The band's answer to the first command. `mac`, `serialNumber` and `did` identify the band:
    /// keep them out of logs.
    struct BandInfo: Equatable {
        let verifyMode: UInt64
        let oobMode: UInt64
        let serialNumber: String
        let mac: String
        let model: String
        let did: String
    }

    enum Failure: Error, Equatable {
        /// The band is bound to another phone or app (error code 1): it has to be reset first.
        case alreadyBound
        /// The band wants a signature from Xiaomi's server (verify mode 1): not possible here.
        case serverBindRequired
        case unsupportedVerifyMode(UInt64)
        case unsupportedOOB(UInt64)
        /// Declined on the band, or its prompt timed out (error code 6 or confirm_result false).
        case rejectedOnBand
        /// The band's public key or proof is malformed or wrong.
        case bandProofMismatch
        /// Any other account error code (section 5), with the command id it answered.
        case band(code: UInt64, step: UInt64)
        /// A reply with the expected id that is neither the expected message nor an error code.
        case unexpectedReply(step: UInt64)
    }

    struct Bound {
        /// Bytes 40..56 of the key block: the key for every later login.
        let authKey: Data
        /// Bytes 0..40, in the roles of the normal login's keys. Whether the band treats this
        /// connection as logged in with them is unverified (section 6).
        let keys: MiAuth.SessionKeys
        let appDeviceID: String
        let info: BandInfo
    }

    enum Step {
        /// Write this command. `confirmOnBand`: the band may now be waiting for its button.
        case send(Data, confirmOnBand: Bool)
        case bound(Bound)
        /// Over. `tellBand`, when present, is an error command to write before giving up.
        case failed(Failure, tellBand: Data?)
        /// Not a bind reply, or not one this stage waits for.
        case ignored
    }

    // MARK: Commands (section 2)

    private static func command(_ id: UInt64, field: Int, _ body: PBWriter) -> Data {
        var account = PBWriter()
        account.message(field, body)
        return envelope(id, account)
    }

    private static func envelope(_ id: UInt64, _ account: PBWriter) -> Data {
        var command = PBWriter()
        command.varint(1, commandType)
        command.varint(2, id)
        command.message(3, account)
        return command.data
    }

    /// Step 1: BindStartV2{check_dynamic_code false, MD5 of the user id, device name if any}.
    static func startCommand(userID: String, deviceName: String) -> Data {
        var start = PBWriter()
        start.bool(1, false)
        start.bytes(2, Data(Insecure.MD5.hash(data: Data(userID.utf8))))
        if !deviceName.isEmpty { start.string(3, deviceName) }
        return command(idStart, field: 11, start)
    }

    /// Step 3: AppVerify{app device id, public key as 64 bytes X ‖ Y}.
    static func appVerifyCommand(appDeviceID: String, publicKey: Data) -> Data {
        var verify = PBWriter()
        verify.string(1, appDeviceID)
        verify.bytes(2, publicKey)
        return command(idVerify, field: 17, verify)
    }

    /// Step 5: AppConfirm{app random, app proof}.
    static func appConfirmCommand(appRandom: Data, appSign: Data) -> Data {
        var confirm = PBWriter()
        confirm.bytes(1, appRandom)
        confirm.bytes(2, appSign)
        return command(idConfirm, field: 19, confirm)
    }

    static let resultNonce = Data(0x10...0x1B)
    static let resultAAD = Data("bind-data".utf8)

    /// Step 7: BindResultV2{AES-CCM(ResultInfo{user id, CompanionDevice})} under the
    /// phone-to-band key, the fixed nonce and the associated data "bind-data".
    static func resultCommand(encryptionKey: Data, userID: String, deviceName: String) -> Data {
        // CompanionDevice as the normal login sends it: device_type IOS (1), name, capability.
        var companion = PBWriter()
        companion.varint(1, 1)
        companion.string(3, deviceName)
        companion.varint(4, 0xFFFF_FFFF)
        var info = PBWriter()
        info.string(1, userID)
        info.message(2, companion)
        var result = PBWriter()
        result.bytes(1, MiCrypto.ccmEncrypt(key: encryptionKey, nonce: resultNonce, plaintext: info.data, aad: resultAAD))
        return command(idResult, field: 29, result)
    }

    /// Account{error_code} under a bind id: how the phone tells the band it gave up.
    static func errorCommand(id: UInt64, code: UInt64) -> Data {
        var account = PBWriter()
        account.varint(3, code)
        return envelope(id, account)
    }

    // MARK: Crypto (section 3)

    /// HMAC-SHA256 keyed with the ECDH secret over a side's random (and the dynamic code).
    static func proof(sharedSecret: Data, random: Data, dynamicCode: String = "") -> Data {
        MiCrypto.hmacSHA256(key: sharedSecret, random + Data(dynamicCode.utf8))
    }

    /// HKDF-SHA256, salt = app random ‖ device random, IKM = ECDH secret, info "miwear-bind", 64 bytes.
    static func keyBlock(sharedSecret: Data, appRandom: Data, deviceRandom: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret),
                               salt: appRandom + deviceRandom,
                               info: Data("miwear-bind".utf8),
                               outputByteCount: 64).withUnsafeBytes { Data($0) }
    }

    // MARK: Replies

    static func bandInfo(_ account: PBMessage) -> BandInfo? {
        guard let info = account.message(12), let verifyMode = info.varints[1], let oobMode = info.varints[5] else { return nil }
        func text(_ field: Int) -> String { String(decoding: info.blobs[field] ?? Data(), as: UTF8.self) }
        return BandInfo(verifyMode: verifyMode, oobMode: oobMode, serialNumber: text(2), mac: text(3), model: text(4), did: text(7))
    }

    // MARK: State machine

    /// One bind. `start()` gives the first command; feed every plaintext command the band sends
    /// to `receive` and do what the returned step says. The caller owns the timeouts (the vendor
    /// app waits 15 to 20 s per reply) and gives up by dropping the machine.
    struct Machine {
        private enum Stage { case idle, info, verify, confirm, result, done }

        let config: Config
        private let privateKey: P256.KeyAgreement.PrivateKey
        private let appRandom: Data
        private var stage = Stage.idle
        private var block = Data()
        private(set) var info: BandInfo?

        /// nil when the config is invalid or `appRandom` is not 16 bytes. Tests pass a fixed key
        /// and random; the app takes the defaults.
        init?(config: Config,
              privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
              appRandom: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) {
            guard config.isValid, appRandom.count == 16 else { return nil }
            self.config = config
            self.privateKey = privateKey
            self.appRandom = appRandom
        }

        mutating func start() -> Data {
            stage = .info
            return MiBind.startCommand(userID: config.userID, deviceName: config.deviceName)
        }

        mutating func receive(_ command: Data) -> Step {
            let expected: [Stage: UInt64] = [.info: idStart, .verify: idVerify, .confirm: idConfirm, .result: idResult]
            guard let waitingFor = expected[stage], let message = PBMessage(command),
                  message.varints[1] == commandType, let id = message.varints[2],
                  expected.values.contains(id) else { return .ignored }
            let account = message.message(3)

            if let code = account?.varints[3], !(code == 0 && id == idResult && stage == .result) {
                switch code {
                case errorAlreadyBound: return fail(.alreadyBound)
                case errorCancel: return fail(.rejectedOnBand)
                default: return fail(.band(code: code, step: id))
                }
            }
            guard id == waitingFor else { return .ignored }
            let waitsForButton = info?.oobMode == oobButton

            switch stage {
            case .info:
                guard let account, let info = MiBind.bandInfo(account) else { return fail(.unexpectedReply(step: id)) }
                self.info = info
                guard info.verifyMode == verifyModeLocal else {
                    return fail(info.verifyMode == verifyModeServer ? .serverBindRequired : .unsupportedVerifyMode(info.verifyMode))
                }
                guard supportedOOB.contains(info.oobMode) else { return fail(.unsupportedOOB(info.oobMode)) }
                stage = .verify
                return .send(MiBind.appVerifyCommand(appDeviceID: config.appDeviceID, publicKey: privateKey.publicKey.rawRepresentation),
                             confirmOnBand: info.oobMode == oobButton)

            case .verify:
                guard let verify = account?.message(18) else { return fail(.unexpectedReply(step: id)) }
                // The band's key is X ‖ Y, which is CryptoKit's raw representation; an off-curve point throws.
                guard let key = verify.blobs[1], let random = verify.blobs[2], let sign = verify.blobs[3],
                      key.count == 64, random.count == 16, sign.count == 32,
                      let bandKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: key),
                      let secret = try? privateKey.sharedSecretFromKeyAgreement(with: bandKey).withUnsafeBytes({ Data($0) }),
                      MiBind.proof(sharedSecret: secret, random: random, dynamicCode: config.dynamicCode) == sign
                else { return fail(.bandProofMismatch, tellBand: MiBind.errorCommand(id: idConfirm, code: errorVerify)) }
                block = MiBind.keyBlock(sharedSecret: secret, appRandom: appRandom, deviceRandom: random)
                stage = .confirm
                let appSign = MiBind.proof(sharedSecret: secret, random: appRandom, dynamicCode: config.dynamicCode)
                return .send(MiBind.appConfirmCommand(appRandom: appRandom, appSign: appSign), confirmOnBand: waitsForButton)

            case .confirm:
                guard let confirmed = account?.message(20)?.varints[1] else { return fail(.unexpectedReply(step: id)) }
                guard confirmed != 0 else { return fail(.rejectedOnBand) }
                stage = .result
                return .send(MiBind.resultCommand(encryptionKey: block.subdata(in: 16..<32), userID: config.userID, deviceName: config.deviceName),
                             confirmOnBand: false)

            case .result:
                // Error code 0, or no error code at all (the vendor app takes both as success).
                guard let info else { return fail(.unexpectedReply(step: id)) }
                stage = .done
                let keys = MiAuth.SessionKeys(decryptionKey: block.subdata(in: 0..<16), encryptionKey: block.subdata(in: 16..<32),
                                              decryptionNonce: block.subdata(in: 32..<36), encryptionNonce: block.subdata(in: 36..<40))
                return .bound(Bound(authKey: block.subdata(in: 40..<56), keys: keys, appDeviceID: config.appDeviceID, info: info))

            case .idle, .done:
                return .ignored
            }
        }

        private mutating func fail(_ failure: Failure, tellBand: Data? = nil) -> Step {
            stage = .done
            return .failed(failure, tellBand: tellBand)
        }
    }
}

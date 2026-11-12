import AudioToolbox
import AVFoundation
import Foundation

/// Rings the phone for Find Phone (docs/STAY-CONNECTED.md section 4): a looping tone made in code
/// on the playback audio session, so it sounds with the silent switch on and can start from the
/// background (the `audio` background mode), plus a vibration every 2 s.
@MainActor
final class PhoneRinger {
    private var player: AVAudioPlayer?
    private var vibration: Timer?

    var isRinging: Bool { player != nil }

    /// False when the audio session or the player refused; the caller still has the notification.
    @discardableResult
    func start() -> Bool {
        guard player == nil else { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` makes the session mixable, which is what lets it start in the background.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.tone, fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 1
            guard player.play() else { throw CocoaError(.featureUnsupported) }
            self.player = player
        } catch {
            try? session.setActive(false)
            return false
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibration = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        return true
    }

    func stop() {
        vibration?.invalidate()
        vibration = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static let sampleRate = 22_050

    /// One second of 16-bit mono PCM as a WAV file: two 120 ms beeps (2093 Hz, then 1568 Hz) with
    /// 5 ms fades, then quiet. Looped, that's two beeps a second.
    static let tone: Data = wav(samples: toneSamples())

    static func toneSamples() -> [Int16] {
        let rate = Double(sampleRate)
        let beeps: [(start: Double, frequency: Double)] = [(0.0, 2093), (0.2, 1568)]
        let length = 0.12, fade = 0.005, amplitude = 0.9 * Double(Int16.max)
        return (0..<sampleRate).map { i in
            let t = Double(i) / rate
            guard let beep = beeps.first(where: { t >= $0.start && t < $0.start + length }) else { return 0 }
            let x = t - beep.start
            let envelope = min(1, x / fade, (length - x) / fade)
            return Int16(amplitude * envelope * sin(2 * .pi * beep.frequency * x))
        }
    }

    /// A RIFF/WAVE file around 16-bit mono samples.
    static func wav(samples: [Int16]) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        let pcm = samples.reduce(into: Data(capacity: samples.count * 2)) { data, sample in
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        var out = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVE".utf8)
        out += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        out += Data("data".utf8) + le32(pcm.count) + pcm
        return out
    }
}

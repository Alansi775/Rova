import Foundation
import AVFoundation

/// Says the stop out loud, through whatever you are listening on.
///
/// The case this exists for: phone in a pocket, headphones in, music playing,
/// on a bus. A notification is useless there — it buzzes a pocket nobody is
/// going to reach into, and the stop goes past.
///
/// The first version of this did not work on a real bus. The notification
/// arrived, the music ducked, and then nothing was said. The ducking proves
/// the audio session activated, so the failure was downstream of it, and
/// three things in that path were fragile:
///
/// * The chime was played through `AVAudioEngine`, started on demand. An
///   engine started while the app is in the background, on a route that may
///   have changed since launch, is far more likely to fail silently than an
///   `AVAudioPlayer` with a prepared file.
/// * `AVSpeechSynthesisVoice(language: "en-GB")` returns a voice the device
///   may not actually have installed, and synthesis then produces silence.
///   A voice is now chosen from what the device reports it has.
/// * `.mixWithOthers` was set alongside `.duckOthers`. Mixing tells the
///   system this audio may be blended away; for an announcement that must be
///   heard, that is the wrong request.
///
/// `lastOutcome` records what actually happened on the last attempt, so a
/// silent failure is visible in Settings instead of being discovered by
/// missing a stop.
@MainActor
final class SpokenGuidance: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpokenGuidance()

    /// Off by default: an app that starts talking into someone's music
    /// without being asked has overstepped.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private let key = "rova.spokenGuidance"

    /// What happened last time something was said. Shown in Settings.
    enum Outcome: Equatable {
        case never
        case spoke(String)
        case failed(String)
    }
    private(set) var lastOutcome: Outcome = .never

    private let synth = AVSpeechSynthesizer()
    private var chimePlayer: AVAudioPlayer?
    private var said: Set<String> = []
    private var pending: String?

    private override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: speaking

    /// Say something once per trip, identified by `id`.
    func announce(_ sentence: String, id: String) {
        guard isEnabled, said.insert(id).inserted else { return }
        speak(sentence)
    }

    /// Forget what has been said, so the next trip announces again.
    func resetTrip() { said.removeAll() }

    /// Spoken immediately, so the rider hears exactly what it will sound like
    /// before relying on it — and so a device that cannot speak says so here
    /// rather than on a bus.
    func demonstrate() { speak("Next stop announcements are on.") }

    private func speak(_ sentence: String) {
        guard activateSession() else {
            lastOutcome = .failed("The audio session could not be started.")
            return
        }
        playChime()

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestEnglishVoice()
        // A touch slower than default. Heard once, over traffic, through
        // earbuds, by someone who may not speak English natively.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.preUtteranceDelay = 0.5       // let the chime finish
        utterance.postUtteranceDelay = 0.2

        pending = sentence
        synth.speak(utterance)
    }

    /// A voice the device actually has.
    ///
    /// Asking for a language by name returns something whether or not the
    /// voice is installed, and synthesis with a missing voice is silent. The
    /// installed list is checked instead, preferring British English, then
    /// any English, then whatever the system default is.
    static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        if let gb = installed.first(where: { $0.language == "en-GB" }) { return gb }
        if let us = installed.first(where: { $0.language == "en-US" }) { return us }
        if let any = installed.first(where: { $0.language.hasPrefix("en") }) { return any }
        return nil      // nil means the system default, which is never missing
    }

    // MARK: audio session

    @discardableResult
    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.duckOthers` lowers the music instead of stopping it, and
            // `.spokenAudio` tells the system this is speech, so headphones
            // and CarPlay treat it the way they treat navigation. No
            // `.mixWithOthers`: this must be heard, not blended away.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func releaseSession() {
        // Hand the route back and tell other apps, so the music comes back up
        // instead of staying ducked for the rest of the ride.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: the chime

    /// Two rising notes, generated once and played from a file.
    ///
    /// A distinctive sound is the point: it has to be recognisable as ROVA
    /// within a quarter of a second, by someone not looking, so they know the
    /// next words are about their stop and not part of what they were
    /// listening to.
    private func playChime() {
        guard let player = chimePlayer ?? makeChimePlayer() else { return }
        chimePlayer = player
        player.currentTime = 0
        player.play()
    }

    private func makeChimePlayer() -> AVAudioPlayer? {
        guard let url = Self.chimeFileURL() else { return nil }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.9
        player?.prepareToPlay()
        return player
    }

    /// Writes the chime to a WAV in the caches directory, once.
    private static func chimeFileURL() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("rova-chime.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let rate = 44_100.0
        let notes: [(frequency: Double, seconds: Double)] = [(784, 0.11), (1046.5, 0.22)]  // G5 → C6
        var samples: [Int16] = []
        for note in notes {
            let count = Int(rate * note.seconds)
            for i in 0..<count {
                let t = Double(i) / rate
                // A short attack and an exponential decay: a struck note
                // rather than a beep, which carries over music without
                // being louder than it.
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 7.0)
                let value = sin(2 * .pi * note.frequency * t) * attack * decay * 0.33
                samples.append(Int16(max(-1, min(1, value)) * 32_000))
            }
        }

        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); append(UInt32(36 + bytes))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                 // PCM, mono
        append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append("data".data(using: .ascii)!); append(bytes)
        for s in samples { append(s) }

        do { try data.write(to: url); return url } catch { return nil }
    }

    // MARK: outcome

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        // Copy the string out before crossing actors: the utterance itself is
        // not Sendable.
        let said = utterance.speechString
        Task { @MainActor in
            self.lastOutcome = .spoke(said)
            self.pending = nil
            self.releaseSession()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.lastOutcome = .failed("Speech was cancelled before it finished.")
            self.pending = nil
            self.releaseSession()
        }
    }
}

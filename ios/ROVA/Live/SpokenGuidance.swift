import Foundation
import AVFoundation

/// Says the stop out loud, through whatever you are listening on.
///
/// The case this exists for: phone in a pocket, headphones in, music playing,
/// on a bus. A notification is useless there — it buzzes a pocket nobody is
/// going to reach into, and the rider misses the stop anyway.
///
/// So the announcement is spoken. Music ducks for a moment, a short two-note
/// chime marks it as this app rather than a podcast saying something, the
/// sentence is said, and the music comes back up. Nothing has to be looked at.
///
/// Two rules it holds to, both borrowed from the rest of this project:
///
/// * It never speaks from a guess. The caller only has something to say when
///   progress along the route is measured, so a stale GPS fix produces
///   silence rather than a confident voice naming the wrong stop. Being told
///   out loud to get off is far more convincing than a number on a screen,
///   which makes a wrong announcement worse than a wrong display.
/// * It says each thing once. A bus creeping over a stop boundary must not
///   make the headphones repeat themselves.
@MainActor
final class SpokenGuidance {
    static let shared = SpokenGuidance()

    /// Off by default: an app that starts talking into someone's music
    /// without being asked has overstepped.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private let key = "rova.spokenGuidance"

    private let synth = AVSpeechSynthesizer()
    private var said: Set<String> = []
    private let engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var chime: AVAudioPCMBuffer?

    /// Say something once per trip, identified by `id`.
    func announce(_ sentence: String, id: String) {
        guard isEnabled, said.insert(id).inserted else { return }
        speak(sentence)
    }

    /// Forget what has been said, so the next trip announces again.
    func resetTrip() { said.removeAll() }

    /// Spoken immediately, used when the rider turns the setting on, so they
    /// hear exactly what it will sound like before relying on it.
    func demonstrate() { speak("Next stop announcements are on.") }

    private func speak(_ sentence: String) {
        activateSession()
        playChime()
        let utterance = AVSpeechUtterance(string: sentence)
        // British English: the stop names are Turkish either way, and a voice
        // that matches the app's own language is less jarring than one that
        // half-reads them.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        // A touch slower than default. This is heard once, over traffic,
        // through earbuds, by someone who may not speak English natively.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.preUtteranceDelay = 0.45      // let the chime finish
        utterance.postUtteranceDelay = 0.2
        synth.speak(utterance)
    }

    // MARK: audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // `.duckOthers` lowers the music instead of stopping it, and
        // `.spokenAudio` tells the system this is speech, so CarPlay and
        // headphones treat it the way they treat navigation.
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: the chime

    /// Two rising notes, generated rather than bundled.
    ///
    /// A distinctive sound is the point: it has to be recognisable as ROVA
    /// within a quarter of a second, by someone not looking, so they know the
    /// next words are about their stop and not part of what they were
    /// listening to.
    private func playChime() {
        guard let buffer = chimeBuffer() else { return }
        if !engine.isRunning {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            try? engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private func chimeBuffer() -> AVAudioPCMBuffer? {
        if let chime { return chime }
        let rate = 44_100.0
        let notes: [(frequency: Double, seconds: Double)] = [(784, 0.11), (1046.5, 0.20)]  // G5 → C6
        let total = notes.reduce(0) { $0 + $1.seconds }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(rate * total)),
              let channel = buffer.floatChannelData?[0] else { return nil }

        var frame = 0
        for note in notes {
            let count = Int(rate * note.seconds)
            for i in 0..<count {
                let t = Double(i) / rate
                // A short attack and an exponential decay: a struck note
                // rather than a beep, which is easier to hear over music
                // without being louder than it.
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 7.5)
                let sample = sin(2 * .pi * note.frequency * t) * attack * decay * 0.28
                channel[frame + i] = Float(sample)
            }
            frame += count
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        chime = buffer
        return buffer
    }
}

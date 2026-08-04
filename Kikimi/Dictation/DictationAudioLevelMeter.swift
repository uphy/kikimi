import Foundation

// MARK: - DictationAudioLevelMeter

/// Pure audio-level math behind the HUD's capturing-phase level bars
/// (`docs/design/49-dictation-hud-slim.md` §3.1). Kept free of AppKit/SwiftUI, like
/// `DictationElapsedTimeFormatter`, so every piece is unit-testable on its own.
///
/// The split matters for where each half runs: `rms(_:)` is called on the mic tap's own callback
/// thread (one pass over the buffer, before anything hops to the main actor), while
/// `normalize(rms:)` and `Smoother` run on the HUD's side with a single `Float` in hand.
enum DictationAudioLevelMeter {
    /// Input level that maps to an empty bar. Chosen so a quiet room's noise floor leaves the bars
    /// still -- the whole point of the meter is that motion means "the mic is actually hearing
    /// you", so a display that twitches at ambient noise would say nothing.
    static let floorDb: Float = -50

    /// Root mean square of one mic buffer. Empty input is silence, not a NaN.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS amplitude to the 0...1 the bars are drawn from, linearly in dBFS between
    /// `floorDb` and 0 dB. Non-decreasing in `rms`; digital silence and anything at or below the
    /// floor both return 0, full scale and above return 1.
    static func normalize(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        guard decibels > floorDb else { return 0 }
        guard decibels < 0 else { return 1 }
        return (decibels - floorDb) / -floorDb
    }

    // MARK: - Smoother

    /// Asymmetric exponential moving average over the per-buffer levels: fast to rise, slow to
    /// fall. Buffers arrive every few tens of milliseconds, and speech is full of short gaps
    /// between syllables -- following them exactly would read as flicker rather than as level.
    struct Smoother {
        /// Weight given to a new value while the level is rising (a syllable's onset should appear
        /// immediately) versus falling (the decay is what makes the bars legible).
        static let attack: Float = 0.3
        static let release: Float = 0.08

        private(set) var value: Float = 0

        init() {}

        mutating func update(_ target: Float) -> Float {
            let coefficient = target > value ? Self.attack : Self.release
            value += (target - value) * coefficient
            return value
        }

        /// Back to silence for the next utterance, so a new HUD never opens holding the tail of
        /// the previous one's decay.
        mutating func reset() {
            value = 0
        }
    }
}

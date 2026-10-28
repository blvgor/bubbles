import Foundation

/// A stretch of speech cut from the microphone at pauses: 16 kHz mono Float32 audio (with a short margin
/// before and after) and where the speech itself starts and ends, in seconds from the session start.
public struct AudioSegment: Equatable, Sendable {
    public var samples: [Float]
    public var start: TimeInterval
    public var end: TimeInterval

    public init(samples: [Float], start: TimeInterval, end: TimeInterval) {
        self.samples = samples
        self.start = start
        self.end = end
    }
}

/// Cuts the microphone stream into segments at pauses, for engines that recognise whole phrases (the built-in
/// Whisper, the ChatGPT cloud). One segment = one future transcript line.
///
/// The audio is read in 20 ms frames; a frame's loudness is its RMS in dBFS. The noise floor is the quietest
/// frame of the last 3 s, held between −70 and −40 dBFS, so a steady room tone or fan is not speech while
/// a long phrase without breaths does not become the floor. Speech starts when a frame is 12 dB above
/// the floor (and above −48 dBFS) and goes on while frames stay within 4 dB of that (hysteresis), so the ends
/// of words do not flicker. Silence of `Transcript.pauseThreshold` (0.8 s) closes the segment; less than
/// 0.2 s of speech in it is a click and is dropped. A monologue is cut at `maximumSegment`, below Whisper's
/// 30 s window.
public struct PauseSegmenter: Sendable {
    public static let sampleRate = 16_000
    public static let frameLength = 320                     // 20 ms
    public static let maximumSegment: TimeInterval = 25
    static let frameSeconds = Double(frameLength) / Double(sampleRate)
    static let pauseFrames = Int((Transcript.pauseThreshold / frameSeconds).rounded())     // 40
    static let minimumSpeechFrames = 10                                                    // 0.2 s
    static let marginFrames = 10                                                           // 0.2 s
    static let maximumFrames = Int((maximumSegment / frameSeconds).rounded())
    static let floorWindow = 150                                                           // 3 s
    static let startAboveFloor: Float = 12
    static let hysteresis: Float = 4
    static let quietestStart: Float = -48

    /// Samples not yet making up a whole frame.
    private var partial: [Float] = []
    /// Index of the next frame.
    private var frame = 0
    /// Audio from frame `historyStart` on: the margin before speech, then the segment being spoken.
    private var history: [Float] = []
    private var historyStart = 0
    /// Recent frame levels, for the noise floor.
    private var levels: [Float] = []
    private var levelCursor = 0

    private var inSegment = false
    private var segmentStart = 0
    private var lastLoud = 0
    private var loudFrames = 0

    public init() {}

    /// Microphone audio, 16 kHz mono, in any chunk size → the segments it completed.
    public mutating func append(_ samples: [Float]) -> [AudioSegment] {
        var out: [AudioSegment] = []
        partial += samples
        var offset = 0
        while partial.count - offset >= Self.frameLength {
            if let segment = consume(partial[offset..<offset + Self.frameLength]) { out.append(segment) }
            offset += Self.frameLength
        }
        partial.removeFirst(offset)
        return out
    }

    /// The session ended (stop, pause): the phrase being spoken, if it was speech.
    public mutating func finish() -> AudioSegment? {
        defer { self = PauseSegmenter() }
        guard inSegment, loudFrames >= Self.minimumSpeechFrames else { return nil }
        return segment(from: segmentStart, to: lastLoud, trailingMargin: true)
    }

    /// RMS of a frame in dBFS (digital silence gives −100).
    public static func level<C: Collection>(_ frame: C) -> Float where C.Element == Float {
        guard !frame.isEmpty else { return -100 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()
        return rms > 0 ? max(-100, 20 * log10(rms)) : -100
    }

    /// whisper.cpp ignores input shorter than a second: short segments get silence appended up to 1.1 s.
    public static func paddedForWhisper(_ samples: [Float]) -> [Float] {
        let minimum = sampleRate + sampleRate / 10
        return samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    // MARK: - Frames

    private mutating func consume(_ samples: ArraySlice<Float>) -> AudioSegment? {
        let n = frame
        frame += 1
        history += samples
        let level = Self.level(samples)
        let floor = noiseFloor(adding: level)
        let start = max(floor + Self.startAboveFloor, Self.quietestStart)
        let keep = start - Self.hysteresis

        guard inSegment else {
            if level >= start {
                inSegment = true
                segmentStart = n
                lastLoud = n
                loudFrames = 1
            } else {
                trimHistory(keepingFramesFrom: n + 1 - Self.marginFrames)
            }
            return nil
        }
        if level >= keep {
            lastLoud = n
            loudFrames += 1
        }
        if n - lastLoud >= Self.pauseFrames {
            inSegment = false
            let closed = loudFrames >= Self.minimumSpeechFrames
                ? segment(from: segmentStart, to: lastLoud, trailingMargin: true) : nil
            trimHistory(keepingFramesFrom: n + 1 - Self.marginFrames)
            return closed
        }
        if n - segmentStart + 1 >= Self.maximumFrames {
            // Cut mid-speech: the next part starts right after, so the transcript keeps it on the same line.
            let closed = segment(from: segmentStart, to: n, trailingMargin: false)
            segmentStart = n + 1
            lastLoud = n
            loudFrames = 0
            trimHistory(keepingFramesFrom: n + 1)
            return closed
        }
        return nil
    }

    /// The quietest of the last 3 s, between −70 and −40 dBFS.
    private mutating func noiseFloor(adding level: Float) -> Float {
        if levels.count < Self.floorWindow {
            levels.append(level)
        } else {
            levels[levelCursor] = level
            levelCursor = (levelCursor + 1) % Self.floorWindow
        }
        return min(-40, max(-70, levels.min() ?? -70))
    }

    private mutating func trimHistory(keepingFramesFrom first: Int) {
        let drop = (max(first, historyStart) - historyStart) * Self.frameLength
        guard drop > 0 else { return }
        history.removeFirst(min(drop, history.count))
        historyStart = max(first, historyStart)
    }

    private func segment(from first: Int, to last: Int, trailingMargin: Bool) -> AudioSegment {
        let from = max(historyStart, first - Self.marginFrames)
        let to = min(frame - 1, last + (trailingMargin ? Self.marginFrames : 0))
        let lower = (from - historyStart) * Self.frameLength
        let upper = min(history.count, (to - historyStart + 1) * Self.frameLength)
        return AudioSegment(samples: lower < upper ? Array(history[lower..<upper]) : [],
                            start: Double(first) * Self.frameSeconds,
                            end: Double(last + 1) * Self.frameSeconds)
    }
}

/// A recognised segment as words for `Transcript`: they share the segment's time span, so a pause between
/// segments starts a new line and the voice commands ("done", "delete last", "next") work as before.
public enum SpeechSegmentText {
    public static func words(_ text: String, start: TimeInterval, end: TimeInterval) -> [SpokenWord] {
        text.split(whereSeparator: \.isWhitespace).map { SpokenWord(String($0), start: start, end: end) }
    }
}

/// Whisper's output for one segment, trimmed. What it writes for silence or noise — its training subtitles'
/// credits and markers like «[BLANK_AUDIO]» — gives nil.
public enum WhisperText {
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols))
        guard !key.isEmpty else { return nil }
        // [BLANK_AUDIO], (music), *noise*: a whole segment in brackets is a sound description, not speech.
        if let first = trimmed.first, let last = trimmed.last, "[(*♪".contains(first), "])*♪".contains(last) { return nil }
        if silencePhrases.contains(key) { return nil }
        if silencePrefixes.contains(where: { key.hasPrefix($0) }) { return nil }
        return trimmed
    }

    private static let silencePhrases: Set<String> = [
        "продолжение следует", "спасибо за просмотр", "спасибо", "thank you", "thanks for watching",
        "thank you for watching", "you", "bye", "до свидания", "субтитры", "music",
    ]

    private static let silencePrefixes = [
        "субтитры сделал", "субтитры создавал", "субтитры подготовил", "редактор субтитров", "корректор",
        "подписывайтесь на канал", "subtitles by", "amara.org",
    ]
}

import AppKit
import AudioToolbox
import AVFoundation
import CLibXMP
import Foundation
import MediaPlayer

// MARK: - Remote catalogue

private struct RadioTrack {
    let title: String
    let artist: String?
    let format: String?
    let downloadURL: URL
    let informationURL: URL?

    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? downloadURL.lastPathComponent : value
    }
}

private enum CatalogueFormat: String {
    case mod = "MOD"
    case xm = "XM"

    var endpoint: URL {
        switch self {
        case .mod: return URL(string: "https://www.stef.be/bassoontracker/api/random")!
        case .xm: return URL(string: "https://www.stef.be/bassoontracker/api/randomxm")!
        }
    }

    static var random: CatalogueFormat { Bool.random() ? .mod : .xm }
}

private enum CatalogueError: Error, LocalizedError {
    case invalidResponse
    case missingTrack
    case invalidDownloadURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "BassoonTracker returned an unreadable response."
        case .missingTrack: return "BassoonTracker did not return a random MOD."
        case .invalidDownloadURL: return "The random MOD did not include a valid download URL."
        }
    }
}

private enum BassoonCatalogue {
    static func parseRandomTrack(from data: Data) throws -> RadioTrack {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let archive = root["modarchive"] as? [String: Any],
              let module = archive["module"] as? [String: Any] else {
            throw CatalogueError.invalidResponse
        }

        guard !module.isEmpty else { throw CatalogueError.missingTrack }
        let rawURL = module["url"] as? String ?? ""
        guard let downloadURL = URL(string: rawURL),
              ["http", "https"].contains(downloadURL.scheme?.lowercased() ?? "") else {
            throw CatalogueError.invalidDownloadURL
        }

        let title = (module["songtitle"] as? String)
            ?? (module["filename"] as? String)
            ?? downloadURL.lastPathComponent
        let format = (module["format"] as? String)?.uppercased()
        let infoURL = (module["infopage"] as? String).flatMap(URL.init(string:))
        var artist: String?
        if let artistInfo = module["artist_info"] as? [String: Any] {
            if let guessed = artistInfo["guessed_artist"] as? [String: Any] {
                artist = guessed["alias"] as? String
            } else if let known = artistInfo["artist"] as? [String: Any] {
                artist = known["alias"] as? String
            }
        }
        if artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { artist = nil }

        return RadioTrack(title: title, artist: artist, format: format, downloadURL: downloadURL,
                          informationURL: infoURL)
    }
}

// MARK: - Tracker module inspection

private enum TrackerPlaybackError: Error, LocalizedError {
    case unsupportedModule
    case decoderUnavailable
    case audioSetupFailed
    case timelineUnavailable
    case transitionUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedModule: return "This tracker file could not be decoded."
        case .decoderUnavailable: return "The tracker replay engine could not start."
        case .audioSetupFailed: return "The Mac audio engine could not start."
        case .timelineUnavailable: return "The track timeline could not be read or seeked."
        case .transitionUnavailable: return "The prefetched track did not start after completion."
        }
    }
}

private struct TrackerModule {
    let data: Data
    let title: String
    let format: String
    fileprivate let fallbackMOD: MODModule?

    init(data: Data) throws {
        var information = xmp_test_info()
        let result = data.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return xmp_test_module_from_memory(baseAddress, data.count, &information)
        }
        guard result == 0 else {
            guard let module = try? MODParser.parse(data) else {
                throw TrackerPlaybackError.unsupportedModule
            }
            self.data = data
            title = module.title
            format = "MOD"
            fallbackMOD = module
            return
        }

        var nameBytes = information.name
        var typeBytes = information.type
        let detectedTitle = Self.string(from: &nameBytes)
        let detectedType = Self.string(from: &typeBytes)
        self.data = data
        title = detectedTitle
        format = Self.shortFormat(for: detectedType, data: data)
        fallbackMOD = nil
    }

    private static func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func shortFormat(for type: String, data: Data) -> String {
        let normalized = type.lowercased()
        if normalized.contains("fast") || normalized.contains("xm") ||
            data.starts(with: Data("Extended Module: ".utf8)) { return "XM" }
        if normalized.contains("protracker") || normalized.contains("mod") { return "MOD" }
        if normalized.contains("scream") || normalized.contains("s3m") { return "S3M" }
        if normalized.contains("impulse") || normalized.contains("it") { return "IT" }
        return type.isEmpty ? "Tracker" : type
    }
}

// MARK: - ProTracker MOD model

private struct MODSample {
    let name: String
    let pcm: [Float]
    let volume: Float
    let fineTune: Int
    let loopStart: Int
    let loopLength: Int

    var hasLoop: Bool {
        loopLength > 2 && loopStart >= 0 && loopStart + loopLength <= pcm.count
    }
}

private struct MODNote {
    let sampleNumber: Int
    let period: Int
    let effect: Int
    let parameter: UInt8
}

private struct MODPattern {
    let events: [MODNote]
}

private struct MODModule {
    let title: String
    let channelCount: Int
    let orders: [Int]
    let patterns: [MODPattern]
    let samples: [MODSample]
}

private enum MODParseError: Error, LocalizedError {
    case truncated
    case unsupportedSignature(String)
    case invalidSong

    var errorDescription: String? {
        switch self {
        case .truncated: return "The module file is incomplete."
        case .unsupportedSignature(let signature):
            return "This first version does not yet support MOD signature \(signature)."
        case .invalidSong: return "The module does not contain a playable song."
        }
    }
}

private enum MODParser {
    static func parse(_ data: Data) throws -> MODModule {
        let bytes = [UInt8](data)
        guard bytes.count >= 1084 else { throw MODParseError.truncated }

        let title = text(bytes, offset: 0, count: 20)
        let signature = text(bytes, offset: 1080, count: 4)
        guard let channelCount = channels(for: signature), channelCount > 0, channelCount <= 32 else {
            throw MODParseError.unsupportedSignature(signature.isEmpty ? "unknown" : signature)
        }

        struct Header {
            let name: String
            let length: Int
            let fineTune: Int
            let volume: Float
            let loopStart: Int
            let loopLength: Int
        }

        var headers: [Header] = []
        for index in 0..<31 {
            let offset = 20 + index * 30
            guard offset + 30 <= bytes.count else { throw MODParseError.truncated }
            let rawFineTune = Int(bytes[offset + 24] & 0x0F)
            let signedFineTune = rawFineTune > 7 ? rawFineTune - 16 : rawFineTune
            headers.append(Header(
                name: text(bytes, offset: offset, count: 22),
                length: word(bytes, offset + 22) * 2,
                fineTune: signedFineTune,
                volume: Float(min(bytes[offset + 25], 64)) / 64,
                loopStart: word(bytes, offset + 26) * 2,
                loopLength: word(bytes, offset + 28) * 2
            ))
        }

        let songLength = Int(bytes[950])
        guard songLength > 0 && songLength <= 128 else { throw MODParseError.invalidSong }
        let orders = bytes[952..<(952 + songLength)].map(Int.init)
        guard let highestPattern = orders.max() else { throw MODParseError.invalidSong }
        let patternCount = highestPattern + 1
        let patternByteCount = patternCount * 64 * channelCount * 4
        let sampleDataOffset = 1084 + patternByteCount
        guard sampleDataOffset <= bytes.count else { throw MODParseError.truncated }

        var patterns: [MODPattern] = []
        patterns.reserveCapacity(patternCount)
        for patternIndex in 0..<patternCount {
            var events: [MODNote] = []
            events.reserveCapacity(64 * channelCount)
            var offset = 1084 + patternIndex * 64 * channelCount * 4
            for _ in 0..<(64 * channelCount) {
                guard offset + 4 <= bytes.count else { throw MODParseError.truncated }
                let first = bytes[offset]
                let second = bytes[offset + 1]
                let third = bytes[offset + 2]
                let fourth = bytes[offset + 3]
                let sampleNumber = Int(first & 0xF0) | Int(third >> 4)
                let period = (Int(first & 0x0F) << 8) | Int(second)
                events.append(MODNote(sampleNumber: sampleNumber, period: period,
                                      effect: Int(third & 0x0F), parameter: fourth))
                offset += 4
            }
            patterns.append(MODPattern(events: events))
        }

        var samples: [MODSample] = []
        samples.reserveCapacity(31)
        var cursor = sampleDataOffset
        for header in headers {
            guard cursor + header.length <= bytes.count else { throw MODParseError.truncated }
            let pcm = bytes[cursor..<(cursor + header.length)].map {
                Float(Int8(bitPattern: $0)) / 128
            }
            samples.append(MODSample(name: header.name, pcm: pcm, volume: header.volume,
                                     fineTune: header.fineTune, loopStart: header.loopStart,
                                     loopLength: header.loopLength))
            cursor += header.length
        }

        return MODModule(title: title, channelCount: channelCount, orders: orders,
                         patterns: patterns, samples: samples)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func text(_ bytes: [UInt8], offset: Int, count: Int) -> String {
        guard offset >= 0 && offset + count <= bytes.count else { return "" }
        let content = bytes[offset..<(offset + count)].prefix { $0 != 0 }
        return String(bytes: content, encoding: .isoLatin1)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func channels(for signature: String) -> Int? {
        if ["M.K.", "M!K!", "M&K!", "N.T.", "FLT4", "4CHN"].contains(signature) { return 4 }
        if signature.hasSuffix("CHN"), let value = Int(signature.dropLast(3)) { return value }
        if signature.hasSuffix("CH"), let value = Int(signature.dropLast(2)) { return value }
        return nil
    }
}

// MARK: - Minimal native MOD replay engine

private struct PlaybackProgress {
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let canSeek: Bool
}

private final class MODChannel {
    var sampleIndex = -1
    var samplePosition = 0.0
    var basePeriod = 0.0
    var currentPeriod = 0.0
    var targetPeriod = 0.0
    var volume: Float = 0
    var active = false
    var effect = 0
    var parameter: UInt8 = 0
    var effectMemory = Array(repeating: UInt8(0), count: 16)
    var vibratoPhase = 0.0
    var loopRow = 0
    var loopCount = 0
    var delayedNote: MODNote?
}

private final class MODRenderer: @unchecked Sendable {
    private let module: MODModule
    private let sampleRate: Double
    private let onFinish: () -> Void
    private let amigaClock = 3_546_895.0
    private var channels: [MODChannel]
    private var songPosition = 0
    private var row = 0
    private var tick = 0
    private var speed = 6
    private var bpm = 125
    private var framesRemainingInTick = 0
    private var totalFrames = 0
    private var pendingPositionJump: Int?
    private var pendingBreakRow: Int?
    private var pendingLoopRow: Int?
    private var positionVisits: [Int]
    private var ended = false
    private var finishSent = false
    private let lock = NSLock()

    init(module: MODModule, sampleRate: Double, onFinish: @escaping () -> Void) {
        self.module = module
        self.sampleRate = sampleRate
        self.onFinish = onFinish
        channels = (0..<module.channelCount).map { _ in MODChannel() }
        positionVisits = Array(repeating: 0, count: module.orders.count)
        if !positionVisits.isEmpty { positionVisits[0] = 1 }
    }

    func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        for frame in 0..<frameCount {
            if framesRemainingInTick <= 0 && !ended { prepareNextTick() }
            guard !ended else {
                left[frame] = 0
                right[frame] = 0
                sendFinishOnce()
                continue
            }

            var leftMix: Float = 0
            var rightMix: Float = 0
            for (index, channel) in channels.enumerated() where channel.active {
                guard channel.sampleIndex >= 0 && channel.sampleIndex < module.samples.count,
                      channel.currentPeriod > 0 else { continue }
                let sample = module.samples[channel.sampleIndex]
                guard !sample.pcm.isEmpty else { channel.active = false; continue }

                normalizePosition(channel, sample: sample)
                guard channel.active else { continue }
                let sampleIndex = Int(channel.samplePosition)
                guard sampleIndex >= 0 && sampleIndex < sample.pcm.count else {
                    channel.active = false
                    continue
                }

                let value = sample.pcm[sampleIndex] * channel.volume
                let leftChannel = index % 4 == 0 || index % 4 == 3
                if leftChannel {
                    leftMix += value * 0.82
                    rightMix += value * 0.18
                } else {
                    leftMix += value * 0.18
                    rightMix += value * 0.82
                }

                let fineTuneRatio = pow(2.0, Double(sample.fineTune) / 96.0)
                channel.samplePosition += (amigaClock / channel.currentPeriod) * fineTuneRatio / sampleRate
            }

            let scale = Float(1.15 / sqrt(Double(max(2, module.channelCount))))
            left[frame] = max(-1, min(1, leftMix * scale))
            right[frame] = max(-1, min(1, rightMix * scale))
            framesRemainingInTick -= 1
            totalFrames += 1
            if totalFrames >= Int(sampleRate * 60 * 12) { ended = true }
        }
    }

    func progress() -> PlaybackProgress {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackProgress(
            elapsed: Double(totalFrames) / sampleRate,
            duration: nil,
            canSeek: false
        )
    }

    private func normalizePosition(_ channel: MODChannel, sample: MODSample) {
        guard channel.samplePosition >= Double(sample.pcm.count) else { return }
        if sample.hasLoop {
            let end = sample.loopStart + sample.loopLength
            while channel.samplePosition >= Double(end) {
                channel.samplePosition -= Double(sample.loopLength)
            }
            if channel.samplePosition < Double(sample.loopStart) {
                channel.samplePosition = Double(sample.loopStart)
            }
        } else {
            channel.active = false
        }
    }

    private func prepareNextTick() {
        if tick >= speed {
            tick = 0
            advanceRow()
            if ended { return }
        }

        if tick == 0 { processRow() } else { processEffects() }
        framesRemainingInTick = max(1, Int((sampleRate * 2.5 / Double(max(32, bpm))).rounded()))
        tick += 1
    }

    private func processRow() {
        guard songPosition >= 0 && songPosition < module.orders.count else { ended = true; return }
        let patternIndex = module.orders[songPosition]
        guard patternIndex >= 0 && patternIndex < module.patterns.count else { ended = true; return }
        let pattern = module.patterns[patternIndex]
        let start = row * module.channelCount
        guard start + module.channelCount <= pattern.events.count else { ended = true; return }

        pendingPositionJump = nil
        pendingBreakRow = nil
        pendingLoopRow = nil

        for index in 0..<module.channelCount {
            let event = pattern.events[start + index]
            let channel = channels[index]
            channel.effect = event.effect
            if event.parameter != 0 { channel.effectMemory[event.effect] = event.parameter }
            channel.parameter = event.parameter == 0 ? channel.effectMemory[event.effect] : event.parameter
            channel.currentPeriod = channel.basePeriod
            channel.delayedNote = nil

            let extendedCommand = event.effect == 0xE ? Int(event.parameter >> 4) : -1
            if extendedCommand == 0xD {
                channel.delayedNote = event
                if event.sampleNumber > 0 { selectSample(event.sampleNumber, for: channel) }
            } else {
                applyNote(event, to: channel)
            }

            switch event.effect {
            case 0x9:
                if event.period > 0 || event.sampleNumber > 0 {
                    channel.samplePosition = Double(Int(channel.parameter) * 256)
                }
            case 0xB:
                pendingPositionJump = Int(event.parameter)
            case 0xC:
                channel.volume = Float(min(event.parameter, 64)) / 64
            case 0xD:
                pendingBreakRow = min(63, Int(event.parameter >> 4) * 10 + Int(event.parameter & 0x0F))
            case 0xE:
                processExtendedAtRow(event.parameter, channel: channel)
            case 0xF:
                let value = Int(event.parameter)
                if value == 0 { ended = true }
                else if value < 32 { speed = max(1, value) }
                else { bpm = value }
            default:
                break
            }
        }
    }

    private func selectSample(_ sampleNumber: Int, for channel: MODChannel) {
        let index = sampleNumber - 1
        guard index >= 0 && index < module.samples.count else { return }
        channel.sampleIndex = index
        channel.volume = module.samples[index].volume
    }

    private func applyNote(_ note: MODNote, to channel: MODChannel) {
        if note.sampleNumber > 0 { selectSample(note.sampleNumber, for: channel) }
        guard note.period > 0 else { return }
        if note.effect == 0x3 || note.effect == 0x5 {
            channel.targetPeriod = Double(note.period)
            if channel.basePeriod <= 0 { trigger(note, on: channel) }
        } else {
            trigger(note, on: channel)
        }
    }

    private func trigger(_ note: MODNote, on channel: MODChannel) {
        guard note.period > 0 else { return }
        channel.basePeriod = Double(note.period)
        channel.currentPeriod = Double(note.period)
        channel.samplePosition = 0
        channel.active = channel.sampleIndex >= 0
    }

    private func processExtendedAtRow(_ parameter: UInt8, channel: MODChannel) {
        let command = Int(parameter >> 4)
        let value = Int(parameter & 0x0F)
        switch command {
        case 0x1:
            channel.basePeriod = max(56, channel.basePeriod - Double(value))
            channel.currentPeriod = channel.basePeriod
        case 0x2:
            channel.basePeriod = min(1712, channel.basePeriod + Double(value))
            channel.currentPeriod = channel.basePeriod
        case 0x6:
            if value == 0 {
                channel.loopRow = row
            } else if channel.loopCount == 0 {
                channel.loopCount = value
                pendingLoopRow = channel.loopRow
            } else {
                channel.loopCount -= 1
                if channel.loopCount > 0 { pendingLoopRow = channel.loopRow }
            }
        case 0xA:
            channel.volume = min(1, channel.volume + Float(value) / 64)
        case 0xB:
            channel.volume = max(0, channel.volume - Float(value) / 64)
        default:
            break
        }
    }

    private func processEffects() {
        for channel in channels {
            channel.currentPeriod = channel.basePeriod
            let parameter = channel.parameter
            switch channel.effect {
            case 0x0:
                let phase = tick % 3
                let semitones = phase == 1 ? Int(parameter >> 4) : phase == 2 ? Int(parameter & 0x0F) : 0
                if semitones > 0 && channel.basePeriod > 0 {
                    channel.currentPeriod = channel.basePeriod / pow(2, Double(semitones) / 12)
                }
            case 0x1:
                channel.basePeriod = max(56, channel.basePeriod - Double(parameter))
                channel.currentPeriod = channel.basePeriod
            case 0x2:
                channel.basePeriod = min(1712, channel.basePeriod + Double(parameter))
                channel.currentPeriod = channel.basePeriod
            case 0x3:
                tonePortamento(channel, amount: Int(parameter))
            case 0x4:
                vibrato(channel, parameter: parameter)
            case 0x5:
                tonePortamento(channel, amount: Int(channel.effectMemory[0x3]))
                volumeSlide(channel, parameter: parameter)
            case 0x6:
                vibrato(channel, parameter: channel.effectMemory[0x4])
                volumeSlide(channel, parameter: parameter)
            case 0xA:
                volumeSlide(channel, parameter: parameter)
            case 0xE:
                processExtendedAtTick(parameter, channel: channel)
            default:
                break
            }
        }
    }

    private func tonePortamento(_ channel: MODChannel, amount: Int) {
        let step = Double(amount)
        guard step > 0 && channel.targetPeriod > 0 else { return }
        if channel.basePeriod < channel.targetPeriod {
            channel.basePeriod = min(channel.targetPeriod, channel.basePeriod + step)
        } else if channel.basePeriod > channel.targetPeriod {
            channel.basePeriod = max(channel.targetPeriod, channel.basePeriod - step)
        }
        channel.currentPeriod = channel.basePeriod
    }

    private func vibrato(_ channel: MODChannel, parameter: UInt8) {
        let speed = Double(parameter >> 4)
        let depth = Double(parameter & 0x0F)
        channel.vibratoPhase += speed * .pi / 32
        channel.currentPeriod = max(56, channel.basePeriod + sin(channel.vibratoPhase) * depth * 2)
    }

    private func volumeSlide(_ channel: MODChannel, parameter: UInt8) {
        let up = Float(parameter >> 4) / 64
        let down = Float(parameter & 0x0F) / 64
        channel.volume = max(0, min(1, channel.volume + up - down))
    }

    private func processExtendedAtTick(_ parameter: UInt8, channel: MODChannel) {
        let command = Int(parameter >> 4)
        let value = Int(parameter & 0x0F)
        switch command {
        case 0x9 where value > 0 && tick % value == 0:
            channel.samplePosition = 0
            channel.active = channel.sampleIndex >= 0
        case 0xC where tick == value:
            channel.volume = 0
        case 0xD where tick == value:
            if let delayed = channel.delayedNote { trigger(delayed, on: channel) }
        default:
            break
        }
    }

    private func advanceRow() {
        if let loopRow = pendingLoopRow {
            row = max(0, min(63, loopRow))
            return
        }

        if pendingPositionJump != nil || pendingBreakRow != nil {
            songPosition = pendingPositionJump ?? (songPosition + 1)
            row = pendingBreakRow ?? 0
        } else {
            row += 1
            if row >= 64 {
                row = 0
                songPosition += 1
            }
        }

        guard songPosition >= 0 && songPosition < module.orders.count else { ended = true; return }
        if row == 0 || pendingPositionJump != nil || pendingBreakRow != nil {
            positionVisits[songPosition] += 1
            if positionVisits[songPosition] > 1 { ended = true }
        }
    }

    private func sendFinishOnce() {
        guard !finishSent else { return }
        finishSent = true
        DispatchQueue.main.async { [onFinish] in onFinish() }
    }
}

private final class MODAudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var renderer: MODRenderer?
    private var playbackToken = UUID()
    private var outputVolume: Float = 0.8
    private(set) var isPaused = false

    func play(_ module: MODModule, onFinish: @escaping () -> Void) throws {
        stop()
        let token = UUID()
        playbackToken = token
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let renderer = MODRenderer(module: module, sampleRate: format.sampleRate) { [weak self] in
            guard let self, self.playbackToken == token else { return }
            onFinish()
        }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            renderer.render(frameCount: Int(frameCount), left: left, right: right)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = outputVolume
        engine.prepare()
        try engine.start()
        self.renderer = renderer
        sourceNode = source
        isPaused = false
    }

    func setVolume(_ value: Float) {
        outputVolume = max(0, min(1, value))
        engine.mainMixerNode.outputVolume = outputVolume
    }

    func progress() -> PlaybackProgress? { renderer?.progress() }

    func pause() {
        guard engine.isRunning else { return }
        engine.pause()
        isPaused = true
    }

    func resume() throws {
        guard isPaused else { return }
        try engine.start()
        isPaused = false
    }

    func stop() {
        playbackToken = UUID()
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        renderer = nil
        isPaused = false
    }
}

// MARK: - Multi-format tracker replay

private final class XMPRenderer: @unchecked Sendable {
    private let context: xmp_context
    private let onFinish: () -> Void
    private var samples = Array(repeating: Int16(0), count: 131_072)
    private var ended = false
    private var finishSent = false
    private let lock = NSLock()

    init(module: TrackerModule, onFinish: @escaping () -> Void) throws {
        guard let context = xmp_create_context() else {
            throw TrackerPlaybackError.decoderUnavailable
        }
        self.context = context
        self.onFinish = onFinish

        _ = xmp_set_player(context, XMP_PLAYER_DEFPAN, 50)
        let loadResult = module.data.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return xmp_load_module_from_memory(context, baseAddress, module.data.count)
        }
        guard loadResult == 0 else {
            xmp_free_context(context)
            throw TrackerPlaybackError.unsupportedModule
        }
        guard xmp_start_player(context, 48_000, 0) == 0 else {
            xmp_release_module(context)
            xmp_free_context(context)
            throw TrackerPlaybackError.decoderUnavailable
        }
    }

    deinit {
        xmp_end_player(context)
        xmp_release_module(context)
        xmp_free_context(context)
    }

    func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, frameCount > 0, frameCount * 2 <= samples.count else {
            clear(frameCount: frameCount, left: left, right: right)
            sendFinishOnce()
            return
        }

        let byteCount = frameCount * 2 * MemoryLayout<Int16>.size
        let result = samples.withUnsafeMutableBytes { buffer -> Int32 in
            xmp_play_buffer(context, buffer.baseAddress, Int32(byteCount), 1)
        }
        for frame in 0..<frameCount {
            left[frame] = Float(samples[frame * 2]) / 32_768
            right[frame] = Float(samples[frame * 2 + 1]) / 32_768
        }
        if result != 0 {
            ended = true
            sendFinishOnce()
        }
    }

    func progress() -> PlaybackProgress {
        lock.lock()
        defer { lock.unlock() }
        var information = xmp_frame_info()
        xmp_get_frame_info(context, &information)
        let elapsed = TimeInterval(max(0, information.time)) / 1_000
        let durationMilliseconds = max(0, information.total_time)
        let duration = durationMilliseconds > 0
            ? TimeInterval(durationMilliseconds) / 1_000
            : nil
        return PlaybackProgress(
            elapsed: duration.map { min(elapsed, $0) } ?? elapsed,
            duration: duration,
            canSeek: duration != nil
        )
    }

    func seek(to seconds: TimeInterval, precise: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        var information = xmp_frame_info()
        xmp_get_frame_info(context, &information)
        guard information.total_time > 0 else { return }
        let milliseconds = min(
            max(0, Int(seconds * 1_000)),
            max(0, Int(information.total_time) - 1)
        )
        let result = precise
            ? xmp_seek_time_frame(context, Int32(milliseconds))
            : xmp_seek_time(context, Int32(milliseconds))
        if result >= 0 {
            ended = false
            finishSent = false
        }
    }

    private func clear(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for frame in 0..<frameCount {
            left[frame] = 0
            right[frame] = 0
        }
    }

    private func sendFinishOnce() {
        guard !finishSent else { return }
        finishSent = true
        DispatchQueue.main.async { [onFinish] in onFinish() }
    }
}

private final class TrackerAudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var renderer: XMPRenderer?
    private var playbackToken = UUID()
    private var outputVolume: Float = 0.8
    private(set) var isPaused = false

    func play(_ module: TrackerModule, onFinish: @escaping () -> Void) throws {
        stop()
        let token = UUID()
        playbackToken = token
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let renderer = try XMPRenderer(module: module) { [weak self] in
            guard let self, self.playbackToken == token else { return }
            onFinish()
        }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            renderer.render(frameCount: Int(frameCount), left: left, right: right)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = outputVolume
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
            throw TrackerPlaybackError.audioSetupFailed
        }
        self.renderer = renderer
        sourceNode = source
        isPaused = false
    }

    func setVolume(_ value: Float) {
        outputVolume = max(0, min(1, value))
        engine.mainMixerNode.outputVolume = outputVolume
    }

    func progress() -> PlaybackProgress? { renderer?.progress() }

    func seek(to seconds: TimeInterval, precise: Bool = false) {
        renderer?.seek(to: seconds, precise: precise)
    }

    func pause() {
        guard engine.isRunning else { return }
        engine.pause()
        isPaused = true
    }

    func resume() throws {
        guard isPaused else { return }
        try engine.start()
        isPaused = false
    }

    func stop() {
        playbackToken = UUID()
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        renderer = nil
        isPaused = false
    }
}

private final class UniversalTrackerAudioPlayer {
    private enum Backend {
        case xmp
        case nativeMOD
    }

    private let xmpPlayer = TrackerAudioPlayer()
    private let modPlayer = MODAudioPlayer()
    private var backend: Backend?
    private(set) var volume: Float = 0.8

    func play(_ module: TrackerModule, onFinish: @escaping () -> Void) throws {
        stop()
        if let fallback = module.fallbackMOD {
            try modPlayer.play(fallback, onFinish: onFinish)
            backend = .nativeMOD
        } else {
            try xmpPlayer.play(module, onFinish: onFinish)
            backend = .xmp
        }
    }

    func pause() {
        switch backend {
        case .xmp: xmpPlayer.pause()
        case .nativeMOD: modPlayer.pause()
        case nil: break
        }
    }

    func resume() throws {
        switch backend {
        case .xmp: try xmpPlayer.resume()
        case .nativeMOD: try modPlayer.resume()
        case nil: break
        }
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        xmpPlayer.setVolume(volume)
        modPlayer.setVolume(volume)
    }

    func progress() -> PlaybackProgress? {
        switch backend {
        case .xmp: return xmpPlayer.progress()
        case .nativeMOD: return modPlayer.progress()
        case nil: return nil
        }
    }

    func seek(to seconds: TimeInterval, precise: Bool = false) {
        if case .xmp = backend { xmpPlayer.seek(to: seconds, precise: precise) }
    }

    func stop() {
        xmpPlayer.stop()
        modPlayer.stop()
        backend = nil
    }
}

// MARK: - Radio state

private enum RadioPhase: Equatable {
    case stopped
    case loading
    case playing
    case paused
    case failed(String)
}

private struct PreparedTrack {
    let track: RadioTrack
    let module: TrackerModule
}

private final class RadioController {
    private static let volumeDefaultsKey = "playbackVolume"

    var onChange: (() -> Void)?
    private(set) var phase: RadioPhase = .stopped { didSet { onChange?() } }
    private(set) var track: RadioTrack? { didSet { onChange?() } }
    private let audioPlayer = UniversalTrackerAudioPlayer()
    private let session: URLSession
    private var task: URLSessionDataTask?
    private var prefetchTask: URLSessionDataTask?
    private var prefetchedTrack: PreparedTrack?
    private var playbackGeneration = UUID()
    private var waitingForPrefetch = false
    private var stationIsOn = false
    private var unsupportedSkips = 0
    private var prefetchFailures = 0
    private var nextFormat = CatalogueFormat.random

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "ModRadio/0.1 macOS"]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
        let savedVolume = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Double
        audioPlayer.setVolume(Float(savedVolume ?? 0.8))
    }

    var volume: Float { audioPlayer.volume }

    var playbackProgress: PlaybackProgress? { audioPlayer.progress() }

    var hasPrefetchedTrack: Bool { prefetchedTrack != nil }

    func setVolume(_ value: Float) {
        audioPlayer.setVolume(value)
        UserDefaults.standard.set(Double(audioPlayer.volume), forKey: Self.volumeDefaultsKey)
    }

    func seek(to seconds: TimeInterval, precise: Bool = false) {
        audioPlayer.seek(to: seconds, precise: precise)
    }

    func playRandom() {
        stationIsOn = true
        unsupportedSkips = 0
        beginNewGeneration(with: nil)
    }

    func playAnother() {
        stationIsOn = true
        unsupportedSkips = 0
        let prepared = prefetchedTrack
        beginNewGeneration(with: prepared)
    }

    func playForVerification(track: RadioTrack, module: TrackerModule) {
        stationIsOn = true
        playbackGeneration = UUID()
        let generation = playbackGeneration
        task?.cancel()
        prefetchTask?.cancel()
        task = nil
        prefetchTask = nil
        prefetchedTrack = nil
        waitingForPrefetch = false
        audioPlayer.stop()
        startPlayback(PreparedTrack(track: track, module: module),
                      generation: generation, shouldPrefetch: false)
    }

    func togglePause() {
        switch phase {
        case .playing:
            audioPlayer.pause()
            phase = .paused
        case .paused:
            do {
                try audioPlayer.resume()
                phase = .playing
            } catch {
                phase = .failed("Audio could not resume.")
            }
        default:
            break
        }
    }

    func stop() {
        stationIsOn = false
        playbackGeneration = UUID()
        task?.cancel()
        prefetchTask?.cancel()
        task = nil
        prefetchTask = nil
        prefetchedTrack = nil
        waitingForPrefetch = false
        audioPlayer.stop()
        phase = .stopped
    }

    private func beginNewGeneration(with prepared: PreparedTrack?) {
        playbackGeneration = UUID()
        let generation = playbackGeneration
        task?.cancel()
        prefetchTask?.cancel()
        task = nil
        prefetchTask = nil
        prefetchedTrack = nil
        waitingForPrefetch = false
        prefetchFailures = 0
        audioPlayer.stop()
        if let prepared {
            startPlayback(prepared, generation: generation)
        } else {
            loadRandomTrack(generation: generation)
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        stationIsOn && playbackGeneration == generation
    }

    private func loadRandomTrack(generation: UUID) {
        guard isCurrent(generation) else { return }
        task?.cancel()
        audioPlayer.stop()
        phase = .loading

        let requestedFormat = nextFormat
        nextFormat = requestedFormat == .mod ? .xm : .mod
        task = session.dataTask(with: requestedFormat.endpoint) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error as? URLError, error.code == .cancelled { return }
            guard error == nil, let data else {
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.task = nil
                    self.phase = .failed("Couldn’t reach BassoonTracker.")
                }
                return
            }

            do {
                let track = try BassoonCatalogue.parseRandomTrack(from: data)
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.download(track, generation: generation)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.task = nil
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
        task?.resume()
    }

    private func download(_ track: RadioTrack, generation: UUID) {
        guard isCurrent(generation) else { return }
        task = session.dataTask(with: track.downloadURL) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error as? URLError, error.code == .cancelled { return }
            guard error == nil, let data else {
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.task = nil
                    self.phase = .failed("The tracker module could not be downloaded.")
                }
                return
            }

            do {
                let module = try TrackerModule(data: data)
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.task = nil
                    self.startPlayback(PreparedTrack(track: track, module: module),
                                       generation: generation)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.task = nil
                    if self.unsupportedSkips < 3 {
                        self.unsupportedSkips += 1
                        self.phase = .loading
                        self.loadRandomTrack(generation: generation)
                    } else {
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
        task?.resume()
    }

    private func startPlayback(_ prepared: PreparedTrack, generation: UUID,
                               shouldPrefetch: Bool = true) {
        guard isCurrent(generation) else { return }
        waitingForPrefetch = false
        track = RadioTrack(
            title: prepared.module.title.isEmpty ? prepared.track.displayTitle : prepared.module.title,
            artist: prepared.track.artist,
            format: prepared.module.format,
            downloadURL: prepared.track.downloadURL,
            informationURL: prepared.track.informationURL
        )
        do {
            try audioPlayer.play(prepared.module) { [weak self] in
                guard let self else { return }
                self.advanceAfterFinish(generation: generation)
            }
            unsupportedSkips = 0
            prefetchFailures = 0
            phase = .playing
            if shouldPrefetch { prefetchNextTrack(generation: generation) }
        } catch {
            phase = .failed("The Mac audio engine could not start.")
        }
    }

    private func advanceAfterFinish(generation: UUID) {
        guard isCurrent(generation) else { return }
        if let prepared = prefetchedTrack {
            prefetchedTrack = nil
            startPlayback(prepared, generation: generation)
        } else if prefetchTask != nil {
            waitingForPrefetch = true
            audioPlayer.stop()
            phase = .loading
        } else {
            loadRandomTrack(generation: generation)
        }
    }

    private func prefetchNextTrack(generation: UUID) {
        guard isCurrent(generation) else { return }
        prefetchTask?.cancel()
        prefetchedTrack = nil

        let requestedFormat = nextFormat
        nextFormat = requestedFormat == .mod ? .xm : .mod
        let catalogueTask = session.dataTask(with: requestedFormat.endpoint) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error as? URLError, error.code == .cancelled { return }
            guard error == nil, let data else {
                DispatchQueue.main.async { self.prefetchFailed(generation: generation) }
                return
            }
            do {
                let track = try BassoonCatalogue.parseRandomTrack(from: data)
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.downloadPrefetched(track, generation: generation)
                }
            } catch {
                DispatchQueue.main.async { self.prefetchFailed(generation: generation) }
            }
        }
        prefetchTask = catalogueTask
        catalogueTask.resume()
    }

    private func downloadPrefetched(_ track: RadioTrack, generation: UUID) {
        guard isCurrent(generation) else { return }
        let downloadTask = session.dataTask(with: track.downloadURL) { [weak self] data, _, error in
            guard let self else { return }
            if let error = error as? URLError, error.code == .cancelled { return }
            guard error == nil, let data else {
                DispatchQueue.main.async { self.prefetchFailed(generation: generation) }
                return
            }
            do {
                let module = try TrackerModule(data: data)
                let prepared = PreparedTrack(track: track, module: module)
                DispatchQueue.main.async {
                    guard self.isCurrent(generation) else { return }
                    self.prefetchTask = nil
                    self.prefetchFailures = 0
                    if self.waitingForPrefetch {
                        self.startPlayback(prepared, generation: generation)
                    } else {
                        self.prefetchedTrack = prepared
                    }
                }
            } catch {
                DispatchQueue.main.async { self.prefetchFailed(generation: generation) }
            }
        }
        prefetchTask = downloadTask
        downloadTask.resume()
    }

    private func prefetchFailed(generation: UUID) {
        guard isCurrent(generation) else { return }
        prefetchTask = nil
        if prefetchFailures < 3 {
            prefetchFailures += 1
            prefetchNextTrack(generation: generation)
        } else if waitingForPrefetch {
            waitingForPrefetch = false
            loadRandomTrack(generation: generation)
        }
    }
}

// MARK: - macOS Now Playing and media keys

private final class SystemMediaController: NSObject {
    private weak var radio: RadioController?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let informationCenter = MPNowPlayingInfoCenter.default()
    private var isRegistered = false

    init(radio: RadioController) {
        self.radio = radio
        super.init()
        registerCommands()
        update()
    }

    deinit { invalidate() }

    func update() {
        guard let radio else { return }
        updateCommandAvailability(for: radio)

        guard let track = radio.track, radio.phase != .stopped else {
            informationCenter.nowPlayingInfo = nil
            informationCenter.playbackState = .stopped
            return
        }

        let progress = radio.playbackProgress
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyAlbumTitle: "ModRadio",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress?.elapsed ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: radio.phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.downloadURL.absoluteString,
            MPNowPlayingInfoPropertyServiceIdentifier: "com.pdparchitect.modradio"
        ]
        if let artist = track.artist { information[MPMediaItemPropertyArtist] = artist }
        if let format = track.format { information[MPMediaItemPropertyGenre] = "\(format) tracker music" }
        if let duration = progress?.duration { information[MPMediaItemPropertyPlaybackDuration] = duration }
        informationCenter.nowPlayingInfo = information

        switch radio.phase {
        case .playing: informationCenter.playbackState = .playing
        case .paused: informationCenter.playbackState = .paused
        default: informationCenter.playbackState = .stopped
        }
    }

    func invalidate() {
        guard isRegistered else { return }
        for command in registeredCommands { command.removeTarget(self) }
        isRegistered = false
        informationCenter.nowPlayingInfo = nil
        informationCenter.playbackState = .stopped
    }

    private var registeredCommands: [MPRemoteCommand] {
        [commandCenter.playCommand, commandCenter.pauseCommand,
         commandCenter.togglePlayPauseCommand, commandCenter.stopCommand,
         commandCenter.nextTrackCommand, commandCenter.previousTrackCommand,
         commandCenter.skipForwardCommand, commandCenter.skipBackwardCommand,
         commandCenter.changePlaybackPositionCommand]
    }

    private func registerCommands() {
        guard !isRegistered else { return }
        commandCenter.playCommand.addTarget(self, action: #selector(handlePlay(_:)))
        commandCenter.pauseCommand.addTarget(self, action: #selector(handlePause(_:)))
        commandCenter.togglePlayPauseCommand.addTarget(self, action: #selector(handleToggle(_:)))
        commandCenter.stopCommand.addTarget(self, action: #selector(handleStop(_:)))
        commandCenter.nextTrackCommand.addTarget(self, action: #selector(handleNext(_:)))
        commandCenter.previousTrackCommand.addTarget(self, action: #selector(handlePrevious(_:)))
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget(self, action: #selector(handleSkipForward(_:)))
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget(self, action: #selector(handleSkipBackward(_:)))
        commandCenter.changePlaybackPositionCommand.addTarget(
            self, action: #selector(handlePositionChange(_:)))

        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
        isRegistered = true
    }

    private func updateCommandAvailability(for radio: RadioController) {
        let isPlaying = radio.phase == .playing
        let isPaused = radio.phase == .paused
        let isActive = isPlaying || isPaused
        let canSeek = isActive && (radio.playbackProgress?.canSeek == true)
        commandCenter.playCommand.isEnabled = !isPlaying && radio.phase != .loading
        commandCenter.pauseCommand.isEnabled = isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = radio.phase != .loading
        commandCenter.stopCommand.isEnabled = isActive || radio.phase == .loading
        commandCenter.nextTrackCommand.isEnabled = isActive || radio.phase == .loading
        commandCenter.previousTrackCommand.isEnabled = canSeek
        commandCenter.skipForwardCommand.isEnabled = canSeek
        commandCenter.skipBackwardCommand.isEnabled = canSeek
        commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
    }

    private func actionableRadio() -> RadioController? {
        guard let radio else { return nil }
        return radio
    }

    @objc private func handlePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio() else { return .noActionableNowPlayingItem }
        switch radio.phase {
        case .paused: radio.togglePause()
        case .stopped, .failed: radio.playAnother()
        case .playing: break
        case .loading: return .commandFailed
        }
        update()
        return .success
    }

    @objc private func handlePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio(), radio.phase == .playing else {
            return .noActionableNowPlayingItem
        }
        radio.togglePause()
        update()
        return .success
    }

    @objc private func handleToggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio() else { return .noActionableNowPlayingItem }
        switch radio.phase {
        case .playing, .paused: radio.togglePause()
        case .stopped, .failed: radio.playAnother()
        case .loading: return .commandFailed
        }
        update()
        return .success
    }

    @objc private func handleStop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio() else { return .noActionableNowPlayingItem }
        radio.stop()
        update()
        return .success
    }

    @objc private func handleNext(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio() else { return .noActionableNowPlayingItem }
        radio.playAnother()
        update()
        return .success
    }

    @objc private func handlePrevious(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio(), radio.playbackProgress?.canSeek == true else {
            return .noSuchContent
        }
        radio.seek(to: 0, precise: true)
        update()
        return .success
    }

    @objc private func handleSkipForward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        seek(by: event.interval)
    }

    @objc private func handleSkipBackward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        seek(by: -event.interval)
    }

    @objc private func handlePositionChange(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio(), let progress = radio.playbackProgress,
              progress.canSeek else { return .noSuchContent }
        let target = min(max(0, event.positionTime), progress.duration ?? event.positionTime)
        radio.seek(to: target)
        update()
        return .success
    }

    private func seek(by interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let radio = actionableRadio(), let progress = radio.playbackProgress,
              progress.canSeek else { return .noSuchContent }
        let target = min(max(0, progress.elapsed + interval), progress.duration ?? .greatestFiniteMagnitude)
        radio.seek(to: target)
        update()
        return .success
    }
}

// MARK: - Menu bar application

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let updater = AppUpdater()
    private let radio = RadioController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let titleItem = NSMenuItem(title: "MOD Radio", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "Ready for a random module", action: nil, keyEquivalent: "")
    private let progressItem = NSMenuItem()
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "—")
    private let playItem = NSMenuItem(title: "Play Random MOD or XM", action: #selector(playRandom), keyEquivalent: "r")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: " ")
    private let stopItem = NSMenuItem(title: "Stop Radio", action: #selector(stopRadio), keyEquivalent: ".")
    private let volumeItem = NSMenuItem()
    private let volumeSlider = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeImageView = NSImageView()
    private let bassoonItem = NSMenuItem(title: "Open in BassoonTracker", action: #selector(openInBassoon), keyEquivalent: "")
    private let informationItem = NSMenuItem(title: "View Module Page", action: #selector(openInformation), keyEquivalent: "")
    private var progressTimer: Timer?
    private var systemMedia: SystemMediaController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "MOD Radio"
        statusItem.menu = menu
        menu.delegate = self

        titleItem.isEnabled = false
        detailItem.isEnabled = false
        configureProgressItem()
        configureVolumeItem()
        for item in [titleItem, detailItem, progressItem, NSMenuItem.separator(), playItem, pauseItem, stopItem,
                     NSMenuItem.separator(), volumeItem, NSMenuItem.separator(), bassoonItem,
                     informationItem, NSMenuItem.separator()] {
            item.target = self
            menu.addItem(item)
        }
        updater.addMenuItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "About ModRadio", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit MOD Radio", action: #selector(quit), keyEquivalent: "q").target = self

        updater.start()
        systemMedia = SystemMediaController(radio: radio)
        radio.onChange = { [weak self] in self?.refresh() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        progressTimer?.invalidate()
        systemMedia?.invalidate()
        systemMedia = nil
        radio.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        let track = radio.track
        titleItem.title = track?.displayTitle ?? "MOD Radio"
        switch radio.phase {
        case .stopped:
            detailItem.title = "Ready for a random module"
            playItem.title = track == nil ? "Play Random MOD or XM" : "Start with Another Track"
            pauseItem.isEnabled = false
            stopItem.isEnabled = false
            setSymbol("radio", description: "ModRadio")
        case .loading:
            detailItem.title = "Finding a random MOD or XM…"
            playItem.title = "Try Another Track"
            pauseItem.isEnabled = false
            stopItem.isEnabled = true
            setSymbol("arrow.triangle.2.circlepath", description: "Finding a random tracker song")
        case .playing:
            detailItem.title = trackDetails(prefix: "Playing", track: track)
            playItem.title = "Play Another Track"
            pauseItem.title = "Pause"
            pauseItem.isEnabled = true
            stopItem.isEnabled = true
            setSymbol("waveform.circle.fill", description: "Playing MOD Radio")
        case .paused:
            detailItem.title = trackDetails(prefix: "Paused", track: track)
            playItem.title = "Play Another Track"
            pauseItem.title = "Resume"
            pauseItem.isEnabled = true
            stopItem.isEnabled = true
            setSymbol("pause.circle.fill", description: "MOD Radio paused")
        case .failed(let message):
            detailItem.title = message
            playItem.title = "Try Another Track"
            pauseItem.isEnabled = false
            stopItem.isEnabled = true
            setSymbol("exclamationmark.circle", description: "MOD Radio needs attention")
        }
        bassoonItem.isEnabled = track != nil
        informationItem.isEnabled = track?.informationURL != nil
        updateProgress()
        systemMedia?.update()
    }

    private func trackDetails(prefix: String, track: RadioTrack?) -> String {
        let details = [track?.format, track?.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return details.isEmpty ? prefix : prefix + " • " + details.joined(separator: " • ")
    }

    private func setSymbol(_ name: String, description: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func configureProgressItem() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 48))
        progressSlider.frame = NSRect(x: 14, y: 22, width: 242, height: 20)
        progressSlider.isContinuous = true
        progressSlider.isEnabled = false
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged(_:))
        progressSlider.toolTip = "Track position"
        progressSlider.setAccessibilityLabel("Track position")
        container.addSubview(progressSlider)

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        elapsedLabel.frame = NSRect(x: 15, y: 5, width: 100, height: 14)
        elapsedLabel.font = timeFont
        elapsedLabel.textColor = .secondaryLabelColor
        container.addSubview(elapsedLabel)

        durationLabel.frame = NSRect(x: 155, y: 5, width: 100, height: 14)
        durationLabel.font = timeFont
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.alignment = .right
        container.addSubview(durationLabel)

        progressItem.view = container
    }

    private func updateProgress() {
        let isPlaying: Bool
        switch radio.phase {
        case .playing, .paused: isPlaying = true
        default: isPlaying = false
        }
        guard isPlaying, let progress = radio.playbackProgress else {
            progressSlider.minValue = 0
            progressSlider.maxValue = 1
            progressSlider.doubleValue = 0
            progressSlider.isEnabled = false
            elapsedLabel.stringValue = "0:00"
            durationLabel.stringValue = "—"
            return
        }

        elapsedLabel.stringValue = formattedTime(progress.elapsed)
        if let duration = progress.duration, duration > 0 {
            progressSlider.minValue = 0
            progressSlider.maxValue = duration
            progressSlider.doubleValue = min(progress.elapsed, duration)
            progressSlider.isEnabled = progress.canSeek
            durationLabel.stringValue = formattedTime(duration)
        } else {
            progressSlider.minValue = 0
            progressSlider.maxValue = 1
            progressSlider.doubleValue = 0
            progressSlider.isEnabled = false
            durationLabel.stringValue = "—"
        }
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func configureVolumeItem() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 38))
        volumeImageView.frame = NSRect(x: 14, y: 10, width: 18, height: 18)
        volumeImageView.imageScaling = .scaleProportionallyDown
        container.addSubview(volumeImageView)

        volumeSlider.frame = NSRect(x: 43, y: 7, width: 213, height: 24)
        volumeSlider.doubleValue = Double(radio.volume)
        volumeSlider.isContinuous = true
        volumeSlider.altIncrementValue = 0.05
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.toolTip = "Playback volume"
        volumeSlider.setAccessibilityLabel("Playback volume")
        container.addSubview(volumeSlider)

        volumeItem.view = container
        refreshVolumeIcon()
    }

    private func refreshVolumeIcon() {
        let name: String
        let description: String
        switch volumeSlider.doubleValue {
        case ...0.001:
            name = "speaker.slash.fill"
            description = "Muted"
        case ..<0.34:
            name = "speaker.wave.1.fill"
            description = "Low playback volume"
        case ..<0.67:
            name = "speaker.wave.2.fill"
            description = "Medium playback volume"
        default:
            name = "speaker.wave.3.fill"
            description = "High playback volume"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        volumeImageView.image = image
    }

    @objc private func playRandom() {
        radio.track == nil ? radio.playRandom() : radio.playAnother()
    }

    @objc private func togglePause() { radio.togglePause() }
    @objc private func stopRadio() { radio.stop() }

    @objc private func volumeChanged(_ sender: NSSlider) {
        radio.setVolume(Float(sender.doubleValue))
        refreshVolumeIcon()
    }

    @objc private func progressChanged(_ sender: NSSlider) {
        radio.seek(to: sender.doubleValue)
        updateProgress()
        systemMedia?.update()
    }

    @objc private func openInBassoon() {
        guard let track = radio.track else { return }
        var components = URLComponents(string: "https://www.stef.be/bassoontracker/")!
        components.queryItems = [URLQueryItem(name: "file", value: track.downloadURL.absoluteString)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc private func openInformation() {
        if let url = radio.track?.informationURL { NSWorkspace.shared.open(url) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Command-line verification and entry point

private func blockingDownload(_ url: URL) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<Data, Error>!
    let task = URLSession.shared.dataTask(with: url) { data, _, error in
        if let error { outcome = .failure(error) }
        else if let data { outcome = .success(data) }
        else { outcome = .failure(CatalogueError.invalidResponse) }
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    return try outcome.get()
}

private func runSmokeTest(format: CatalogueFormat = .random) -> Never {
    do {
        let response = try blockingDownload(format.endpoint)
        let track = try BassoonCatalogue.parseRandomTrack(from: response)
        let module = try TrackerModule(data: blockingDownload(track.downloadURL))
        let player = UniversalTrackerAudioPlayer()
        var didFinish = false
        try player.play(module) { didFinish = true }
        Thread.sleep(forTimeInterval: 0.5)
        guard let initialProgress = player.progress(),
              let duration = initialProgress.duration,
              initialProgress.canSeek,
              duration > 4 else {
            throw TrackerPlaybackError.timelineUnavailable
        }
        let seekTarget = min(duration - 1, max(2, duration * 0.5))
        player.seek(to: seekTarget)
        Thread.sleep(forTimeInterval: 0.5)
        guard let seekedProgress = player.progress(),
              seekedProgress.elapsed > initialProgress.elapsed else {
            throw TrackerPlaybackError.timelineUnavailable
        }
        player.seek(to: max(0, duration - 0.5), precise: true)
        let deadline = Date().addingTimeInterval(5)
        while !didFinish && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        guard didFinish else { throw TrackerPlaybackError.timelineUnavailable }
        player.stop()
        print("random_track=\(track.displayTitle)")
        print("format=\(module.format)")
        print("duration_seconds=\(Int(duration))")
        print("seek_seconds=\(Int(seekedProgress.elapsed))")
        print("end_callback=received")
        print("audio_engine=started")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("modradio: smoke test failed: \(error.localizedDescription)\n").utf8))
        exit(1)
    }
}

private func waitForRadio(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
    }
    return condition()
}

private func runRadioTransitionSmokeTest() -> Never {
    let radio = RadioController()
    do {
        radio.playRandom()
        guard waitForRadio(timeout: 25, condition: {
            radio.phase == .playing && radio.hasPrefetchedTrack
        }), let firstTrack = radio.track,
            let duration = radio.playbackProgress?.duration,
            duration > 2 else {
            throw TrackerPlaybackError.transitionUnavailable
        }

        radio.seek(to: max(0, duration - 0.5), precise: true)
        guard waitForRadio(timeout: 8, condition: {
            radio.phase == .playing && radio.track?.downloadURL != firstTrack.downloadURL
        }), let nextTrack = radio.track else {
            throw TrackerPlaybackError.transitionUnavailable
        }

        radio.stop()
        print("first_track=\(firstTrack.displayTitle)")
        print("next_track=\(nextTrack.displayTitle)")
        print("prefetch=ready")
        print("transition=completed")
        exit(0)
    } catch {
        radio.stop()
        FileHandle.standardError.write(Data(("modradio: transition test failed: \(error.localizedDescription)\n").utf8))
        exit(1)
    }
}

private func runMediaIntegrationSmokeTest() -> Never {
    let radio = RadioController()
    let systemMedia = SystemMediaController(radio: radio)
    radio.onChange = { systemMedia.update() }
    let testTrack = RadioTrack(
        title: "ModRadio Media Test",
        artist: "ModRadio",
        format: "MOD",
        downloadURL: URL(string: "https://www.stef.be/bassoontracker/")!,
        informationURL: nil
    )
    guard let module = try? TrackerModule(data: syntheticMODData()) else {
        radio.stop()
        systemMedia.invalidate()
        FileHandle.standardError.write(Data("modradio: synthetic media test module was invalid\n".utf8))
        exit(1)
    }
    radio.playForVerification(track: testTrack, module: module)

    guard radio.phase == .playing, let track = radio.track else {
        radio.stop()
        systemMedia.invalidate()
        FileHandle.standardError.write(Data("modradio: media integration test failed to start playback\n".utf8))
        exit(1)
    }

    systemMedia.update()
    let informationCenter = MPNowPlayingInfoCenter.default()
    let commandCenter = MPRemoteCommandCenter.shared()
    let information = informationCenter.nowPlayingInfo ?? [:]
    let title = information[MPMediaItemPropertyTitle] as? String
    let duration = information[MPMediaItemPropertyPlaybackDuration] as? Double
    let elapsed = information[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
    guard title == track.displayTitle,
          duration != nil,
          elapsed != nil,
          informationCenter.playbackState == .playing,
          commandCenter.pauseCommand.isEnabled,
          commandCenter.togglePlayPauseCommand.isEnabled,
          commandCenter.nextTrackCommand.isEnabled else {
        radio.stop()
        systemMedia.invalidate()
        FileHandle.standardError.write(Data("modradio: media integration metadata was incomplete\n".utf8))
        exit(1)
    }

    radio.togglePause()
    systemMedia.update()
    guard informationCenter.playbackState == .paused,
          commandCenter.playCommand.isEnabled else {
        radio.stop()
        systemMedia.invalidate()
        FileHandle.standardError.write(Data("modradio: media integration pause state failed\n".utf8))
        exit(1)
    }

    radio.stop()
    systemMedia.invalidate()
    print("now_playing_title=\(title ?? "")")
    print("duration_seconds=\(Int(duration ?? 0))")
    print("media_commands=enabled")
    print("playback_state=playing_and_paused")
    exit(0)
}

private func syntheticMODData() -> Data {
    var bytes = [UInt8](repeating: 0, count: 1084 + 64 * 4 * 4)
    let title = Array("ModRadio Media Test".utf8.prefix(20))
    bytes.replaceSubrange(0..<title.count, with: title)
    bytes[950] = 1
    bytes[951] = 0
    bytes.replaceSubrange(1080..<1084, with: Array("M.K.".utf8))
    return Data(bytes)
}

private func runStandardInputPlaybackCheck() -> Never {
    do {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let module = try TrackerModule(data: data)
        let player = UniversalTrackerAudioPlayer()
        try player.play(module) {}
        Thread.sleep(forTimeInterval: 2)
        player.stop()
        print("local_track=\(module.title)")
        print("format=\(module.format)")
        print("audio_engine=started")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(("modradio: standard-input playback check failed: \(error.localizedDescription)\n").utf8))
        exit(1)
    }
}

@main
struct ModRadioApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--smoke-stdin") { runStandardInputPlaybackCheck() }
        if CommandLine.arguments.contains("--smoke-media") { runMediaIntegrationSmokeTest() }
        if CommandLine.arguments.contains("--smoke-transition") { runRadioTransitionSmokeTest() }
        if CommandLine.arguments.contains("--smoke-mod") { runSmokeTest(format: .mod) }
        if CommandLine.arguments.contains("--smoke-xm") { runSmokeTest(format: .xm) }
        if CommandLine.arguments.contains("--smoke-test") { runSmokeTest() }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

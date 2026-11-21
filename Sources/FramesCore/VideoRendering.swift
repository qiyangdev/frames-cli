@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Darwin
import Foundation

public enum VideoRotation: String, CaseIterable, Sendable {
    case none, clockwise, counterclockwise
    case halfTurn = "180"

    var orientation: CGImagePropertyOrientation {
        switch self {
        case .none: .up
        case .clockwise: .right
        case .counterclockwise: .left
        case .halfTurn: .down
        }
    }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, prores
    case hevcAlpha = "hevc-alpha"

    public var usesMOV: Bool { self == .prores || self == .hevcAlpha }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .prores: .proRes4444
        case .hevcAlpha: .hevcWithAlpha
        }
    }
}

public enum VideoPreset: String, CaseIterable, Sendable {
    case compact, balanced, best

    func bitrate(for codec: VideoCodec) -> Int {
        let index = switch self {
        case .compact: 0
        case .balanced: 1
        case .best: 2
        }
        return (codec == .h264 ? [6, 10, 16] : [4, 7, 10])[index] * 1_000_000
    }
}

public enum VideoBackground: Sendable, Equatable, CustomStringConvertible {
    case white, black, transparent
    case rgb(UInt32)

    public init(_ value: String) throws {
        switch value.lowercased() {
        case "white": self = .white
        case "black": self = .black
        case "transparent": self = .transparent
        default:
            guard value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) else {
                throw FramesError("Background must be white, black, transparent, or #RRGGBB.")
            }
            self = .rgb(rgb)
        }
    }

    public var description: String {
        switch self {
        case .white: "white"
        case .black: "black"
        case .transparent: "transparent"
        case let .rgb(value): String(format: "#%06x", value & 0xffffff)
        }
    }

    var color: CIColor {
        switch self {
        case .white: .white
        case .black: .black
        case .transparent: .clear
        case let .rgb(value):
            CIColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255)
        }
    }
}

public struct VideoInput: Sendable {
    public var url: URL
    public var frame: FrameOptions
    public var rotation: VideoRotation

    public init(url: URL, frame: FrameOptions = .init(), rotation: VideoRotation = .none) {
        self.url = url
        self.frame = frame
        self.rotation = rotation
    }
}

public enum VideoPlayback: Sendable {
    case simultaneous, sequential
}

public struct VideoExportOptions: Sendable {
    public var codec: VideoCodec
    public var preset: VideoPreset
    public var background: VideoBackground
    public var stripAudio: Bool
    public var quality: Int?
    public var playback: VideoPlayback
    public var spacing: Int
    public var proportional: Bool

    public init(codec: VideoCodec = .h264, preset: VideoPreset = .best,
                background: VideoBackground? = nil, stripAudio: Bool = false, quality: Int? = nil,
                playback: VideoPlayback = .simultaneous, spacing: Int = 60, proportional: Bool = true) {
        self.codec = codec
        self.preset = preset
        self.background = background ?? (codec == .hevcAlpha ? .transparent : .white)
        self.stripAudio = stripAudio
        self.quality = quality
        self.playback = playback
        self.spacing = spacing
        self.proportional = proportional
    }

    public var resolvedCodec: VideoCodec {
        background == .transparent && codec != .hevcAlpha ? .prores : codec
    }

    public func outputSize(for size: PixelSize) -> PixelSize {
        guard resolvedCodec != .prores else { return size }
        return PixelSize(width: size.width + size.width % 2, height: size.height + size.height % 2)
    }
}

public struct VideoDescription: Sendable {
    public let frame: FrameDescription
    public let sourceSize: PixelSize
    public let duration: Double
    public let frameRate: Double
    public let frameRateRatio: String
    public let codec: String?
    public let audioCodec: String?
    public let hasAudio: Bool
    public let rotation: VideoRotation
}

public struct VideoExport: Sendable {
    public let output: URL
    public let size: PixelSize
    public let duration: Double
    public let hasAudio: Bool
    public let inputs: [VideoDescription]
    public let scaleFactors: [Double]
}

extension FramesRenderer {
    public func describeVideo(_ input: VideoInput) async throws -> VideoDescription {
        try await loadClip(input).description
    }

    /// Exports one video or lays out multiple videos on a single canvas.
    public func exportVideo(_ inputs: [VideoInput], to destination: URL, options: VideoExportOptions = .init(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> VideoExport {
        guard !inputs.isEmpty else { throw FramesError("At least one video is required.") }
        let codec = options.resolvedCodec
        if let quality = options.quality {
            guard (0...51).contains(quality) else { throw FramesError("Quality must be between 0 and 51.") }
            guard codec != .hevcAlpha else {
                throw FramesError("--quality is not supported with --codec hevc-alpha. Use --preset instead.")
            }
        }
        if codec.usesMOV && destination.pathExtension.lowercased() != "mov" {
            throw FramesError("ProRes and HEVC alpha outputs must use the .mov extension.")
        }
        var clips: [VideoClip] = []
        for input in inputs {
            try Task.checkCancellation()
            clips.append(try await loadClip(input))
        }

        let merged = clips.count > 1
        let sequential = merged && options.playback == .sequential
        let duration = sequential ? clips.reduce(CMTime.zero) { $0 + $1.duration }
            : clips.map(\.duration).max() ?? .zero
        let frameStep = merged ? CMTime(value: 1, timescale: 30) : clips[0].frameStep
        var elapsed = CMTime.zero
        let starts = clips.map { clip in
            let start = elapsed
            if sequential { elapsed = elapsed + clip.duration }
            return start
        }
        let plans = try clips.map { try prepare($0.description.frame, displaySize: $0.displaySize) }
        let tileImages = plans.map { plan in
            let frame = plan.frame
            let size = codec == .hevcAlpha && merged ? plan.description.frameSize
                : options.outputSize(for: plan.description.frameSize)
            return frame.composited(over: CIImage(color: .clear).cropped(to: CGRect(
                x: 0, y: 0, width: size.width, height: size.height
            )))
        }
        let arrangement = try layout(tileImages, physicalHeights: plans.map { $0.description.match.device.physicalHeight },
                                     spacing: options.spacing, proportional: options.proportional, bottomAlign: true)
        let size = options.outputSize(for: arrangement.size)
        try size.validate()
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var audio: [ExportAudio] = []
        if !options.stripAudio {
            if sequential {
                audio = [try await ExportAudio.sequence(clips: clips, starts: starts, duration: duration)]
            } else if !merged {
                let clip = clips[0]
                for track in clip.audioTracks {
                    audio.append(try await ExportAudio.passthrough(asset: clip.asset, track: track, duration: duration))
                }
            }
        }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: ".frames-\(UUID().uuidString).\(codec.usesMOV ? "mov" : "mp4")")
        defer { try? FileManager.default.removeItem(at: staged) }
        let isMOV = codec.usesMOV || destination.pathExtension.lowercased() == "mov"
        let writer = try AVAssetWriter(outputURL: staged, fileType: isMOV ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings = videoSettings(codec: codec, size: size, options: options)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw FramesError("This device cannot encode \(codec.rawValue) at \(size).")
        }
        let videoTrack = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoTrack, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(videoTrack) else { throw FramesError("Could not add the video writer track.") }
        writer.add(videoTrack)
        let audioTracks = try audio.map { source in
            let settings = source.formatHint == nil ? source.mixFormat.aacSettings : nil
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: source.formatHint)
            guard writer.canAdd(track) else { throw FramesError("Could not add the audio writer track.") }
            writer.add(track)
            return track
        }
        let readers = try clips.map(VideoFrames.init)
        guard writer.startWriting() else { throw writer.error ?? FramesError("Could not start video export.") }
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw FramesError("Could not allocate a video pixel buffer pool.") }

        let canvas = CIImage(color: options.background.color).cropped(to: bounds)
        var frameIndex: Int32 = 0
        var time = CMTime.zero
        var videoDone = false
        var unfinishedAudio = Set(audio.indices)
        var lastProgress = -1
        while !videoDone || !unfinishedAudio.isEmpty {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? FramesError("Video export stopped.") }
            var advanced = false
            if !videoDone, videoTrack.isReadyForMoreMediaData {
                advanced = true
                if time >= duration {
                    videoTrack.markAsFinished()
                    videoDone = true
                } else {
                    try autoreleasepool {
                        let frames = try readers.enumerated().map { index, reader in
                            let sample = try reader.frame(at: max(.zero, time - starts[index]))
                            var framed = try composite(sample, plan: plans[index])
                            let tile = tileImages[index].extent
                            if tile != framed.extent {
                                let fill = CIImage(color: options.background.color).cropped(to: tile)
                                framed = framed.transformed(by: .init(translationX: 0, y: tile.height - framed.extent.height))
                                    .composited(over: fill)
                            }
                            return framed
                        }
                        let composite = merge(frames, layout: arrangement, background: options.background.color)
                            .transformed(by: .init(translationX: 0, y: CGFloat(size.height - arrangement.size.height)))
                            .composited(over: canvas)
                        var buffer: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                            throw FramesError("Could not allocate a video frame.")
                        }
                        render(composite, to: buffer, bounds: bounds)
                        guard adaptor.append(buffer, withPresentationTime: time) else {
                            throw writer.error ?? FramesError("Could not write video frame.")
                        }
                    }
                    frameIndex += 1
                    time = CMTimeMultiply(frameStep, multiplier: frameIndex)
                    let percent = Int(min(1, time.seconds / duration.seconds) * 100)
                    if percent != lastProgress {
                        progress?(Double(percent) / 100)
                        lastProgress = percent
                    }
                }
            }
            for index in audio.indices where unfinishedAudio.contains(index) && audioTracks[index].isReadyForMoreMediaData {
                advanced = true
                let track = audioTracks[index]
                if let sample = try audio[index].next() {
                    guard track.append(sample) else { throw writer.error ?? FramesError("Could not write audio.") }
                } else {
                    track.markAsFinished()
                    unfinishedAudio.remove(index)
                }
            }
            if !advanced { try await Task.sleep(for: .milliseconds(3)) }
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? FramesError("Could not finish video export.") }

        if rename(staged.path, destination.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress?(1)
        let factors = zip(arrangement.placements, tileImages).map { placement, image in
            Double(placement.size.height) / Double(image.extent.height)
        }
        return VideoExport(output: destination, size: size, duration: duration.seconds,
                           hasAudio: !audio.isEmpty, inputs: clips.map(\.description), scaleFactors: factors)
    }

    private func videoSettings(codec: VideoCodec, size: PixelSize, options: VideoExportOptions) -> [String: Any] {
        // The renderer writes sRGB into the video buffers.
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if codec != .prores {
            var compression: [String: Any] = [AVVideoAverageBitRateKey: options.preset.bitrate(for: codec)]
            if let quality = options.quality {
                compression = [AVVideoQualityKey: 1 - Double(quality) / 51]
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        return settings
    }

    private func loadClip(_ input: VideoInput) async throws -> VideoClip {
        let asset = AVURLAsset(url: input.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw FramesError("No video stream found in \(input.url.path).")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let formats = try await video.load(.formatDescriptions)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= Double(Int32.max) / 240,
              let format = formats.first else {
            throw FramesError("Could not determine video duration and format for \(input.url.path).")
        }
        let encoded = CMVideoFormatDescriptionGetDimensions(format)
        let sourceSize = PixelSize(width: Int(encoded.width), height: Int(encoded.height))
        try sourceSize.validate()
        let transform = try await video.load(.preferredTransform)
        let swapped = input.rotation == .clockwise || input.rotation == .counterclockwise
        let size = swapped ? PixelSize(width: sourceSize.height, height: sourceSize.width) : sourceSize
        let transformSwaps = abs(transform.b) > abs(transform.a)
        let display = transformSwaps ? PixelSize(width: size.height, height: size.width) : size
        let frame = try describeFrame(size, options: input.frame, videoDisplaySize: display)
        let rate = try await video.load(.nominalFrameRate)
        let minimum = try await video.load(.minFrameDuration)
        let fps = rate.isFinite && rate > 0 ? Double(rate) : 30
        let frameStep = minimum.isNumeric && minimum.seconds.isFinite && abs(1 / minimum.seconds - fps) < 0.01
            ? CMTime(value: minimum.value, timescale: minimum.timescale)
            : CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        var audioCodec: String?
        if let audio = audioTracks.first, let format = try await audio.load(.formatDescriptions).first {
            audioCodec = codecName(CMFormatDescriptionGetMediaSubType(format))
        }
        let divisor = greatestCommonDivisor(Int64(frameStep.timescale), frameStep.value)
        let rateRatio = "\(Int64(frameStep.timescale) / divisor)/\(frameStep.value / divisor)"
        let description = VideoDescription(frame: frame, sourceSize: sourceSize, duration: duration.seconds,
                                           frameRate: fps, frameRateRatio: rateRatio,
                                           codec: codecName(CMFormatDescriptionGetMediaSubType(format)),
                                           audioCodec: audioCodec, hasAudio: !audioTracks.isEmpty, rotation: input.rotation)
        return VideoClip(asset: asset, video: video, audioTracks: audioTracks, duration: duration, frameStep: frameStep,
                         preferredTransform: transform, displaySize: display, description: description)
    }

    private func greatestCommonDivisor(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        var a = numerator
        var b = denominator
        while b > 0 { (a, b) = (b, a % b) }
        return a
    }

    private func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        let fourCC = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return switch fourCC {
        case "avc1", "avc3": "h264"
        case "hvc1", "hev1", "muxa": "hevc"
        case "mp4a", "aac": "aac"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "prores"
        default: fourCC
        }
    }
}

private struct VideoClip {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    let duration: CMTime
    let frameStep: CMTime
    let preferredTransform: CGAffineTransform
    let displaySize: PixelSize
    let description: VideoDescription
}

private final class VideoFrames {
    private let clip: VideoClip
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let origin: CMTime
    private var current: CMSampleBuffer
    private var upcoming: CMSampleBuffer?

    init(clip: VideoClip) throws {
        self.clip = clip
        reader = try AVAssetReader(asset: clip.asset)
        output = AVAssetReaderTrackOutput(track: clip.video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FramesError("Could not add video decoder.") }
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer() else {
            throw reader.error ?? FramesError("Video contains no readable frames.")
        }
        current = first
        origin = first.presentationTimeStamp
        upcoming = output.copyNextSampleBuffer()
    }

    deinit { reader.cancelReading() }

    func frame(at time: CMTime) throws -> CIImage {
        while let next = upcoming, next.presentationTimeStamp - origin <= time {
            current = next
            upcoming = output.copyNextSampleBuffer()
        }
        if reader.status == .failed { throw reader.error ?? FramesError("Video decoding failed.") }
        guard let buffer = current.imageBuffer else { throw FramesError("Could not decode video frame.") }
        var image = CIImage(cvPixelBuffer: buffer)
        if clip.preferredTransform != .identity {
            // Convert the track's top-left coordinate system to Core Image's bottom-left system.
            let rotation = CGAffineTransform(a: clip.preferredTransform.a, b: -clip.preferredTransform.b,
                                              c: -clip.preferredTransform.c, d: clip.preferredTransform.d, tx: 0, ty: 0)
            image = image.transformed(by: rotation)
            image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        return image.oriented(clip.description.rotation.orientation)
    }
}

private final class ExportAudio {
    struct MixFormat {
        var rate: Int32 = 44_100
        var channels: UInt32 = 2
        var channelLayout: Data?

        var aacSettings: [String: Any] {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
            ]
            settings[AVChannelLayoutKey] = channelLayout
            return settings
        }

        var pcmSettings: [String: Any] {
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            settings[AVChannelLayoutKey] = channelLayout
            return settings
        }

        init(firstSource: CMAudioFormatDescription? = nil) {
            guard let firstSource, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(firstSource)?.pointee,
                  stream.mSampleRate.isFinite, (8_000...96_000).contains(stream.mSampleRate),
                  (1...8).contains(stream.mChannelsPerFrame) else { return }
            rate = Int32(stream.mSampleRate)
            channels = stream.mChannelsPerFrame
            if channels > 2 {
                var length = 0
                if let layout = CMAudioFormatDescriptionGetChannelLayout(firstSource, sizeOut: &length) {
                    channelLayout = Data(bytes: layout, count: length)
                }
            }
        }
    }

    private let reader: AVAssetReader?
    private let output: AVAssetReaderOutput?
    let formatHint: CMFormatDescription?
    let mixFormat: MixFormat
    private let duration: CMTime
    private let fillsGaps: Bool
    private var upcoming: CMSampleBuffer?
    private var position: Int64 = 0
    private lazy var format: CMAudioFormatDescription? = {
        let bytesPerFrame = mixFormat.channels * 2
        var spec = AudioStreamBasicDescription(mSampleRate: Double(mixFormat.rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
                                               mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: mixFormat.channels,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        if let channelLayout = mixFormat.channelLayout {
            channelLayout.withUnsafeBytes { layout in
                _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &spec, layoutSize: layout.count,
                                                   layout: layout.bindMemory(to: AudioChannelLayout.self).baseAddress,
                                                   magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                   formatDescriptionOut: &format)
            }
        } else {
            _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &spec, layoutSize: 0, layout: nil,
                                               magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                               formatDescriptionOut: &format)
        }
        return format
    }()

    static func passthrough(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime) async throws -> ExportAudio {
        guard let format = try await track.load(.formatDescriptions).first else {
            throw FramesError("Could not determine the source audio format.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FramesError("Could not add the source audio track.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FramesError("Could not read the source audio.") }
        return ExportAudio(reader: reader, output: output, duration: duration, fillsGaps: false, formatHint: format)
    }

    static func sequence(clips: [VideoClip], starts: [CMTime], duration: CMTime) async throws -> ExportAudio {
        if !clips.contains(where: { !$0.audioTracks.isEmpty }) {
            return ExportAudio(reader: nil, output: nil, duration: duration, fillsGaps: true)
        }
        let first = try await clips.first?.audioTracks.first?.load(.formatDescriptions).first
        let mix = MixFormat(firstSource: first)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FramesError("Could not create the audio timeline.")
        }
        // Each clip occupies a separate interval on the sequential timeline.
        for (clip, start) in zip(clips, starts) {
            guard let source = clip.audioTracks.first else { continue }
            let sourceRange = try await source.load(.timeRange)
            let range = CMTimeRange(start: sourceRange.start, duration: min(sourceRange.duration, clip.duration))
            guard range.duration > .zero else { continue }
            try track.insertTimeRange(range, of: source, at: start)
        }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: mix.pcmSettings)
        guard reader.canAdd(output) else { throw FramesError("Could not add the audio decoder.") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? FramesError("Could not start reading audio.")
        }
        return ExportAudio(reader: reader, output: output, duration: duration, fillsGaps: true, mixFormat: mix)
    }

    private init(reader: AVAssetReader?, output: AVAssetReaderOutput?, duration: CMTime, fillsGaps: Bool,
                 formatHint: CMFormatDescription? = nil, mixFormat: MixFormat = .init()) {
        self.reader = reader
        self.mixFormat = mixFormat
        self.output = output
        self.formatHint = formatHint
        self.duration = duration
        self.fillsGaps = fillsGaps
        upcoming = output?.copyNextSampleBuffer()
    }

    deinit { reader?.cancelReading() }

    func next() throws -> CMSampleBuffer? {
        if reader?.status == .failed { throw reader?.error ?? FramesError("Audio decoding failed.") }
        let end = duration.convertScale(mixFormat.rate, method: .roundTowardZero).value
        let next = upcoming?.presentationTimeStamp.convertScale(mixFormat.rate, method: .roundHalfAwayFromZero).value ?? end
        if fillsGaps, next - position > 1 {
            let count = min(1024, Int(next - position))
            let sample = try silence(at: position, count: count)
            position += Int64(count)
            return sample
        }
        guard let sample = upcoming else { return nil }
        position = max(position, next + Int64(sample.numSamples))
        upcoming = output?.copyNextSampleBuffer()
        return sample
    }

    private func silence(at position: Int64, count: Int) throws -> CMSampleBuffer {
        let length = count * Int(mixFormat.channels) * 2
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == noErr, let block, let format,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr else {
            throw FramesError("Could not create a silent audio buffer.")
        }
        var sample: CMSampleBuffer?
        let created = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: position, timescale: mixFormat.rate), packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard created == noErr, let sample else { throw FramesError("Could not time silent audio.") }
        return sample
    }
}

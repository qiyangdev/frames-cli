@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import FramesCore

@Test func resolvesWidthOverlapsAndInstalledVariants() throws {
    try withFixture("""
        {
          "1206": {"overlap": {"2622": {"name": "iPhone 17 Portrait", "x": "10", "y": "20", "colors": "yes"}}},
          "1488": {"name": "iPad mini 2021 Portrait", "x": "142", "y": "146"},
          "variants": {
            "iPhone 18 Pro Portrait": {"name": "iPhone 18 Pro Portrait", "x": 4, "y": 8, "colors": "yes"},
            "iPhone Duo Inner Partially Open Landscape": {"name": "iPhone Duo Inner Partially Open Landscape", "colors": "yes"}
          }
        }
        """) { directory in
        let catalog = try FrameCatalog(directory: directory)
        let size = PixelSize(width: 1206, height: 2622)
        let automatic = try catalog.resolve(size)
        #expect(automatic.device.name == "iPhone 18 Pro Portrait")
        #expect(automatic.primary == "iPhone 17 Portrait")
        #expect(automatic.isVariant)
        #expect(try catalog.color(for: automatic.device, selection: "2") == "Glacier")
        #expect(try catalog.resolve(size, device: "iPhone 17 Portrait").device.x == 10)
        #expect(throws: FramesError.self) { try catalog.resolve(.init(width: 1206, height: 1920)) }
        let mini = try catalog.resolve(.init(width: 1488, height: 2266))
        #expect(mini.device.x == 146)
        #expect(mini.device.y == 142)
        let duo = try catalog.resolve(size, device: "iPhone Duo Book Pose")
        #expect(try catalog.color(for: duo.device, defaults: ["iPhone Duo Inner": "Star White"]) == "Star White")
        #expect(try FrameCatalog.knownColors(matching: "Book Pose").first?.colors == ["Night Sky", "Star White"])
    }
}

@Test func rendersMaskAndRotatesSidewaysLandscapeArtwork() throws {
    try withFixture("""
        {"8": {"name": "Phone Landscape", "x": "1", "y": "1", "mask": "yes"}}
        """) { directory in
        let frame = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 6, height: 10))
        let marker = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 9, width: 1, height: 1)).composited(over: frame)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 8))
        let corner = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 7, width: 1, height: 1))
        try write(marker, to: directory.appending(path: "Phone Landscape.png"))
        try write(corner.composited(over: mask), to: directory.appending(path: "Phone Landscape_mask.png"))
        let source = try makeImage(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4)))
        let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
        let framed = try renderer.frameImage(source)
        #expect(framed.description.frameSize == .init(width: 10, height: 6))
        #expect(framed.description.hasAppliedMask)
        #expect(try pixel(framed.image, x: 0, y: 0) == [255, 0, 0, 255])
        #expect(try pixel(framed.image, x: 1, y: 1)[3] == 0)
        let green = try pixel(framed.image, x: 1, y: 4)
        #expect(green == [0, 255, 0, 255])
    }
}

@Test func masksReplaceAlphaWithoutDiscardingStraightRGB() throws {
    try withFixture("""
        {"2": {"name": "Phone", "x": 1, "y": 1, "mask": "yes"}}
        """) { directory in
        let frame = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        try write(frame, to: directory.appending(path: "Phone.png"))
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        try write(mask, to: directory.appending(path: "Phone_mask.png"))
        let pixels: [UInt8] = [10, 60, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let source = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
        let framed = try renderer.frameImage(source)
        #expect(try pixel(framed.image, x: 1, y: 2) == [10, 60, 120, 255])
    }
}

@Test func mergesAtPhysicalScaleAndBottomAlignsBodies() throws {
    try withFixture("""
        {
          "4": {"name": "Phone", "x": 2, "y": 3, "physicalHeight": 6},
          "6": {"name": "Tablet", "x": 2, "y": 2, "physicalHeight": 18}
        }
        """) { directory in
        for (name, width, height, body) in [("Phone", 10, 16, 12), ("Tablet", 12, 20, 18)] {
            let base = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let bezel = CIImage(color: .blue).cropped(to: CGRect(x: 1, y: 1, width: width - 2, height: body))
            try write(bezel.composited(over: base), to: directory.appending(path: "\(name).png"))
        }
        let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
        let frames = try [4, 6].map { width in
            let source = try makeImage(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: width, height: 8)))
            return try renderer.frameImage(source)
        }
        let composition = try renderer.composeImages(frames, spacing: 1)
        #expect(composition.image.width == 18)
        #expect(composition.scaleFactors == [0.5, 1])
    }
}

@Test func rejectsUnrecognizedArchiveBeforeReplacingAssets() throws {
    try withFixture("{}") { directory in
        let archive = directory.appending(path: "invalid.zip")
        try Data([1, 2, 3]).write(to: archive)
        #expect(throws: FramesError.self) { try FrameAssets.installReleaseArchive(at: archive, to: directory) }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "NewFrames.json").path))
    }
}

@Test func exportsNativeVideoAndSequentialAudio() async throws {
    let directory = try fixture("""
        {"64": {"name": "Phone", "x": 8, "y": 8}}
        """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let frame = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 81, height: 65))
    let bezel = CIImage(color: .blue).cropped(to: CGRect(x: 4, y: 4, width: 4, height: 56))
    try write(bezel.composited(over: frame), to: directory.appending(path: "Phone.png"))
    let input = directory.appending(path: "test-clip.mp4")
    try await makeMovie(at: input)
    let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
    let clip = VideoInput(url: input)
    let info = try await renderer.describeVideo(clip)
    #expect(info.frame.inputSize == .init(width: 64, height: 48))
    #expect(info.codec == "h264")
    let output = directory.appending(path: "merged.mp4")
    let result = try await renderer.exportVideo([clip, clip], to: output, options: .init(playback: .sequential, spacing: 6))
    #expect(result.size == .init(width: 170, height: 66))
    #expect(result.hasAudio)
    #expect(abs(result.duration - info.duration * 2) < 0.005)
    let merged = AVURLAsset(url: output)
    #expect(try await merged.loadTracks(withMediaType: .audio).count == 1)
    let track = try #require(try await merged.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 170, height: 66))
    let player = AVAssetImageGenerator(asset: merged)
    player.requestedTimeToleranceBefore = .zero
    player.requestedTimeToleranceAfter = .zero
    let halfway = try await player.image(at: CMTime(value: 4, timescale: 30)).image
    let active = try pixel(halfway, x: 24, y: 32)
    let waiting = try pixel(halfway, x: 109, y: 32)
    #expect(Int(active[1]) - Int(active[0]) > 80, "The left tile should have advanced to green: \(active)")
    #expect(Int(waiting[0]) - Int(waiting[1]) > 80, "The right tile should still hold its first red frame: \(waiting)")

    let single = directory.appending(path: "with-audio.mp4")
    let withAudio = VideoInput(url: output, frame: .init(device: "Phone"))
    let singleResult = try await renderer.exportVideo([withAudio], to: single, options: .init(quality: 23))
    #expect(singleResult.hasAudio)
    #expect(try await AVURLAsset(url: single).loadTracks(withMediaType: .audio).count == 1)

    let mono = directory.appending(path: "mono.mp4")
    try await makeMovie(at: mono, monoAudio: true)
    let mix = directory.appending(path: "mono-then-silence.mp4")
    _ = try await renderer.exportVideo([VideoInput(url: mono), clip], to: mix,
                                       options: .init(playback: .sequential))
    let audio = try #require(try await AVURLAsset(url: mix).loadTracks(withMediaType: .audio).first)
    let format = try #require(try await audio.load(.formatDescriptions).first)
    #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 1)
    #expect(try await audioPeak(at: mix, start: 0.05) > 2_000)
    #expect(try await audioPeak(at: mix, start: 0.3) < 30)
}

@Test(arguments: [VideoCodec.prores, .hevcAlpha])
func transparentCodecsPreserveAlpha(_ codec: VideoCodec) async throws {
    let directory = try fixture("""
        {"64": {"name": "Phone", "x": 16, "y": 16}}
        """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bounds = CGRect(x: 0, y: 0, width: 96, height: 80)
    let frame = CIImage(color: .clear).cropped(to: bounds)
    let bezel = CIImage(color: .blue).cropped(to: CGRect(x: 10, y: 10, width: 6, height: 60))
    try write(bezel.composited(over: frame), to: directory.appending(path: "Phone.png"))
    let input = directory.appending(path: "source.mp4")
    try await makeMovie(at: input)
    let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
    let output = directory.appending(path: "alpha.mov")
    _ = try await renderer.exportVideo([VideoInput(url: input)], to: output,
                                       options: .init(codec: codec, background: .transparent))
    let image = try await firstVideoFrame(at: output)
    #expect(try pixel(image, x: 1, y: 1)[3] < 4)
    #expect(try pixel(image, x: 24, y: 24)[3] >= 250)
}

@Test(arguments: VideoCodec.allCases)
func foldedVideoAndStillApplyTheSameProjectionAndMask(_ codec: VideoCodec) async throws {
    let directory = try fixture("""
        {"variants":{"Folded":{"name":"Folded","mask":"yes","warp":{
          "inputSizes":[[64,48]],"blend":"normal","regions":[
            {"polygon":[[0,0],[32,0],[24,48],[0,48]],
             "inverse":[0.015625,0,0,0,0.020833333333333332,0,0,0]}
          ]
        }}}}
        """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
    try write(CIImage(color: .blue).cropped(to: bounds), to: directory.appending(path: "Folded.png"))
    let hole = CIImage(color: .black).cropped(to: CGRect(x: 4, y: 14, width: 10, height: 14))
    let mask = hole.composited(over: CIImage(color: .white).cropped(to: bounds))
    try write(mask, to: directory.appending(path: "Folded_mask.png"))
    let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
    let options = FrameOptions(device: "Folded")
    let input = directory.appending(path: "source.mp4")
    try await makeMovie(at: input)
    // Compare with the source as decoded, including the source codec's color conversion.
    let source = try await firstVideoFrame(at: input)
    let still = try renderer.frameImage(source, options: options).image
    let output = directory.appending(path: codec.usesMOV ? "folded.mov" : "folded.mp4")
    _ = try await renderer.exportVideo([VideoInput(url: input, frame: options)], to: output,
                                       options: .init(codec: codec, background: codec.usesMOV ? .transparent : .white))
    let video = try await firstVideoFrame(at: output)
    for (x, y, dominant) in [(18, 24, 0), (10, 24, 2), (40, 40, 2)] {
        let screenshotPixel = try pixel(still, x: x, y: y)
        let videoPixel = try pixel(video, x: x, y: y)
        #expect(screenshotPixel[dominant] > 200)
        #expect(zip(screenshotPixel, videoPixel).allSatisfy { abs(Int($0) - Int($1)) < 12 },
                "Pixel (\(x), \(y)): still \(screenshotPixel), video \(videoPixel)")
    }
}

@Test func videoExportReplacesAnOutputLinkWithoutOverwritingItsSource() async throws {
    let directory = try fixture("""
        {"64":{"name":"Phone","x":8,"y":8}}
        """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bounds = CGRect(x: 0, y: 0, width: 80, height: 64)
    try write(CIImage(color: .clear).cropped(to: bounds), to: directory.appending(path: "Phone.png"))
    let source = directory.appending(path: "source.mp4")
    try await makeMovie(at: source)
    let original = try Data(contentsOf: source)
    let renderer = try FramesRenderer(catalog: FrameCatalog(directory: directory))
    let fm = FileManager.default
    let symbolic = directory.appending(path: "symbolic.mp4")
    let hard = directory.appending(path: "hard.mp4")
    try fm.createSymbolicLink(at: symbolic, withDestinationURL: source)
    try fm.linkItem(at: source, to: hard)
    for output in [symbolic, hard] {
        let result = try await renderer.exportVideo([VideoInput(url: source)], to: output)
        #expect(result.size == PixelSize(width: 80, height: 64))
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: output) != original)
        #expect(try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    }
}

private func firstVideoFrame(at url: URL) async throws -> CGImage {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    try #require(reader.startReading())
    defer { reader.cancelReading() }
    let sample = try #require(output.copyNextSampleBuffer()?.imageBuffer)
    return try makeImage(CIImage(cvPixelBuffer: sample))
}

private func audioPeak(at url: URL, start: Double) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 44_100),
                                   duration: CMTime(value: 2_205, timescale: 44_100))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    reader.add(output)
    #expect(reader.startReading())
    var peak = 0
    var count = 0
    while let sample = output.copyNextSampleBuffer(), let buffer = sample.dataBuffer {
        var bytes = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(buffer) / MemoryLayout<Int16>.size)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        try #require(status == noErr)
        peak = max(peak, bytes.map { abs(Int($0)) }.max() ?? 0)
        count += bytes.count
    }
    #expect(count > 0)
    return peak
}

private func fixture(_ catalog: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "frames-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(catalog.utf8).write(to: directory.appending(path: "NewFrames.json"))
    return directory
}

private func withFixture(_ catalog: String, test: (URL) throws -> Void) throws {
    let directory = try fixture(catalog)
    defer { try? FileManager.default.removeItem(at: directory) }
    try test(directory)
}

private func makeImage(_ image: CIImage) throws -> CGImage {
    try #require(CIContext().createCGImage(image, from: image.extent))
}

private func write(_ image: CIImage, to url: URL) throws {
    try FramesRenderer.writePNG(makeImage(image), to: url)
}

private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let sample = try #require(image.cropping(to: CGRect(x: x, y: image.height - y - 1, width: 1, height: 1)))
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { storage in
        let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

private func makeMovie(at url: URL, monoAudio: Bool = false) async throws {
    let size = CGSize(width: 64, height: 48)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(track)
    let audio: AVAssetWriterInput?
    if monoAudio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        writer.add(input)
        audio = input
    } else {
        audio = nil
    }
    guard writer.startWriting() else { throw writer.error ?? FramesError("Could not create test clip.") }
    writer.startSession(atSourceTime: .zero)
    let pool = try #require(adaptor.pixelBufferPool)
    let renderer = CIContext()
    let bounds = CGRect(origin: .zero, size: size)
    for index in 0..<3 {
        while !track.isReadyForMoreMediaData {
            if writer.status != .writing { throw writer.error ?? FramesError("Test clip stopped encoding.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        renderer.render(CIImage(color: index == 0 ? .red : .green).cropped(to: bounds), to: frame)
        guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 15)) else {
            throw writer.error ?? FramesError("Could not append test frame.")
        }
    }
    track.markAsFinished()
    if let audio {
        #expect(audio.append(try monoSamples()))
        audio.markAsFinished()
    }
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 15))
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? FramesError("Could not finish test clip.") }
}


private func monoSamples() throws -> CMSampleBuffer {
    let rate: Int32 = 44_100
    let count = Int(rate / 5)
    let length = count * MemoryLayout<Int16>.size
    var pcm = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                          mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                          mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &pcm, layoutSize: 0, layout: nil,
                                               magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                               formatDescriptionOut: &format) == noErr)
    var block: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                   blockBufferOut: &block) == noErr)
    let data = try #require(block)
    let tone = (0..<count).map { sample in Int16(10_000 * sin(2 * .pi * 440 * Double(sample) / Double(rate))) }
    let status = tone.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data,
                                      offsetIntoDestination: 0, dataLength: $0.count)
    }
    try #require(status == noErr)
    var sample: CMSampleBuffer?
    let descriptor = try #require(format)
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: data, formatDescription: descriptor, sampleCount: count,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
    ) == noErr)
    return try #require(sample)
}

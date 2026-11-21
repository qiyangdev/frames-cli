#if os(macOS)
import Foundation
import FramesCore

extension FramesCommand {
    private struct VideoJob {
        let path: CommandPath
        let input: VideoInput
    }

    private static func videoInputs(_ args: Arguments, settings: Settings) throws -> [VideoJob] {
        let sources = inputs(args.files, video: true)
        guard !sources.isEmpty else { throw FramesError("No videos found in the specified paths.") }
        let frames = try args.frameOptions(count: sources.count, defaults: settings.colors)
        let rotation = try args.selection("--rotate", default: VideoRotation.none)
        return zip(sources, frames).map { path, frame in
            VideoJob(path: path, input: VideoInput(url: path.url, frame: frame, rotation: rotation))
        }
    }

    static func videoInfo(_ args: Arguments, renderer: FramesRenderer, settings: Settings) async throws {
        let videos = try videoInputs(args, settings: settings)
        var records: [[String: Any]] = []
        for job in videos {
            do {
                let info = try await renderer.describeVideo(job.input)
                reportFrame(info.frame, options: job.input.frame, catalog: renderer.catalog, verbose: args.has("--verbose"))
                if info.frame.maskMissing { log("Warning: display mask missing for \(info.frame.match.device.name).") }
                var record = videoFields(info, output: .init())
                let size = info.frame.inputSize
                record.merge([
                    "file": job.path.path, "name": job.path.lastPathComponent,
                    "width": size.width, "height": size.height,
                    "source_width": info.sourceSize.width, "source_height": info.sourceSize.height,
                    "fps_rate": info.frameRateRatio, "audio_codec": nullable(info.audioCodec),
                    "x": info.frame.match.device.x, "y": info.frame.match.device.y,
                    "resize_width": nullable(info.frame.resizeTarget?.width), "resize_height": nullable(info.frame.resizeTarget?.height),
                    "has_mask": info.frame.match.device.hasMask, "is_variant": info.frame.match.isVariant,
                ]) { _, new in new }
                records.append(record)
            } catch {
                records.append(["file": job.path.path, "name": job.path.lastPathComponent, "error": error.localizedDescription])
            }
        }
        if args.has("--json") {
            if records.count == 1 { try writeJSON(records[0]) } else { try writeJSON(records) }
        } else {
            if records.count > 1 {
                let matched = records.filter { $0["device"] != nil }.count
                print("Scanned \(records.count) videos · \(matched) matched · \(records.count - matched) failed")
            }
            let style = terminalStyle(args)
            for record in records {
                print("\n" + style.bold(record["name"] as? String ?? ""))
                if let error = record["error"] { print("  ✗ \(error)"); continue }
                if let dimensions = record["dimensions"], let duration = record["duration"],
                   let fps = record["fps"], let codec = record["codec"] {
                    let audio = record["audio"] as? Bool == true ? "audio: \(record["audio_codec"] ?? "unknown")" : "no audio"
                    print("  \(dimensions) · \(duration)s · \(fps) fps · \(codec) · \(audio)")
                }
                if let device = record["device"] as? String { print("  ✓ " + style.bold(device)) }
                if record["is_variant"] as? Bool == true, let primary = record["primary_match"] { print("  Primary match: \(primary)") }
                if let frame = record["frame_size"] { print("  Frame size: \(frame)") }
                if record["padded"] as? Bool == true, let dimensions = record["output_dimensions"] { print("  Video size: \(dimensions) (padded for MP4)") }
                if let color = record["color"] as? String { print("  Color: \(color)") }
                if let width = record["resize_width"], !(width is NSNull) { print("  Scaled to \(width)px") }
                if record["has_mask"] as? Bool == true {
                    print("  Mask: \(record["mask_missing"] as? Bool == true ? "missing" : "available")")
                }
            }
        }
    }

    static func exportVideos(_ args: Arguments, renderer: FramesRenderer, settings: Settings) async throws {
        let videos = try videoInputs(args, settings: settings)
        let merge = args.has("--merge")
        let sequential = args.has("--playback-offset")
        guard !merge || videos.count >= 2 else { throw FramesError("--merge requires at least two videos.") }
        guard !sequential || merge else { throw FramesError("--playback-offset requires --merge.") }
        let requestedCodec = try args.selection("--codec", default: VideoCodec.h264)
        let codec: VideoCodec = args.has("--alpha") && requestedCodec != .hevcAlpha ? .prores : requestedCodec
        let preset = try args.selection("--preset", default: VideoPreset.best)
        let background = try args["--background"].map(VideoBackground.init)
            ?? (args.has("--alpha") || codec == .hevcAlpha ? .transparent : .white)
        let options = try VideoExportOptions(codec: codec, preset: preset, background: background,
                                             stripAudio: args.has("--strip-audio"), quality: args.integer("--quality", range: 0...51),
                                             playback: sequential ? .sequential : .simultaneous,
                                             spacing: args.integer("--spacing", range: 0...50_000) ?? 60,
                                             proportional: !args.has("--no-scale"))
        let output = args["--output"].map(CommandPath.init)
        let isDirectory = output.flatMap { try? $0.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory } == true
        let explicitFile = output.map { !$0.url.pathExtension.isEmpty && !isDirectory } ?? false
        guard merge || videos.count == 1 || !explicitFile else {
            throw FramesError("--output must be a directory for several individual videos.")
        }
        let ext = options.resolvedCodec.usesMOV ? "mov" : "mp4"
        func destination(for source: CommandPath, name: String) -> CommandPath {
            if let output, explicitFile { return output }
            return (output ?? source.parent).appending(name + "." + ext)
        }
        let groups = merge ? [videos] : videos.map { [$0] }
        let destinations = groups.compactMap { group -> CommandPath? in
            guard let first = group.first else { return nil }
            let name = merge ? "merged_framed" : first.path.url.deletingPathExtension().lastPathComponent + "_framed"
            return destination(for: first.path, name: name)
        }
        try validateOutputs(destinations.map(\.url), against: videos.map(\.path.url),
                            individualVideo: !merge, allowReplacingInputs: merge && explicitFile)
        let progress: (@Sendable (Double) -> Void)? = interactive && !args.has("--json")
            ? { @Sendable completed in
                let text = "\rRendering \(Int(completed * 100))%   "
                FileHandle.standardError.write(Data(text.utf8))
            } : nil
        var resolved: [[VideoDescription]] = []
        for group in groups {
            var descriptions: [VideoDescription] = []
            for job in group {
                let description = try await renderer.describeVideo(job.input)
                reportFrame(description.frame, options: job.input.frame, catalog: renderer.catalog, verbose: args.has("--verbose"))
                if description.frame.maskMissing { log("Warning: display mask missing for \(description.frame.match.device.name).") }
                descriptions.append(description)
            }
            resolved.append(descriptions)
        }

        var records: [[String: Any]] = []
        for (groupIndex, (group, output)) in zip(groups, destinations).enumerated() {
            let sourceBytes = group.reduce(0) { $0 + bytes(at: $1.path.url) }
            // Reuse the inspected color so random selections get a single result per input.
            let selected = zip(group, resolved[groupIndex]).map { job, description in
                var input = job.input
                input.frame.color = description.frame.color
                return input
            }
            let result = try await renderer.exportVideo(selected, to: output.url, options: options, progress: progress)
            if progress != nil { log("") }
            let outputBytes = bytes(at: output.url)
            let metrics = fileMetrics(source: sourceBytes, output: outputBytes)
            var details: [[String: Any]] = []
            for (index, info) in result.inputs.enumerated() {
                var record = videoFields(info, output: options, merged: merge)
                record.merge([
                    "source": group[index].path.path, "output": output.path,
                    "output_codec": options.resolvedCodec.rawValue, "audio_stripped": options.stripAudio,
                    "background": options.background.description, "preset": preset.rawValue,
                    "quality": nullable(options.quality), "alpha": options.resolvedCodec.usesMOV,
                    "resized": info.frame.resizeTarget != nil, "masked": info.frame.hasAppliedMask,
                ]) { _, new in new }
                if merge { record["scale_factor"] = rounded(result.scaleFactors[index], places: 4) }
                details.append(record)
            }
            var aggregate: [String: Any]
            if merge {
                aggregate = [
                    "merged": output.path, "count": group.count, "duration": rounded(result.duration, places: 6),
                    "dimensions": result.size.description, "playback_offset": sequential,
                    "audio": result.hasAudio, "audio_stripped": options.stripAudio, "preset": preset.rawValue,
                    "frames": details, "output_codec": options.resolvedCodec.rawValue,
                ]
            } else {
                aggregate = details[0]
            }
            aggregate.merge(metrics) { _, new in new }
            records.append(aggregate)
            if !args.has("--json") {
                print("\(output.path) (\(ByteCountFormatter.string(fromByteCount: Int64(outputBytes), countStyle: .file)))")
            }
        }
        if args.has("--json") {
            if records.count == 1 { try writeJSON(records[0]) } else { try writeJSON(["videos": records]) }
        }
    }

    private static func videoFields(_ info: VideoDescription, output: VideoExportOptions, merged: Bool = false) -> [String: Any] {
        let frame = info.frame
        let size = output.resolvedCodec == .hevcAlpha && merged ? frame.frameSize : output.outputSize(for: frame.frameSize)
        return [
            "device": frame.match.device.name, "primary_match": frame.match.primary,
            "color": nullable(frame.color), "dimensions": frame.inputSize.description, "frame_size": frame.frameSize.description,
            "duration": rounded(info.duration, places: 6), "fps": rounded(info.frameRate, places: 4),
            "codec": nullable(info.codec), "audio": info.hasAudio && !output.stripAudio, "mask_missing": frame.maskMissing,
            "physicalHeight": frame.match.device.physicalHeight, "rotation": info.rotation.rawValue,
            "source_dimensions": info.sourceSize.description, "output_width": size.width, "output_height": size.height,
            "output_dimensions": size.description, "padded": size != frame.frameSize,
        ]
    }

    private static func bytes(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func fileMetrics(source: Int, output: Int) -> [String: Any] {
        let savings = source - output
        let sourceSize = ByteCountFormatter.string(fromByteCount: Int64(source), countStyle: .file)
        let outputSize = ByteCountFormatter.string(fromByteCount: Int64(output), countStyle: .file)
        let change = ByteCountFormatter.string(fromByteCount: Int64(abs(savings)), countStyle: .file)
        return [
            "source_size_bytes": source, "source_size": sourceSize,
            "output_size_bytes": output, "output_size": outputSize,
            "savings_bytes": savings, "savings": savings < 0 ? "-" + change : change,
            "savings_percent": source > 0 ? rounded(100 * Double(savings) / Double(source), places: 2) : 0,
        ]
    }
}
#endif

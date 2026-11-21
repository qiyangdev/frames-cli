#if os(macOS)
import AppKit
import Foundation
import FramesCore

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "webp"]
let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

struct CommandPath {
    let path: String
    let url: URL

    init(_ argument: String) {
        let expanded = (argument as NSString).expandingTildeInPath
        let components = expanded.split(separator: "/").filter { $0 != "." }
        let normalized = components.joined(separator: "/")
        path = expanded.hasPrefix("/") ? "/" + normalized : normalized.isEmpty ? "." : normalized
        url = fileURL(expanded)
    }

    var lastPathComponent: String { url.lastPathComponent }
    var parent: CommandPath {
        let prefix = (path as NSString).deletingLastPathComponent
        return CommandPath(prefix.isEmpty ? "." : prefix)
    }

    func appending(_ name: String) -> CommandPath {
        CommandPath(path == "." ? name : (path as NSString).appendingPathComponent(name))
    }
}

func inputs(_ paths: [String], video: Bool = false) -> [CommandPath] {
    let fm = FileManager.default
    let extensions = video ? videoExtensions : imageExtensions
    return paths.flatMap { argument -> [CommandPath] in
        let path = CommandPath(argument)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path.url.path, isDirectory: &isDirectory) else {
            FramesCommand.log("Error: \(path.path) not found")
            return []
        }
        if !isDirectory.boolValue {
            if video && !extensions.contains(path.url.pathExtension.lowercased()) {
                FramesCommand.log("Error: \(path.path) is not a supported video file")
                return []
            }
            return [path]
        }
        let entries = (try? fm.contentsOfDirectory(at: path.url, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            extensions.contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { path.appending($0.lastPathComponent) }
    }
}

extension FramesCommand {
    private struct ImageJob {
        let source: CommandPath
        let frame: FramedImage

        var metadata: [String: Any] {
            let description = frame.description
            let device = description.match.device
            return [
                "source": source.path, "device": device.name, "primary_match": description.match.primary,
                "color": nullable(description.color), "dimensions": description.inputSize.description,
                "frame_size": description.frameSize.description, "resized": description.resizeTarget != nil,
                "masked": description.hasAppliedMask, "mask_missing": description.maskMissing,
                "physicalHeight": device.physicalHeight, "is_variant": description.match.isVariant,
            ]
        }
    }

    static func frameImages(_ args: Arguments, renderer: FramesRenderer, settings: Settings) async throws {
        let sources = inputs(args.files)
        guard !sources.isEmpty else { throw FramesError("No images found in the specified paths.") }
        let batchSize = try args.integer("--batch", range: 2...Int.max)
        let spacing = try args.integer("--spacing", range: 0...50_000) ?? 60
        let frameOptions = try args.frameOptions(count: sources.count, defaults: settings.colors)
        let subfolder = try args["--subfolder"].map(Settings.validateSubfolder)
            ?? (args.has("--framed-subfolder") ? "framed" : settings.subfolder)
        func directory(for source: CommandPath) -> CommandPath {
            if let explicit = args["--output"] { return CommandPath(explicit) }
            return subfolder.map { source.parent.appending($0) } ?? source.parent
        }
        var jobs: [ImageJob] = []
        for (source, options) in zip(sources, frameOptions) {
            do {
                let framed = try renderer.frameImage(at: source.url, options: options)
                if framed.description.maskMissing { log("Warning: display mask missing for \(framed.description.match.device.name).") }
                reportFrame(framed.description, options: options, catalog: renderer.catalog, verbose: args.has("--verbose"))
                jobs.append(ImageJob(source: source, frame: framed))
            } catch {
                log("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard let first = jobs.first else { throw FramesError("No screenshots were framed.") }
        var metadata = jobs.map(\.metadata)
        let json: Any
        var outputs: [CommandPath] = []
        if (args.has("--merge") || batchSize != nil), jobs.count > 1 {
            let size = min(batchSize ?? jobs.count, jobs.count)
            let batches = stride(from: 0, to: jobs.count, by: size).map {
                $0..<min($0 + size, jobs.count)
            }
            let destinations = batches.indices.map { index in
                let name = batches.count == 1 ? "merged_framed.png" : "merged_\(index + 1)_framed.png"
                return directory(for: first.source).appending(name)
            }
            try validateOutputs(destinations.map(\.url), against: sources.map(\.url))
            var details: [[String: Any]] = []
            for (index, batch) in batches.enumerated() {
                let frames = jobs[batch].map(\.frame)
                let merge = try renderer.composeImages(frames, spacing: spacing, proportional: !args.has("--no-scale"))
                let output = destinations[index]
                try FramesRenderer.writePNG(merge.image, to: output.url)
                let heights = frames.map { $0.description.match.device.physicalHeight }
                if !args.has("--no-scale"), heights.allSatisfy({ $0 > 0 }), Set(heights).count > 1 {
                    let reference = zip(frames, heights).map { Double($0.image.height) / $1 }.min() ?? 1
                    for (i, height) in zip(batch, heights) {
                        let factor = (height * reference).rounded(.toNearestOrEven) / Double(jobs[i].frame.image.height)
                        metadata[i]["scale_factor"] = factor < 0.999 ? rounded(factor, places: 4) : 1.0
                    }
                }
                outputs.append(output)
                details.append(["merged": output.path, "count": batch.count])
            }
            if batches.count == 1 {
                json = ["merged": destinations[0].path, "count": jobs.count, "frames": metadata] as [String: Any]
            } else {
                json = ["batches": details, "batch_size": size, "total": jobs.count, "frames": metadata] as [String: Any]
            }
        } else {
            let destinations = jobs.map { job in
                directory(for: job.source).appending(job.source.url.deletingPathExtension().lastPathComponent + "_framed.png")
            }
            try validateOutputs(destinations.map(\.url), against: sources.map(\.url))
            for (index, output) in destinations.enumerated() {
                try FramesRenderer.writePNG(jobs[index].frame.image, to: output.url)
                metadata[index]["output"] = output.path
            }
            outputs = destinations
            if metadata.count == 1 {
                json = metadata[0]
            } else {
                json = ["frames": metadata]
            }
        }
        if args.has("--copy"), outputs.count == 1, let output = outputs.first {
            await copyImage(output.url, announce: !args.has("--json"))
        }
        if args.has("--json") { try writeJSON(json) }
        else { outputs.forEach { print($0.path) } }
    }

    @MainActor
    private static func copyImage(_ url: URL, announce: Bool) {
        guard let png = try? Data(contentsOf: url) else {
            log("Warning: Could not copy to clipboard")
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(png, forType: .png) {
            if announce { log("Copied to clipboard") }
        } else {
            log("Warning: Could not copy to clipboard")
        }
    }

    static func reportFrame(_ frame: FrameDescription, options: FrameOptions, catalog: FrameCatalog, verbose: Bool) {
        let model = frame.match.device
        if !options.strictColor, let color = options.color, catalog.isInvalidColor(color, for: model) {
            log("Warning: Color '\(color)' not found for \(model.name). Using default.")
        }
        if verbose {
            if frame.match.isVariant { log("Variant resolved: \(model.name)") }
            if let size = frame.resizeTarget { log("Resized: \(frame.inputSize) → \(size)") }
            if frame.hasAppliedMask { log("Mask applied") }
        }
    }

    static func imageInfo(_ args: Arguments, catalog: FrameCatalog) throws {
        let sources = inputs(args.files)
        guard !sources.isEmpty else {
            log("No images found.")
            return
        }
        let records = sources.map { source -> [String: Any] in
            var fields: [String: Any] = ["file": source.path, "name": source.lastPathComponent]
            do {
                let size = try FramesRenderer.imageSize(at: source.url)
                fields["width"] = size.width
                fields["height"] = size.height
                guard let match = try? catalog.resolve(size) else {
                    fields["device"] = NSNull()
                    fields["error"] = "Unknown device (width \(size.width)px)"
                    return fields
                }
                let device = match.device
                let colorChoices = catalog.colors(for: device.name)
                let target = device.resizeTarget(for: size)
                fields.merge([
                    "device": device.name, "primary_match": match.primary,
                    "x": device.catalogX.jsonValue, "y": device.catalogY.jsonValue,
                    "colors": colorChoices, "color_count": colorChoices.count, "has_mask": device.hasMask,
                    "resize_width": nullable(target == nil ? nil : device.catalogResizeWidth?.jsonValue),
                    "resize_height": nullable(target == nil ? nil : device.catalogResizeHeight?.jsonValue),
                    "variants": match.variants, "is_variant": match.isVariant,
                ]) { _, new in new }
            } catch {
                fields["error"] = error.localizedDescription
            }
            return fields
        }
        if args.has("--json") {
            if records.count == 1 { try writeJSON(records[0]) } else { try writeJSON(records) }
        } else {
            let style = terminalStyle(args)
            let matched = records.compactMap { $0["device"] as? String }
            if records.count > 1 {
                print("Scanned \(records.count) images · \(matched.count) matched · \(records.count - matched.count) unknown")
            }
            for record in records {
                print("\n" + style.bold(record["name"] as? String ?? ""))
                if let width = record["width"], let height = record["height"] { print("  \(width) × \(height)") }
                if let error = record["error"] as? String {
                    print("  ✗ \(error)")
                    continue
                }
                if let device = record["device"] as? String { print("  ✓ " + style.bold(device)) }
                if record["is_variant"] as? Bool == true, let primary = record["primary_match"] {
                    print("  Primary match: \(primary)")
                }
                let colors = record["colors"] as? [String] ?? []
                if colors.isEmpty { print("  No color variants") }
                else { print("  \(colors.count) colors: \(colors.joined(separator: ", "))") }
                let variants = (record["variants"] as? [String] ?? []).filter { $0 != record["device"] as? String }
                if variants.count > 0 { print("  Also available: \(variants.joined(separator: ", "))") }
                if let width = record["resize_width"], !(width is NSNull) { print("  Scaled to \(width)px") }
                if record["has_mask"] as? Bool == true { print("  Mask applied") }
            }
            if matched.count > 3 {
                print("\n" + style.bold("Summary"))
                let counts = Dictionary(grouping: matched, by: { $0 }).mapValues(\.count)
                let names = counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
                for name in names { print("  \(counts[name] ?? 0)× \(name)") }
                if matched.count < records.count { print("  \(records.count - matched.count)× unknown") }
            }
        }
    }

    static func validateOutputs(_ destinations: [URL], against sources: [URL],
                                individualVideo: Bool = false, allowReplacingInputs: Bool = false) throws {
        func location(_ url: URL) -> URL {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent)
        }
        func aliases(_ left: URL, _ right: URL) -> Bool {
            let lhs = location(left)
            let rhs = location(right)
            if lhs.path == rhs.path || lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path { return true }
            guard let id = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
                  let otherID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
                return false
            }
            return id.isEqual(otherID)
        }
        for (i, destination) in destinations.enumerated() {
            for earlier in destinations.indices.prefix(i) where aliases(destination, destinations[earlier]) {
                if !individualVideo || !aliases(sources[i], sources[earlier]) {
                    throw FramesError("Multiple inputs would write to \(destination.path). Choose distinct output names.")
                }
            }
            if allowReplacingInputs { continue }
            for source in sources where aliases(destination, source) {
                if !individualVideo || !aliases(sources[i], source) {
                    throw FramesError("Output \(destination.path) would replace an input. Choose another output location.")
                }
            }
        }
    }
}

func rounded(_ value: Double, places: Int) -> Double {
    let factor = pow(10.0, Double(places))
    return (value * factor).rounded() / factor
}
#endif

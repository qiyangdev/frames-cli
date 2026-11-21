#if os(macOS)
import Foundation

enum ReleasePack {
    struct Summary {
        let version: String
        let previous: String
        let fileCount: Int
        let pngCount: Int
        let existingCount: Int
        let newFiles: [String]
        let archiveBytes: Int
        let digest: String
    }

    static func build(_ builtURL: URL, previous previousURL: URL, version: String, added: [String],
                      output: URL, archive: URL) throws -> Summary {
        guard version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil else {
            throw PackError("Version must look like 4.2.2")
        }
        let built = try PackStorage.readPack(builtURL)
        let previous = try PackStorage.readPack(previousURL)
        guard let oldCatalog = previous[catalogFile], let newCatalog = built[catalogFile], built[versionFile] != nil,
              let oldVersion = previous[versionFile].flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw PackError("Both packs need \(catalogFile) and \(versionFile)")
        }
        guard version != oldVersion else { throw PackError("The previous pack is already version \(version)") }
        let missing = Set(previous.keys).subtracting(built.keys).sorted()
        guard missing.isEmpty else { throw PackError("Missing from the new pack: \(missing.joined(separator: ", "))") }
        let changed = previous.keys.filter { $0 != catalogFile && $0 != versionFile && previous[$0] != built[$0] }.sorted()
        guard changed.isEmpty else { throw PackError("Changed since the previous pack: \(changed.joined(separator: ", "))") }

        var catalog = try JSONValue.document(newCatalog)
        let previousCatalog = try JSONValue.document(oldCatalog)
        guard let variants = catalog["variants"]?.object, previousCatalog["variants"]?.object != nil else {
            throw PackError("Both catalogs need a variants object")
        }
        guard JSONValue.object(catalog).encoded() == newCatalog else {
            throw PackError("NewFrames.json must use two-space indentation and a trailing newline")
        }
        let oldNames = Set(previousCatalog.entries.compactMap { $0["name"]?.string })
        let names = Set(catalog.entries.compactMap { $0["name"]?.string }).subtracting(oldNames).sorted()
        guard names == added.sorted() else {
            throw PackError("Expected added frames \(added.sorted()), found \(names)")
        }
        let additions = Set(added)
        for field in variants.fields {
            if let name = field.value.object?["name"]?.string, additions.contains(name), name != field.key {
                throw PackError("Variant \(field.key) has a different name field")
            }
        }
        catalog.forEachEntry { entry in
            entry["name"]?.string.map { !additions.contains($0) } ?? true
        }
        guard JSONValue.object(catalog).encoded() == oldCatalog else {
            throw PackError("NewFrames.json changes more than the added frames")
        }

        let newFiles = Set(built.keys).subtracting(previous.keys).sorted()
        func owns(_ name: String, file: String) -> Bool {
            [" ", "_", "."].contains { file.hasPrefix(name + $0) }
        }
        for name in newFiles {
            guard name.hasSuffix(".png"), added.contains(where: { owns($0, file: name) }),
                  let image = built[name] else {
                throw PackError("New file does not belong to an added frame: \(name)")
            }
            _ = try PNGData.inspect(image)
            _ = try Raster(png: image)
        }
        for name in added where !newFiles.contains(where: { owns(name, file: $0) }) {
            throw PackError("No new files for \(name)")
        }

        try PackStorage.stage(output: output, archive: archive) { stage in
            for (name, data) in built {
                try (name == versionFile ? Data(version.utf8) : data).write(to: stage.appending(path: name))
            }
        }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        return Summary(version: version, previous: oldVersion, fileCount: built.count,
                       pngCount: built.keys.filter { $0.hasSuffix(".png") }.count, existingCount: previous.count - 2,
                       newFiles: newFiles, archiveBytes: bytes.count, digest: bytes.sha256)
    }
}

enum TrimPack {
    static let noiseAlpha: UInt8 = 8

    struct Device {
        let files: Int
        let canvas: Size
        let crop: Box
        let droppedAlpha: Int
        let droppedLone: Int

        var json: JSONValue {
            .object(["files": .number(String(files)), "canvas": canvas.json, "box": crop.json,
                     "dropped_alpha": .number(String(droppedAlpha)), "dropped_lone": .number(String(droppedLone)),
                     "shift": .array([.number(String(crop.left)), .number(String(crop.top))])])
        }
    }

    struct Report {
        var devices: [String: Device] = [:]
        var untouched: [String] = []

        var deviceJSON: JSONValue {
            var entries: OrderedObject = [:]
            for name in devices.keys.sorted() { entries[name] = devices[name]?.json }
            return .object(entries)
        }

        var json: JSONValue {
            .object(["devices": deviceJSON, "untouched": .array(untouched.map(JSONValue.string))])
        }
    }

    static func sideways(_ name: String, _ size: Size) -> Bool {
        name.hasSuffix(" Landscape") && size.height > size.width
    }

    static func visibleBounds(_ alpha: Raster) -> Box? {
        let width = alpha.width, height = alpha.height
        var left = width, top = height, right = 0, bottom = 0
        let pixels = alpha.pixels
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > noiseAlpha {
                var visible = false
                for row in max(0, y - 1)...min(height - 1, y + 1) {
                    for column in max(0, x - 1)...min(width - 1, x + 1)
                    where (row != y || column != x) && pixels[row * width + column] > noiseAlpha {
                        visible = true
                        break
                    }
                    if visible { break }
                }
                if visible {
                    left = min(left, x)
                    right = max(right, x + 1)
                    top = min(top, y)
                    bottom = max(bottom, y + 1)
                }
            }
        }
        return left < right ? Box(left, top, right, bottom) : nil
    }

    static func dropped(_ alpha: Raster, outside box: Box) -> (maximum: Int, aboveNoise: Int) {
        var maximum = 0, above = 0
        for y in 0..<alpha.height {
            for x in 0..<alpha.width where y < box.top || y >= box.bottom || x < box.left || x >= box.right {
                let value = alpha.pixels[y * alpha.width + x]
                maximum = max(maximum, Int(value))
                if value > noiseAlpha { above += 1 }
            }
        }
        return (maximum, above)
    }

    static func unionBounds(_ alphas: [Raster], name: String) throws -> Box {
        var union: Box?
        for alpha in alphas {
            guard let bounds = visibleBounds(alpha) else { throw PackError("No visible device in \(name)") }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        guard let union else { throw PackError("No artwork for \(name)") }
        return union
    }

    static func build(source: URL, output: URL, version: String, archive: URL? = nil) throws -> Report {
        var catalog = try PackStorage.readCatalog(in: source)
        let candidates = try PackStorage.contents(of: source)
        let entries = catalog.entries
        let names = Set(entries.compactMap { $0["name"]?.string }).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        let warped = Set(entries.compactMap { $0["warp"] != nil ? $0["name"]?.string : nil })
        var byDevice: [String: [URL]] = [:]
        var report = Report()
        return try PackStorage.stage(output: output, archive: archive) { stage in
            for file in candidates {
                try PackStorage.checkRegular(file)
                let name = file.lastPathComponent
                if name == catalogFile || name == versionFile { continue }
                let stem = file.deletingPathExtension().lastPathComponent
                if file.pathExtension == "png", !stem.hasSuffix("_mask"),
                   let owner = names.first(where: { stem == $0 || stem.hasPrefix($0 + " ") }), !warped.contains(owner) {
                    byDevice[owner, default: []].append(file)
                } else {
                    try PackStorage.files.copyItem(at: file, to: stage.appending(path: name))
                    if file.pathExtension == "png", !stem.hasSuffix("_mask") { report.untouched.append(name) }
                }
            }

            for name in byDevice.keys.sorted() {
                let paths = byDevice[name] ?? []
                let rasters = try paths.map(Raster.init(url:))
                guard let first = rasters.first else { continue }
                let storedSideways = sideways(name, first.size)
                let alphas = rasters.map {
                    sideways(name, $0.size) ? $0.alpha.rotatedCounterclockwise() : $0.alpha
                }
                let size = alphas[0].size
                guard alphas.allSatisfy({ $0.size == size }) else { throw PackError("\(name) colors have different canvas sizes") }
                let box = try unionBounds(alphas, name: name)
                let loss = alphas.map { dropped($0, outside: box) }
                let stored = storedSideways ? Box(first.width - box.bottom, box.left, first.width - box.top, box.right) : box
                for (path, image) in zip(paths, rasters) {
                    guard Box(image.size).contains(stored) else { throw PackError("Unexpected orientation in \(path.lastPathComponent)") }
                    let destination = stage.appending(path: path.lastPathComponent)
                    try image.crop(stored).write(to: destination, iccProfile: PNGData.iccProfile(of: path))
                    try PackOptimizer.lossless(destination)
                }
                report.devices[name] = Device(files: paths.count, canvas: size, crop: box,
                                              droppedAlpha: loss.map(\.maximum).max() ?? 0, droppedLone: loss.map(\.aboveNoise).reduce(0, +))
            }
            try catalog.forEachEntry { entry in
                guard let name = entry["name"]?.string, let device = report.devices[name] else { return true }
                guard let x = entry["x"]?.integer, let y = entry["y"]?.integer,
                      x >= device.crop.left, y >= device.crop.top else { throw PackError("Crop cuts into the screen of \(name)") }
                entry["x"] = .string(String(x - device.crop.left))
                entry["y"] = .string(String(y - device.crop.top))
                return true
            }
            try PackStorage.write(catalog, version: version, to: stage)
            return report
        }
    }
}

enum PackOptimizer {
    struct Row: Sendable {
        let file: String
        let sourceBytes: Int
        let bytes: Int
        let quantized: Bool

        var json: JSONValue {
            .object(["file": .string(file), "kind": .string(quantized ? "quantized" : "lossless"), "bytes": .number(String(bytes))])
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let executable = paths.map({ URL(filePath: String($0)).appending(path: tool) })
            .first(where: { PackStorage.files.isExecutableFile(atPath: $0.path) }) else {
            throw PackError("Required tool \(tool) was not found on PATH")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func lossless(_ file: URL) throws {
        let status = try run("oxipng", ["-q", "-o", "4", "--strip", "safe", file.path])
        guard status == 0 else { throw PackError("oxipng exited with status \(status) for \(file.lastPathComponent)") }
    }

    static func visualError(_ original: Raster, _ candidate: Raster) throws -> (psnr: Double, block: Int) {
        guard original.size == candidate.size else { return (0, 255) }
        var minimum = 99.0, maximum = 0
        for background in [0, 255] {
            var squares = 0
            var gray = Raster(size: original.size, channels: 1)
            for i in stride(from: 0, to: original.pixels.count, by: 4) {
                let oldAlpha = Int(original.pixels[i + 3]), newAlpha = Int(candidate.pixels[i + 3])
                var luminance = 32768
                for (channel, factor) in [19595, 38470, 7471].enumerated() {
                    let old = (Int(original.pixels[i + channel]) * oldAlpha + background * (255 - oldAlpha) + 127) / 255
                    let new = (Int(candidate.pixels[i + channel]) * newAlpha + background * (255 - newAlpha) + 127) / 255
                    let error = abs(old - new)
                    squares += error * error
                    luminance += factor * error
                }
                gray.pixels[i / 4] = UInt8(luminance >> 16)
            }
            let mse = Double(squares) / Double(gray.pixels.count * 3)
            if mse > 0 { minimum = min(minimum, 10 * log10(255 * 255 / mse)) }
            let blocks = try gray.resized(to: Size(max(1, original.width / 32), max(1, original.height / 32)), filter: .box)
            maximum = max(maximum, Int(blocks.pixels.max() ?? 0))
        }
        return (minimum, maximum)
    }

    static func optimize(_ source: URL, to destination: URL) throws -> Row {
        let input = try Data(contentsOf: source)
        let original = try Raster(png: input)
        let stem = source.deletingPathExtension().lastPathComponent
        return try PackStorage.temp { temporary in
            let lossless = temporary.appending(path: "lossless.png")
            try input.write(to: lossless)
            try self.lossless(lossless)
            var selected = try Data(contentsOf: lossless)
            guard try Raster(png: selected) == original else { throw PackError("oxipng changed pixels in \(source.lastPathComponent)") }
            var quantized = false
            if !stem.hasSuffix("_mask"), !stem.hasSuffix("_camera") {
                let candidate = temporary.appending(path: "quantized.png")
                if try run("pngquant", ["--speed", "1", "--strip", "--force", "--output", candidate.path, source.path]) == 0 {
                    try self.lossless(candidate)
                    let bytes = try Data(contentsOf: candidate)
                    let error = try visualError(original, Raster(png: bytes))
                    if error.psnr >= 50, error.block <= 2, bytes.count < selected.count {
                        selected = bytes
                        quantized = true
                    }
                }
            }
            try selected.write(to: destination)
            return Row(file: source.lastPathComponent, sourceBytes: input.count, bytes: selected.count, quantized: quantized)
        }
    }

    static func build(source: URL, output: URL) throws -> [Row] {
        let files = try PackStorage.contents(of: source)
        return try PackStorage.stage(output: output) { stage in
            try files.compactMap { file in
                try PackStorage.checkRegular(file)
                let destination = stage.appending(path: file.lastPathComponent)
                if file.pathExtension == "png" { return try optimize(file, to: destination) }
                try PackStorage.files.copyItem(at: file, to: destination)
                return nil
            }
        }
    }
}
#endif

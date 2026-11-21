#if os(macOS)
import Foundation

struct ArtworkView: Sendable {
    let name: String
    let asset: String
    let canvas: Size
    let screen: Box
    let physicalHeight: Double

    var entry: OrderedObject {
        ["name": .string(name), "x": .string(String(screen.left)), "y": .string(String(screen.top)),
         "mask": "yes", "colors": "yes", "physicalHeight": .double(physicalHeight)]
    }

    func screenMask(in raster: Raster) throws -> Raster {
        guard raster.size == canvas else { throw PackError("Unexpected canvas for \(name): \(raster.size), expected \(canvas)") }
        var mask = raster.alpha
        mask.pixels = mask.pixels.map { $0 < 255 ? 255 : 0 }
        mask.fill(x: (screen.left + screen.right) / 2, y: (screen.top + screen.bottom) / 2, with: 128)
        mask.pixels = mask.pixels.map { $0 == 128 ? 255 : 0 }
        guard mask.bounds == screen else {
            throw PackError("\(name) screen opening changed: expected \(screen), got \(String(describing: mask.bounds))")
        }
        return mask.crop(screen)
    }
}

enum FlatArtwork {
    struct Task: Sendable {
        let view: ArtworkView
        let colors: [String]
        let sourceName: @Sendable (String) -> String
    }

    static let duoColors = ["Night Sky", "Star White"]
    static let duo: [(view: ArtworkView, announced: Size?)] = [
        (ArtworkView(name: "iPhone Duo Outer Portrait", asset: "Outer Closed Portrait", canvas: Size(1574, 2194),
                     screen: Box(88, 80, 1486, 2114), physicalHeight: 117.8), nil),
        (ArtworkView(name: "iPhone Duo Outer Landscape", asset: "Outer Closed Landscape", canvas: Size(2194, 1574),
                     screen: Box(80, 88, 2114, 1486), physicalHeight: 84.1), nil),
        (ArtworkView(name: "iPhone Duo Inner Portrait", asset: "Inner Open Portrait", canvas: Size(2247, 3093),
                     screen: Box(120, 120, 2127, 2973), physicalHeight: 164.6), Size(1878, 2670)),
        (ArtworkView(name: "iPhone Duo Inner Landscape", asset: "Inner Open Landscape", canvas: Size(3093, 2247),
                     screen: Box(120, 120, 2973, 2127), physicalHeight: 117.8), Size(2670, 1878)),
        (ArtworkView(name: "iPhone Duo Outer Open", asset: "Outer Open", canvas: Size(3056, 2194),
                     screen: Box(1570, 80, 2968, 2114), physicalHeight: 117.8), nil),
    ]

    static let proled = [
        ArtworkView(name: "MacBook Pro PROLED 14", asset: "14-inch", canvas: Size(3860, 2540),
                    screen: Box(418, 277, 3442, 2263), physicalHeight: 248.5),
        ArtworkView(name: "MacBook Pro PROLED 16", asset: "16-inch", canvas: Size(4260, 2840),
                    screen: Box(394, 287, 3866, 2553), physicalHeight: 279.5),
    ]

    static func addDuo(to catalog: inout OrderedObject) throws {
        for (view, announced) in duo {
            var entry = view.entry
            let native = view.screen.size
            if view.asset == "Outer Open" {
                try catalog.addVariant(view.name, entry: entry)
            } else {
                if announced != nil {
                    entry["resizeWidth"] = .string(String(native.width))
                    entry["resizeHeight"] = .string(String(native.height))
                }
                for size in [native, announced].compactMap({ $0 }) {
                    try catalog.addWidth(size.width, entry: entry, height: size.height)
                }
            }
        }
    }

    static func addPROLED(to catalog: inout OrderedObject) throws {
        if let original = catalog["3024"]?.object, original["overlap"] == nil {
            guard original["name"]?.string == "MacBook Pro M5 14" else { throw PackError("Unexpected 3024-wide entry in base") }
            catalog["3024"] = .object(["overlap": .object(["1964": .object(original)])])
        }
        for view in proled {
            let size = view.screen.size
            if catalog[String(size.width)] == nil {
                try catalog.addWidth(size.width, entry: view.entry)
            } else {
                try insertOverlap(size, entry: view.entry, into: &catalog)
            }
        }
        var scaled = proled[1].entry
        scaled["resizeWidth"] = .number("3472")
        scaled["resizeHeight"] = .number("2266")
        for size in [Size(3822, 2478), Size(2000, 1297), Size(4128, 2694)] {
            try insertOverlap(size, entry: scaled, into: &catalog)
        }
    }

    private static func insertOverlap(_ size: Size, entry: OrderedObject, into catalog: inout OrderedObject) throws {
        let key = String(size.width), height = String(size.height)
        if var row = catalog[key]?.object {
            guard var overlap = row["overlap"]?.object, overlap[height] == nil else {
                throw PackError("Catalog already defines width \(size.width) or size \(size)")
            }
            overlap[height] = .object(entry)
            row["overlap"] = .object(overlap)
            catalog[key] = .object(row)
        } else {
            try catalog.addWidth(size.width, entry: entry, height: size.height)
        }
    }

    static func build(source: URL, base: URL, output: URL, archive: URL?, version override: String?, isDuo: Bool) throws {
        var catalog = try PackStorage.readCatalog(in: base)
        let version = try override ?? PackStorage.version(in: base)
        guard let major = version.split(separator: ".").first.flatMap({ Int($0) }), major >= 4 else {
            throw PackError("Base asset version must be at least 4")
        }
        let jobs: [Task]
        if isDuo {
            try addDuo(to: &catalog)
            jobs = duo.map { view, _ in
                Task(view: view, colors: duoColors) { "iPhone Duo - \($0) - \(view.asset).png" }
            }
        } else {
            try addPROLED(to: &catalog)
            jobs = proled.map { view in
                Task(view: view, colors: ["Silver", "Space Black"]) { "MacBook Pro with PROLED XDR Display \(view.asset) \($0).png" }
            }
        }

        let savings = try PackStorage.stage(output: output, archive: archive) { stage in
            try PackStorage.copy(base, to: stage) { $0.hasSuffix(".png") }
            if isDuo, try PackStorage.contents(of: stage).isEmpty { throw PackError("Base pack contains no frame PNGs") }
            try copyLicense(from: source, to: stage)
            var before = 0, after = 0
            for task in jobs {
                var shared: Raster?
                for color in task.colors {
                    let input = source.appending(path: task.sourceName(color))
                    let data = try Data(contentsOf: input)
                    let artwork = try Raster(png: data)
                    let mask = try task.view.screenMask(in: artwork)
                    if let shared, shared != mask { throw PackError("Screen masks differ between finishes: \(task.view.name)") }
                    shared = mask
                    let png = try PNGData.optimize(data, raster: artwork)
                    try png.write(to: stage.appending(path: "\(task.view.name) \(color).png"), options: .withoutOverwriting)
                    before += data.count
                    after += png.count
                }
                if let shared { try shared.write(to: stage.appending(path: "\(task.view.name)_mask.png")) }
                print("Prepared \(task.view.name)")
            }
            try PackStorage.write(catalog, version: version, to: stage)
            return (before, after)
        }
        print("\(isDuo ? "Duo" : "PROLED") PNGs: \(savings.0) → \(savings.1) bytes")
        print("Built \(output.path)")
    }

    static func copyLicense(from source: URL, to output: URL, replace: Bool = false) throws {
        let license = source.deletingLastPathComponent().appending(path: licenseFile)
        do { try PackStorage.checkRegular(license) }
        catch { throw PackError("Keep \(licenseFile) beside the source artwork folder") }
        let destination = output.appending(path: licenseFile)
        if replace {
            try Data(contentsOf: license).write(to: destination, options: .atomic)
        } else {
            try PackStorage.files.copyItem(at: license, to: destination)
        }
    }
}

enum HomeViewArtwork {
    static let screen = 1088
    static let views: [(view: ArtworkView, colors: [String])] = [
        (ArtworkView(name: "HomeView", asset: "select", canvas: Size(1260, 1494),
                     screen: Box(86, 86, 1174, 1174), physicalHeight: 172.5), ["Silver", "Starlight", "Rose Pink", "Space Gray"]),
        (ArtworkView(name: "HomeView Wall Mounted", asset: "wallmount-select", canvas: Size(1260, 1260),
                     screen: Box(86, 86, 1174, 1174), physicalHeight: 145.5), ["Silver", "Space Gray"]),
    ]

    static func addCatalog(to catalog: inout OrderedObject) throws {
        for (view, _) in views {
            var entry = view.entry
            entry["resizeWidth"] = "1088"
            entry["resizeHeight"] = "1088"
            if view.asset == "select" {
                for size in [screen, 1080] { try catalog.addWidth(size, entry: entry, height: size) }
            } else {
                try catalog.addVariant(view.name, entry: entry)
            }
        }
    }

    private static func opening(_ renders: [Raster]) throws -> Raster {
        guard let first = renders.first else { throw PackError("No HomeView renders") }
        let alpha = first.alpha
        guard let body = alpha.bounds, renders.allSatisfy({ $0.size == first.size && $0.alpha.bounds == body }) else {
            throw PackError("Finishes have different outlines")
        }
        var dark = Raster(size: first.size, channels: 1)
        for i in dark.pixels.indices where alpha.pixels[i] == 255 {
            let offset = i * 4
            let darkInEveryFinish = renders.allSatisfy {
                max($0.pixels[offset], $0.pixels[offset + 1], $0.pixels[offset + 2]) < 8
            }
            if darkInEveryFinish { dark.pixels[i] = 255 }
        }
        let y = body.top + body.size.width / 2
        guard y < dark.height else { throw PackError("Unexpected HomeView outline") }
        var run = 0
        var seed: Int?
        for x in body.left..<body.right {
            run = dark.pixels[y * dark.width + x] == 255 ? run + 1 : 0
            if run == 40 {
                seed = x - 19
                break
            }
        }
        guard let seed else { throw PackError("Could not locate HomeView's bezel ring") }
        dark.fill(x: seed, y: y, with: 128)
        dark.pixels = dark.pixels.map { $0 == 128 ? 255 : 0 }
        let center = (body.left + body.right) / 2
        guard dark.pixels[y * dark.width + center] == 0 else { throw PackError("The bezel reaches the middle of the screen") }
        dark.fill(x: center, y: y, with: 64)
        dark.pixels = dark.pixels.map { $0 == 64 ? 255 : 0 }
        guard let opened = dark.bounds, abs(opened.size.width - opened.size.height) <= 2,
              (0.84..<0.89).contains(Double(opened.size.width) / Double(body.size.width)) else {
            throw PackError("Unexpected HomeView screen opening")
        }
        return dark
    }

    static func frames(_ renders: [Raster], view: ArtworkView) throws -> (frames: [Raster], mask: Raster) {
        let opened = try opening(renders)
        guard let bounds = opened.bounds else { throw PackError("HomeView opening is empty") }
        let target = view.screen, size = view.canvas
        let scaleX = Double(bounds.size.width) / Double(screen)
        let scaleY = Double(bounds.size.height) / Double(screen)
        let box = [Double(bounds.left) - Double(target.left) * scaleX, Double(bounds.top) - Double(target.top) * scaleY,
                   Double(bounds.left) + Double(size.width - target.left) * scaleX,
                   Double(bounds.top) + Double(size.height - target.top) * scaleY]
        let coverage = try opened.resized(to: size, filter: .box, source: box)
        let binary = Raster(size: size, channels: 1, pixels: coverage.pixels.map { $0 == 0 ? 0 : 255 })
        guard binary.bounds == target else { throw PackError("\(view.name) opening does not align with its canvas") }
        let frames = try renders.map { render in
            var cut = render
            for i in opened.pixels.indices where opened.pixels[i] != 0 {
                for c in 0..<4 { cut.pixels[i * 4 + c] = 0 }
            }
            var scaled = try cut.resized(to: size, filter: .lanczos, source: box)
            guard let body = scaled.alpha.bounds, body.left <= 1, body.top <= 1,
                  body.right >= size.width - 1, body.bottom >= size.height - 1 else {
                throw PackError("\(view.name) body does not fill its canvas")
            }
            for i in coverage.pixels.indices where coverage.pixels[i] > 0 {
                let p = i * 4
                scaled.pixels[p] = 0
                scaled.pixels[p + 1] = 0
                scaled.pixels[p + 2] = 0
                scaled.pixels[p + 3] = 255 - coverage.pixels[i]
            }
            return scaled
        }
        return (frames, binary.crop(target))
    }

    static func build(source: URL, base: URL, output: URL, archive: URL?) throws {
        var catalog = try PackStorage.readCatalog(in: base)
        let version = try PackStorage.version(in: base)
        try addCatalog(to: &catalog)
        try PackStorage.stage(output: output, archive: archive) { stage in
            try PackStorage.copy(base, to: stage) { $0 != catalogFile && $0 != versionFile }
            for (view, colors) in views {
                let renders = try colors.map { color in
                    let name = "homeview-\(view.asset)-\(color.lowercased().replacingOccurrences(of: " ", with: ""))-202610.png"
                    let raw = try Raster(url: source.appending(path: name))
                    guard raw.size == Size(4000, 4000) else { throw PackError("Download \(name) at 4000 x 4000") }
                    return raw
                }
                let result = try frames(renders, view: view)
                for (color, frame) in zip(colors, result.frames) {
                    let filename = "\(view.name) \(color).png"
                    try frame.write(to: stage.appending(path: filename))
                    print("  \(filename)")
                }
                try result.mask.write(to: stage.appending(path: "\(view.name)_mask.png"))
                print("  \(view.name)_mask.png")
            }
            try PackStorage.write(catalog, version: version, to: stage)
        }
        print("Built \(output.path)")
    }
}

enum MiniUltraArtwork {
    static let ultra = ["Black + Alpine Loop Burgundy", "Black + Ocean Band Translucent Black", "Black + Trail Loop Burgundy",
                        "Natural + Alpine Loop Desert", "Natural + Ocean Band Translucent Gray", "Natural + Trail Loop Sand"]
    static let devices: [(view: ArtworkView, colors: [String])] = [
        (ArtworkView(name: "iPad mini A20 Pro Portrait", asset: "Portrait", canvas: Size(1772, 2576),
                     screen: Box(130, 130, 1642, 2446), physicalHeight: 195.3), ["Midnight", "Starlight"]),
        (ArtworkView(name: "iPad mini A20 Pro Landscape", asset: "Landscape", canvas: Size(2576, 1772),
                     screen: Box(130, 130, 2446, 1642), physicalHeight: 132.6), ["Midnight", "Starlight"]),
        (ArtworkView(name: "Watch Ultra 4", asset: "Watch", canvas: Size(620, 940),
                     screen: Box(99, 213, 521, 727), physicalHeight: 72.1), ultra),
    ]

    static func build(mini: URL, watch: URL, base: URL, output: URL, version: String, archive: URL?) throws -> JSONValue {
        var catalog = try PackStorage.readCatalog(in: base)
        guard catalog.fields.contains(where: { $0.value.object?["name"]?.string == "Watch Ultra 3" }) else {
            throw PackError("Base has no Watch Ultra 3 entry")
        }
        return try PackStorage.stage(output: output, archive: archive) { stage in
            try PackStorage.temp { temp in
                let raw = temp.appending(path: "raw")
                let cropped = temp.appending(path: "cropped")
                try PackStorage.files.createDirectory(at: raw, withIntermediateDirectories: false)
                var new: OrderedObject = ["variants": .object([:])]
                for (view, colors) in devices {
                    let watchFrame = view.asset == "Watch"
                    let entry: OrderedObject = ["name": .string(view.name), "colors": "yes",
                                                 "x": .string(String(view.screen.left)), "y": .string(String(view.screen.top)),
                                                 "physicalHeight": .double(view.physicalHeight)]
                    if watchFrame { try new.addVariant(view.name, entry: entry) }
                    else { try new.addWidth(view.screen.size.width, entry: entry) }
                    var shared: Raster?
                    for color in colors {
                        let filename = watchFrame ? "AW Ultra 4 - \(color).png" : "iPad mini (A20 Pro) - \(color) - \(view.asset).png"
                        let source = (watchFrame ? watch : mini).appending(path: filename)
                        var frame = try Raster(url: source)
                        let mask = try view.screenMask(in: frame)
                        if let shared, shared != mask { throw PackError("Screens differ between finishes of \(view.name)") }
                        shared = mask
                        for y in view.screen.top..<view.screen.bottom {
                            for x in view.screen.left..<view.screen.right {
                                let index = (y * frame.width + x) * 4
                                if frame.pixels[index + 3] <= TrimPack.noiseAlpha {
                                    for c in 0..<4 { frame.pixels[index + c] = 0 }
                                }
                            }
                        }
                        try frame.write(to: raw.appending(path: "\(view.name) \(color).png"),
                                        iccProfile: PNGData.iccProfile(of: source))
                    }
                }
                try PackStorage.write(new, version: version, to: raw)
                let report = try TrimPack.build(source: raw, output: cropped, version: version)
                new = try PackStorage.readCatalog(in: cropped)
                for field in new.fields where field.key != "variants" {
                    guard catalog[field.key] == nil else { throw PackError("Base already defines width \(field.key)") }
                    catalog[field.key] = field.value
                }
                if let variants = new["variants"]?.object {
                    for field in variants.fields {
                        if let entry = field.value.object { try catalog.addVariant(field.key, entry: entry) }
                    }
                }
                try PackStorage.copy(base, to: stage) { $0 != catalogFile && $0 != versionFile }
                let rows = try PackStorage.contents(of: cropped).filter { $0.pathExtension == "png" }.map { file in
                    let destination = stage.appending(path: file.lastPathComponent)
                    guard !PackStorage.files.fileExists(atPath: destination.path) else {
                        throw PackError("Base already contains \(file.lastPathComponent)")
                    }
                    return try PackOptimizer.optimize(file, to: destination)
                }
                try PackStorage.write(catalog, version: version, to: stage)
                print("Added \(rows.count) frames (\(rows.map(\.bytes).reduce(0, +)) bytes); built \(output.path)")
                return .object([
                    "sources": .object([
                        "ipad_specs": "https://www.apple.com/ipad-mini/specs/",
                        "watch_specs": "https://www.apple.com/apple-watch-ultra-4/specs/",
                        "ipad_artwork": "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-mini-(A20-Pro).dmg",
                        "watch_artwork": "https://devimages-cdn.apple.com/design/resources/download/Bezel-Apple-Watch-Ultra-4-2026.dmg",
                    ]),
                    "devices": report.deviceJSON, "entries": .object(new), "frames": .array(rows.map(\.json)),
                ])
            }
        }
    }
}
#endif

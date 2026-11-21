#if os(macOS)
import Foundation

struct Point: Equatable, Sendable {
    let x: Double
    let y: Double
    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    var json: JSONValue { .array([.double(x), .double(y)]) }
}

struct WarpQuad: Equatable, Sendable {
    let polygon: [Point]
    let source: [Point]

    static func parse(_ descriptor: Data) throws -> [WarpQuad] {
        var place = ByteCursor(data: descriptor)
        guard place.seekAfter("nonAffineTransformVlLs") else { throw PackError("Missing Smart Object placement") }
        try place.skip(4)
        let end = place.offset + 96
        var values: [Double] = []
        while place.seekAfter("doub", limit: end) { values.append(try place.floatingPoint()) }
        guard values.count == 8 else { throw PackError("Unexpected Smart Object placement") }
        let xs = stride(from: 0, to: 8, by: 2).map { values[$0] }
        let ys = stride(from: 1, to: 8, by: 2).map { values[$0] }
        let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
        guard left < right, top < bottom,
              xs.allSatisfy({ min(abs($0 - left), abs($0 - right)) <= 0.01 }),
              ys.allSatisfy({ min(abs($0 - top), abs($0 - bottom)) <= 0.01 }) else {
            throw PackError("Expected an axis-aligned placed Smart Object")
        }

        let before = try points(descriptor, key: "vertices").map {
            Point(($0.x - left) / (right - left), ($0.y - top) / (bottom - top))
        }
        let after = try points(descriptor, key: "warpedVertices")
        var cursor = ByteCursor(data: descriptor)
        var quads: [WarpQuad] = []
        while cursor.seekAfter("indicesVlLs") {
            guard try cursor.psd(UInt32.self) == 4 else { throw PackError("Unexpected Perspective Warp indices") }
            let indexes = try (0..<4).map { _ -> Int in
                guard try cursor.take(4) == Data("long".utf8) else { throw PackError("Malformed Perspective Warp index") }
                let index = Int(try cursor.psd(UInt32.self))
                guard after.indices.contains(index) else { throw PackError("Perspective Warp index is out of bounds") }
                return index
            }
            quads.append(WarpQuad(polygon: indexes.map { after[$0] }, source: indexes.map { before[$0] }))
        }
        guard quads.count == 3 else { throw PackError("Unexpected Perspective Warp geometry") }
        return quads
    }

    private static func points(_ descriptor: Data, key: String) throws -> [Point] {
        var cursor = ByteCursor(data: descriptor)
        guard cursor.seekAfter(key + "VlLs"), try cursor.psd(UInt32.self) == 8 else {
            throw PackError("Unexpected Perspective Warp vertex count")
        }
        return try (0..<8).map { _ in
            guard cursor.seekAfter("HrznUntF#Pxl") else { throw PackError("Missing horizontal warp coordinate") }
            let x = try cursor.floatingPoint()
            guard try cursor.psd(UInt32.self) == 0, try cursor.take(12) == Data("VrtcUntF#Pxl".utf8) else {
                throw PackError("Missing vertical warp coordinate")
            }
            let y = try cursor.floatingPoint()
            return Point((x * 1e9).rounded(.toNearestOrEven) / 1e9, (y * 1e9).rounded(.toNearestOrEven) / 1e9)
        }
    }
}

struct WarpRegion: Sendable {
    struct Scale {
        var peak = 0.0
        var lowest = Double.infinity
        var across = 0.0
        var down = 0.0
    }

    let points: [Point]
    let inverse: [Double]

    init(quad: WarpQuad, canvas: Size, scaled: Size, crop: Box) throws {
        let polygon = quad.polygon.map {
            Point($0.x * Double(scaled.width) / Double(canvas.width) - Double(crop.left),
                  $0.y * Double(scaled.height) / Double(canvas.height) - Double(crop.top))
        }
        points = polygon
        inverse = try Self.solve(canvas: crop.size, polygon: polygon, source: quad.source)
    }

    private static func solve(canvas: Size, polygon: [Point], source: [Point]) throws -> [Double] {
        guard polygon.count == 4, source.count == 4 else { throw PackError("Expected four points per Perspective Warp region") }
        let width = Double(canvas.width), height = Double(canvas.height)
        var rows: [[Double]] = []
        for (pixel, unit) in zip(polygon, source) {
            let x = pixel.x / width, y = pixel.y / height, u = unit.x, v = unit.y
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for index in 0..<8 {
            guard let pivot = (index..<8).max(by: { abs(rows[$0][index]) < abs(rows[$1][index]) }) else {
                throw PackError("Could not solve perspective")
            }
            rows.swapAt(index, pivot)
            let divisor = rows[index][index]
            guard divisor.isFinite, abs(divisor) > 1e-15 else { throw PackError("Degenerate Perspective Warp region") }
            let basis = rows[index].map { $0 / divisor }
            rows[index] = basis
            for i in 0..<8 where i != index {
                let factor = rows[i][index]
                rows[i] = zip(rows[i], basis).map { $0 - factor * $1 }
            }
        }
        let values = rows.map { $0[8] }
        let divisions = [width, height, 1, width, height, 1, width, height]
        return zip(values, divisions).map(/)
    }

    func scale(for native: Size) throws -> Scale {
        let a = inverse[0], b = inverse[1], c = inverse[2], d = inverse[3]
        let e = inverse[4], f = inverse[5], g = inverse[6], h = inverse[7]
        let width = Double(native.width), height = Double(native.height)
        var result = Scale()
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            for step in 0..<32 {
                let x = p.x + (q.x - p.x) * Double(step) / 32
                let y = p.y + (q.y - p.y) * Double(step) / 32
                let w = g * x + h * y + 1
                let u = (a * x + b * y + c) / w, v = (d * x + e * y + f) / w
                let ux = (a - u * g) / w * width, uy = (b - u * h) / w * width
                let vx = (d - v * g) / w * height, vy = (e - v * h) / w * height
                let determinant = ux * vy - uy * vx
                guard determinant != 0, determinant.isFinite else { throw PackError("Invalid Perspective Warp scale") }
                let xu = vy / determinant, xv = -uy / determinant, yu = -vx / determinant, yv = ux / determinant
                let half = (xu * xu + xv * xv + yu * yu + yv * yv) / 2
                let cross = xu * yv - xv * yu
                let spread = sqrt(max(0, half * half - cross * cross))
                result.peak = max(result.peak, sqrt(half + spread))
                result.lowest = min(result.lowest, sqrt(max(0, half - spread)))
                result.across = max(result.across, hypot(xu, yu))
                result.down = max(result.down, hypot(xv, yv))
            }
        }
        return result
    }

    func json(scale: Scale, native: Size) -> JSONValue {
        func rounded(_ value: Double) -> JSONValue { .double((value * 100).rounded(.toNearestOrEven) / 100) }
        return .object(["polygon": .array(points.map(\.json)), "inverse": .array(inverse.map(JSONValue.double)),
                        "extent": .array([rounded(scale.across * Double(native.width)), rounded(scale.down * Double(native.height))])])
    }
}

enum FoldedArtwork {
    private static let cameraLayerNames = ["black", "dark", "light"]
    static let variants: [(orientation: String, inputs: [Size])] = [
        ("Landscape", [Size(2853, 2007), Size(2670, 1878)]),
        ("Portrait", [Size(2007, 2853), Size(1878, 2670)]),
    ]

    private struct Camera: Equatable {
        let x: Int
        let y: Int
        let ranges: [[UInt8]]

        func json(in crop: Box) -> JSONValue {
            .object(["x": .number(String(x - crop.left)), "y": .number(String(y - crop.top)),
                     "blendIf": .array(ranges.map { .array($0.map { .number(String($0)) }) })])
        }
    }

    private struct Geometry: Equatable {
        let canvas: Size
        let quads: [WarpQuad]
        let size: Size
        let mask: Raster
        let strip: Raster
        let camera: Camera
    }

    static func fittedSize(quads: [WarpQuad], canvas: Size, native: Size) throws -> Size {
        let peak = try quads.map {
            try WarpRegion(quad: $0, canvas: canvas, scaled: canvas, crop: Box(canvas)).scale(for: native).peak
        }.max() ?? 0
        guard peak > 0, peak.isFinite, Double(canvas.width) / peak <= 50_000, Double(canvas.height) / peak <= 50_000 else {
            throw PackError("Invalid fitted PSD dimensions")
        }
        let size = Size(Int(Double(canvas.width) / peak), Int(Double(canvas.height) / peak))
        try size.validate()
        return size
    }

    private static func reflection(_ preview: Raster, vertical: Bool) throws -> [UInt8] {
        let gray = try preview.grayscale.resized(to: Size(1400, 1125), filter: .box)
        func median(_ samples: [UInt8]) -> UInt8 {
            let values = samples.sorted()
            let mean = (Double(values[1]) + Double(values[2])) / 2
            return UInt8(mean.rounded(.toNearestOrEven))
        }
        let values: [UInt8]
        let padding: Int
        if vertical {
            let sample = try gray.resized(to: Size(1400, 375), filter: .box)
            values = (40..<335).map { y in median([240, 300, 1100, 1160].map { sample.pixels[y * 1400 + $0] }) }
            padding = 40
        } else {
            let sample = try gray.resized(to: Size(100, 1125), filter: .box)
            values = (25..<75).map { x in median([200, 275, 850, 930].map { sample.pixels[$0 * 100 + x] }) }
            padding = 25
        }
        let padded = Array(repeating: values[0], count: padding) + values + Array(repeating: values.last!, count: padding)
        return padded.map { $0 > values[0] ? $0 - values[0] : 0 }
    }

    private static func canvasLayer(_ layer: PhotoshopArtwork.Layer, canvas: Size, output: Size) throws -> Raster {
        guard let image = layer.image else { throw PackError("Expected a layer with RGBA data") }
        var raster = Raster(size: canvas, channels: 4)
        raster.paste(image, x: layer.box.left, y: layer.box.top, transparentClears: false)
        return try raster.resized(to: output, filter: .lanczos)
    }

    private static func camera(_ artwork: PhotoshopArtwork, to scaling: Size) throws -> (Raster, Camera) {
        let layers = try cameraLayerNames.map { name in
            guard let layer = artwork.layers[name], layer.blendIf.count == 4 else {
                throw PackError("Missing camera layer or Photoshop Blend If thresholds: \(name)")
            }
            return layer
        }
        let images = try layers.map { try canvasLayer($0, canvas: artwork.canvas, output: scaling) }
        let boxes = try images.map { image in
            guard let box = image.alpha.bounds else { throw PackError("Empty camera layer") }
            return box
        }
        let bounds = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        let width = bounds.size.width
        var strip = Raster(size: Size(width * images.count, bounds.size.height), channels: 4)
        for (index, image) in images.enumerated() { strip.paste(image.crop(bounds), x: index * width, y: 0) }
        return (strip, Camera(x: bounds.left, y: bounds.top, ranges: layers.map(\.blendIf)))
    }

    static func buildView(source: URL, stage: URL, orientation: String, inputs: [Size]) throws -> OrderedObject {
        guard let native = inputs.first else { throw PackError("Missing native Duo capture size") }
        let name = "iPhone Duo Inner Partially Open \(orientation)"
        let vertical = orientation == "Portrait"
        var geometry: Geometry?
        var frames: [(String, Raster)] = []
        var reflections: OrderedObject = [:]
        var profileCount = 0
        for color in FlatArtwork.duoColors {
            let url = source.appending(path: "iPhone Duo - \(color) - Inner Partially Open \(orientation).psd")
            let artwork = try PhotoshopArtwork(url: url, imageLayers: Set(cameraLayerNames + ["hardware"]),
                                               maskLayers: ["screen content"])
            guard let screen = artwork.layers["screen content"], let descriptor = screen.descriptor,
                  let mask = screen.mask, let hardware = artwork.layers["hardware"] else {
                throw PackError("Template is missing its screen, mask, or hardware layer: \(url.lastPathComponent)")
            }
            let quads = try WarpQuad.parse(descriptor)
            let size = try fittedSize(quads: quads, canvas: artwork.canvas, native: native)
            let profile = try reflection(artwork.preview, vertical: vertical)
            profileCount = profile.count
            reflections[color] = .array(profile.map { .number(String($0)) })
            let (strip, cameraData) = try camera(artwork, to: size)
            let shared = Geometry(canvas: artwork.canvas, quads: quads, size: size,
                                  mask: try mask.resized(to: size, filter: .box), strip: strip, camera: cameraData)
            if let geometry, geometry != shared {
                throw PackError("\(orientation) finishes disagree on geometry, display mask, or camera")
            }
            geometry = shared
            frames.append((color, try canvasLayer(hardware, canvas: artwork.canvas, output: size)))
        }
        guard let geometry else { throw PackError("Missing Duo finishes") }
        let alphas = frames.map { $0.1.alpha }
        let crop = try TrimPack.unionBounds(alphas, name: name)
        let dropped = alphas.map { TrimPack.dropped($0, outside: crop).maximum }.max() ?? 0
        for (color, frame) in frames { try frame.crop(crop).write(to: stage.appending(path: "\(name) \(color).png")) }
        try geometry.mask.crop(crop).write(to: stage.appending(path: "\(name)_mask.png"))
        try geometry.strip.write(to: stage.appending(path: "\(name)_camera.png"))
        var regions: [JSONValue] = []
        for quad in geometry.quads {
            let region = try WarpRegion(quad: quad, canvas: geometry.canvas, scaled: geometry.size, crop: crop)
            let scale = try region.scale(for: native)
            guard scale.peak <= 1 else { throw PackError("A \(native) screenshot would be magnified \(scale.peak)x") }
            regions.append(region.json(scale: scale, native: native))
        }
        let scale = Double(profileCount) / Double(vertical ? geometry.size.height : geometry.size.width)
        let span = [.double(Double(vertical ? crop.top : crop.left) * scale),
                    JSONValue.double(Double(vertical ? crop.bottom : crop.right) * scale)]
        var warp: OrderedObject = ["inputSizes": .array(inputs.map(\.json)), "regions": .array(regions),
                                   "reflections": .object(reflections), "reflectionSpan": .array(span),
                                   "camera": geometry.camera.json(in: crop)]
        if vertical {
            warp["blend"] = "normal"
            warp["reflectionAxis"] = "y"
        }
        var entry: OrderedObject = ["name": .string(name), "x": "0", "y": "0", "mask": "yes", "colors": "yes", "warp": .object(warp)]
        if !vertical { entry["physicalHeight"] = .double(117.8) }
        print("\(name) \(geometry.canvas) → \(geometry.size) → \(crop.size), strongest cropped alpha \(dropped)")
        return entry
    }

    static func build(source: URL, base: URL, output: URL, archive: URL?) throws {
        var catalog = try PackStorage.readCatalog(in: base)
        for view in variants where catalog["variants"]?.object?["iPhone Duo Inner Partially Open \(view.orientation)"] != nil {
            throw PackError("Base already defines iPhone Duo Inner Partially Open \(view.orientation)")
        }
        try PackStorage.stage(output: output, archive: archive) { stage in
            try PackStorage.copy(base, to: stage)
            for view in variants {
                let entry = try buildView(source: source, stage: stage, orientation: view.orientation, inputs: view.inputs)
                try catalog.addVariant("iPhone Duo Inner Partially Open \(view.orientation)", entry: entry)
            }
            try JSONValue.object(catalog).encoded().write(to: stage.appending(path: catalogFile), options: .atomic)
            try FlatArtwork.copyLicense(from: source, to: stage, replace: true)
        }
    }
}
#endif

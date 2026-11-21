#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import zlib

struct Size: Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int
    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
    var description: String { "\(width)x\(height)" }
    var json: JSONValue { .array([.number(String(width)), .number(String(height))]) }

    func validate() throws {
        guard (1...50_000).contains(width), (1...50_000).contains(height), width * height <= 50_000_000 else {
            throw PackError("Invalid artwork dimensions: \(self)")
        }
    }
}

struct Box: Equatable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
    init(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
    init(_ size: Size) { self.init(0, 0, size.width, size.height) }
    var size: Size { Size(right - left, bottom - top) }
    var json: JSONValue { .array([left, top, right, bottom].map { .number(String($0)) }) }

    func contains(_ other: Self) -> Bool {
        left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom
    }

    func union(_ other: Self) -> Self {
        Self(min(left, other.left), min(top, other.top), max(right, other.right), max(bottom, other.bottom))
    }
}

struct Raster: Equatable, Sendable {
    enum Filter { case box, lanczos }

    let size: Size
    let channels: Int
    var pixels: [UInt8]
    var width: Int { size.width }
    var height: Int { size.height }

    init(size: Size, channels: Int, value: UInt8 = 0) {
        self.init(size: size, channels: channels, pixels: [UInt8](repeating: value, count: size.width * size.height * channels))
    }

    init(size: Size, channels: Int, pixels: [UInt8]) {
        self.size = size
        self.channels = channels
        self.pixels = pixels
    }

    init(url: URL) throws { try self.init(png: Data(contentsOf: url)) }

    init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) == "public.png" as CFString,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PackError("Could not read PNG artwork")
        }
        let size = Size(image.width, image.height)
        try size.validate()
        let transparency: [UInt8]
        if image.colorSpace?.model == .indexed {
            transparency = try PNGData.inspect(png, validateCRC: false)
                .first(where: { $0.type == "tRNS" }).map { Array($0.contents) } ?? []
        } else {
            transparency = []
        }
        let rgba = Self.rgba(image, paletteAlpha: transparency)
        self.init(size: size, channels: 4, pixels: rgba)
    }

    private static func rgba(_ image: CGImage, paletteAlpha: [UInt8]) -> [UInt8] {
        let width = image.width
        let height = image.height
        if let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * height {
            let bytes = CFDataGetBytePtr(data)!
            let alpha = image.alphaInfo
            let count = image.bitsPerPixel / 8
            let space = image.colorSpace
            let rgb = space?.model == .rgb
            let mono = space?.model == .monochrome
            let indexed = space?.model == .indexed

            if indexed, let space, [1, 2, 4, 8].contains(image.bitsPerPixel),
               let base = space.baseColorSpace, base.model == .rgb, let palette = space.colorTable {
                let bits = image.bitsPerPixel
                let mask = (1 << bits) - 1
                var output = [UInt8]()
                output.reserveCapacity(width * height * 4)
                for y in 0..<height {
                    for x in 0..<width {
                        let index = (Int(bytes[y * image.bytesPerRow + x * bits / 8]) >> (8 - bits - x * bits % 8)) & mask
                        let start = index * 3
                        if start + 2 < palette.count { output.append(contentsOf: palette[start..<(start + 3)]) }
                        else { output.append(contentsOf: [0, 0, 0]) }
                        output.append(paletteAlpha.indices.contains(index) ? paletteAlpha[index] : 255)
                    }
                }
                return output
            }

            if image.bitsPerComponent == 8, (rgb && (3...4).contains(count)) || (mono && (1...2).contains(count)) {
                let first = alpha == .first || alpha == .noneSkipFirst || alpha == .premultipliedFirst
                let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
                let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
                let reverse = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
                var result = [UInt8](repeating: 255, count: width * height * 4)
                for y in 0..<height {
                    for x in 0..<width {
                        let start = y * image.bytesPerRow + x * count
                        let destination = (y * width + x) * 4
                        func channel(_ index: Int) -> UInt8 { bytes[start + (reverse ? count - index - 1 : index)] }
                        let value = opaque ? 255 : channel(first ? 0 : count - 1)
                        let offset = first ? 1 : 0
                        for c in 0..<3 {
                            let sample = channel(offset + (rgb ? c : 0))
                            result[destination + c] = premultiplied ? Self.unpremultiply(sample, by: value) : sample
                        }
                        result[destination + 3] = value
                    }
                }
                return result
            }
        }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        output.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for index in stride(from: 0, to: output.count, by: 4) {
            let alpha = output[index + 3]
            for channel in 0..<3 { output[index + channel] = unpremultiply(output[index + channel], by: alpha) }
        }
        return output
    }

    static func unpremultiply(_ value: UInt8, by alpha: UInt8) -> UInt8 {
        alpha == 0 || alpha == 255 ? value : UInt8(clamping: Int(value) * 255 / Int(alpha))
    }

    var alpha: Raster {
        Raster(size: size, channels: 1, pixels: stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] })
    }

    var grayscale: Raster {
        let gray = stride(from: 0, to: pixels.count, by: 4).map { i in
            UInt8((Int(pixels[i]) * 19595 + Int(pixels[i + 1]) * 38470 + Int(pixels[i + 2]) * 7471 + 32768) >> 16)
        }
        return Raster(size: size, channels: 1, pixels: gray)
    }

    var bounds: Box? {
        var left = width, top = height, right = 0, bottom = 0
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] != 0 {
                left = min(left, x)
                right = max(right, x + 1)
                top = min(top, y)
                bottom = max(bottom, y + 1)
            }
        }
        return left < right ? Box(left, top, right, bottom) : nil
    }

    func crop(_ box: Box) -> Raster {
        precondition(Box(size).contains(box))
        var result: [UInt8] = []
        result.reserveCapacity(box.size.width * box.size.height * channels)
        for y in box.top..<box.bottom {
            let offset = (y * width + box.left) * channels
            result.append(contentsOf: pixels[offset..<(offset + box.size.width * channels)])
        }
        return Raster(size: box.size, channels: channels, pixels: result)
    }

    func rotatedCounterclockwise() -> Raster {
        var rotated = Raster(size: Size(height, width), channels: channels)
        for y in 0..<height {
            for x in 0..<width {
                let input = (y * width + x) * channels
                let output = ((width - 1 - x) * height + y) * channels
                for c in 0..<channels { rotated.pixels[output + c] = pixels[input + c] }
            }
        }
        return rotated
    }

    mutating func paste(_ image: Raster, x: Int, y: Int, transparentClears: Bool = true) {
        precondition(image.channels == channels)
        let left = max(0, x)
        let right = min(width, x + image.width)
        let top = max(0, y)
        let bottom = min(height, y + image.height)
        guard left < right, top < bottom else { return }
        let count = (right - left) * channels
        for row in top..<bottom {
            let source = ((row - y) * image.width + left - x) * channels
            let output = (row * width + left) * channels
            if transparentClears {
                pixels.replaceSubrange(output..<(output + count), with: image.pixels[source..<(source + count)])
            } else {
                for offset in stride(from: 0, to: count, by: 4) where image.pixels[source + offset + 3] != 0 {
                    for c in 0..<4 { pixels[output + offset + c] = image.pixels[source + offset + c] }
                }
            }
        }
    }

    mutating func fill(x: Int, y: Int, with value: UInt8) {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return }
        let seed = y * width + x
        let original = pixels[seed]
        guard original != value else { return }
        var queue = [UInt32(seed)]
        pixels[seed] = value
        var cursor = 0
        while cursor < queue.count {
            let index = Int(queue[cursor])
            cursor += 1
            func visit(_ adjacent: Int) {
                if pixels[adjacent] == original {
                    pixels[adjacent] = value
                    queue.append(UInt32(adjacent))
                }
            }
            if index >= width { visit(index - width) }
            if index + width < pixels.count { visit(index + width) }
            if index % width != 0 { visit(index - 1) }
            if index % width != width - 1 { visit(index + 1) }
        }
    }

    func resized(to output: Size, filter: Filter, source: [Double]? = nil) throws -> Raster {
        try output.validate()
        let area = source ?? [0, 0, Double(width), Double(height)]
        // The legacy image kernel rounded its source box to Float before sampling.
        let bounds = area.map { Double(Float($0)) }
        guard bounds.count == 4, bounds[0] >= 0, bounds[1] >= 0, bounds[2] <= Double(width),
              bounds[3] <= Double(height), bounds[2] > bounds[0], bounds[3] > bounds[1] else {
            throw PackError("Invalid image resize box")
        }
        if output == size, area == [0, 0, Double(width), Double(height)] { return self }

        var samples = pixels
        if channels == 4 {
            for i in stride(from: 0, to: samples.count, by: 4) {
                let alpha = Int(samples[i + 3])
                for c in 0..<3 { samples[i + c] = UInt8((Int(samples[i + c]) * alpha + 127) / 255) }
            }
        }
        let horizontal = taps(input: width, output: output.width, lower: bounds[0], upper: bounds[2], filter: filter)
        let vertical = taps(input: height, output: output.height, lower: bounds[1], upper: bounds[3], filter: filter)
        let rowWidth = output.width * channels
        var intermediate = [UInt8](repeating: 0, count: rowWidth * height)
        for y in 0..<height {
            let row = y * width * channels
            for (x, tap) in horizontal.enumerated() {
                let src = row + tap.start * channels
                for channel in 0..<channels {
                    var value = 1 << 21
                    for i in tap.weights.indices { value += Int(samples[src + i * channels + channel]) * tap.weights[i] }
                    intermediate[y * rowWidth + x * channels + channel] = UInt8(clamping: value >> 22)
                }
            }
        }
        var result = [UInt8](repeating: 0, count: rowWidth * output.height)
        for (y, tap) in vertical.enumerated() {
            let src = tap.start * rowWidth
            for x in 0..<rowWidth {
                var value = 1 << 21
                for i in tap.weights.indices { value += Int(intermediate[src + i * rowWidth + x]) * tap.weights[i] }
                result[y * rowWidth + x] = UInt8(clamping: value >> 22)
            }
        }
        if channels == 4 {
            for i in stride(from: 0, to: result.count, by: 4) {
                let alpha = result[i + 3]
                for c in 0..<3 { result[i + c] = Self.unpremultiply(result[i + c], by: alpha) }
            }
        }
        return Raster(size: output, channels: channels, pixels: result)
    }

    private struct Tap {
        let start: Int
        let weights: [Int]
    }

    private func taps(input: Int, output: Int, lower: Double, upper: Double, filter: Filter) -> [Tap] {
        let scale = (upper - lower) / Double(output)
        let kernelScale = max(1, scale)
        let support = (filter == .box ? 0.5 : 3) * kernelScale
        return (0..<output).map { index in
            let center = lower + (Double(index) + 0.5) * scale
            let start = max(0, Int(center - support + 0.5))
            let end = min(input, Int(center + support + 0.5))
            let weights = (start..<end).map { sample in
                let coordinate = (Double(sample) - center + 0.5) * (1 / kernelScale)
                switch filter {
                case .box:
                    return coordinate > -0.5 && coordinate <= 0.5 ? 1.0 : 0.0
                case .lanczos:
                    guard coordinate >= -3, coordinate < 3 else { return 0.0 }
                    func sinc(_ value: Double) -> Double {
                        if value == 0 { return 1 }
                        let angle = value * .pi
                        return sin(angle) / angle
                    }
                    return sinc(coordinate) * sinc(coordinate / 3)
                }
            }
            let total = weights.reduce(0, +)
            return Tap(start: start, weights: weights.map { total == 0 ? 0 : Int(($0 / total * Double(1 << 22)).rounded()) })
        }
    }

    func png(iccProfile: Data? = nil) throws -> Data {
        let length = width * channels
        var rows = Data()
        rows.reserveCapacity((length + 1) * height)
        for y in 0..<height {
            let start = y * length
            var sub = [UInt8](repeating: 0, count: length)
            var up = [UInt8](repeating: 0, count: length)
            var subScore = 0
            var upScore = 0
            for x in 0..<length {
                let sample = pixels[start + x]
                sub[x] = sample &- (x < channels ? 0 : pixels[start + x - channels])
                up[x] = sample &- (y == 0 ? 0 : pixels[start + x - length])
                subScore += abs(Int(Int8(bitPattern: sub[x])))
                upScore += abs(Int(Int8(bitPattern: up[x])))
            }
            rows.append(subScore < upScore ? UInt8(1) : UInt8(2))
            rows.append(contentsOf: subScore < upScore ? sub : up)
        }
        let compressed = try PNGData.compress(rows)
        var header = Data()
        header.append(UInt32(width), bigEndian: true)
        header.append(UInt32(height), bigEndian: true)
        header.append(contentsOf: [8, channels == 1 ? 0 : 6, 0, 0, 0])
        var output = PNGData.signature
        output.append(PNGData.chunk("IHDR", data: header))
        if let iccProfile { output.append(PNGData.chunk("iCCP", data: iccProfile)) }
        output.append(PNGData.chunk("IDAT", data: compressed))
        output.append(PNGData.chunk("IEND", data: Data()))
        return output
    }

    func write(to url: URL, iccProfile: Data? = nil) throws {
        try png(iccProfile: iccProfile).write(to: url, options: .atomic)
    }
}

enum PNGData {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let descriptive: Set<String> = ["iTXt", "tEXt", "zTXt", "eXIf", "pHYs", "tIME"]
    private static let profiles: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP"]

    static func inspect(_ bytes: Data, validateCRC: Bool = true) throws -> [(type: String, contents: Data)] {
        guard bytes.starts(with: signature) else { throw PackError("Missing PNG signature") }
        var reader = ByteCursor(data: bytes, offset: signature.count)
        var chunks: [(type: String, contents: Data)] = []
        while reader.remaining > 0 {
            let size = Int(try reader.read(UInt32.self, bigEndian: true))
            let typeAndBody = try reader.take(size + 4)
            let crc = try reader.read(UInt32.self, bigEndian: true)
            guard !validateCRC || crc == typeAndBody.crc32Value else { throw PackError("Invalid PNG chunk checksum") }
            let type = String(decoding: typeAndBody.prefix(4), as: UTF8.self)
            chunks.append((type, Data(typeAndBody.dropFirst(4))))
            if type == "IEND" { break }
        }
        guard chunks.first?.type == "IHDR", chunks.first?.contents.count == 13,
              chunks.contains(where: { $0.type == "IDAT" }), chunks.last?.type == "IEND",
              chunks.last?.contents.isEmpty == true, reader.remaining == 0 else { throw PackError("Invalid PNG structure") }
        return chunks
    }

    static func iccProfile(of url: URL) throws -> Data? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try inspect(data, validateCRC: false).first { $0.type == "iCCP" }?.contents
    }

    static func optimize(_ bytes: Data, raster: Raster) throws -> Data {
        let chunks = try inspect(bytes)
        var result = signature
        for item in chunks where !descriptive.contains(item.type) { result.append(chunk(item.type, data: item.contents)) }
        if profiles.isDisjoint(with: chunks.map(\.type)) {
            let clean = try raster.png()
            if clean.count < result.count { result = clean }
        }
        guard try Raster(png: result) == raster else { throw PackError("Lossless optimization changed image pixels") }
        return result
    }

    static func chunk(_ type: String, data: Data) -> Data {
        let contents = Data(type.utf8) + data
        var result = Data()
        result.append(UInt32(data.count), bigEndian: true)
        result.append(contents)
        result.append(contents.crc32Value, bigEndian: true)
        return result
    }

    static func compress(_ data: Data) throws -> Data {
        let capacity = compressBound(uLong(data.count))
        var size = capacity
        var output = Data(count: Int(capacity))
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress, &size, source.bindMemory(to: UInt8.self).baseAddress,
                          uLong(data.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw PackError("Could not compress PNG") }
        output.count = Int(size)
        return output
    }
}
#endif

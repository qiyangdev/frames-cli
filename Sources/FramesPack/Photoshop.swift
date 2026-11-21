#if os(macOS)
import Foundation

struct PhotoshopArtwork {
    struct Layer {
        let box: Box
        let image: Raster?
        let mask: Raster?
        let blendIf: [UInt8]
        let descriptor: Data?
    }

    let canvas: Size
    let layers: [String: Layer]
    let preview: Raster

    private struct Record {
        let name: String
        let box: Box
        let channels: [(id: Int16, length: Int)]
        let mask: Data
        let blendIf: [UInt8]
        let descriptor: Data?
    }

    init(url: URL, imageLayers: Set<String>, maskLayers: Set<String>) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var file = ByteCursor(data: data)
        guard try file.take(4) == Data("8BPS".utf8), try file.psd(UInt16.self) == 1 else {
            throw PackError("Expected a PSD template: \(url.lastPathComponent)")
        }
        try file.skip(6)
        let channelCount = Int(try file.psd(UInt16.self))
        let height = Int(try file.psd(UInt32.self)), width = Int(try file.psd(UInt32.self))
        canvas = Size(width, height)
        try canvas.validate()
        guard (3...16).contains(channelCount), try file.psd(UInt16.self) == 8, try file.psd(UInt16.self) == 3 else {
            throw PackError("Expected an 8-bit RGB PSD: \(url.lastPathComponent)")
        }
        for _ in 0..<2 {
            let length = try file.length()
            try file.skip(length)
        }

        let sectionEnd = try file.sectionEnd()
        let infoEnd = try file.sectionEnd()
        guard infoEnd <= sectionEnd else { throw PackError("Invalid PSD layer section") }
        let count = abs(Int(try file.psd(Int16.self)))
        var records: [Record] = []
        for _ in 0..<count {
            let box = try file.box()
            let count = Int(try file.psd(UInt16.self))
            guard count <= 64 else { throw PackError("Invalid PSD channel count") }
            var channels: [(Int16, Int)] = []
            for _ in 0..<count {
                let id = try file.psd(Int16.self)
                channels.append((id, try file.length()))
            }
            try file.skip(12)
            let end = try file.sectionEnd()
            guard end <= infoEnd else { throw PackError("Invalid PSD layer record") }
            let maskLength = try file.length()
            let mask = try file.take(maskLength)
            let rangeLength = try file.length()
            let ranges = try file.take(rangeLength)
            let labelLength = Int(try file.psd(UInt8.self))
            let label = try file.take(labelLength)
            guard let name = String(data: label, encoding: .macOSRoman)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                throw PackError("Invalid PSD layer name")
            }
            try file.skip((4 - (labelLength + 1) % 4) % 4)
            var descriptor: Data?
            while file.offset < end {
                guard try file.take(4) == Data("8BIM".utf8) else { throw PackError("Unexpected PSD layer data") }
                let key = try file.take(4)
                let length = try file.length()
                let block = try file.take(length)
                if key == Data("SoLd".utf8) { descriptor = block }
                try file.skip(length % 2)
            }
            guard file.offset == end else { throw PackError("Invalid PSD layer data size") }
            records.append(Record(name: name, box: box, channels: channels, mask: mask,
                                  blendIf: Array(ranges.dropFirst(4).prefix(4)), descriptor: descriptor))
        }

        var layers: [String: Layer] = [:]
        for record in records {
            var planes: [Int16: Raster] = [:]
            var mask: Raster?
            let needsImage = imageLayers.contains(record.name)
            let needsMask = maskLayers.contains(record.name)
            let size = record.box.size
            for channel in record.channels {
                guard channel.length <= infoEnd - file.offset else { throw PackError("Truncated PSD layer channel") }
                if needsMask, channel.id == -2 {
                    var contents = ByteCursor(data: try file.take(channel.length))
                    var metadata = ByteCursor(data: record.mask)
                    let box = try metadata.box()
                    let fill = try metadata.psd(UInt8.self)
                    var plane = Raster(size: canvas, channels: 1, value: fill)
                    let decoded = try Self.channel(&contents, size: box.size)
                    plane.paste(decoded, x: box.left, y: box.top)
                    mask = plane
                } else if needsImage, [0, 1, 2, -1].contains(channel.id), size.width > 0, size.height > 0 {
                    var contents = ByteCursor(data: try file.take(channel.length))
                    planes[channel.id] = try Self.channel(&contents, size: size)
                } else {
                    try file.skip(channel.length)
                }
            }
            let image = planes[0] == nil ? nil : try Self.rgb(planes, size: size, hasAlpha: true)
            layers[record.name] = Layer(box: record.box, image: image, mask: mask,
                                        blendIf: record.blendIf, descriptor: record.descriptor)
        }
        self.layers = layers
        file.offset = sectionEnd
        guard try file.psd(UInt16.self) == 1 else { throw PackError("Expected a PackBits PSD preview") }
        var lengths: [[Int]] = []
        for _ in 0..<channelCount {
            lengths.append(try (0..<height).map { _ in Int(try file.psd(UInt16.self)) })
        }
        var planes: [Int16: Raster] = [:]
        for (index, rows) in lengths.prefix(3).enumerated() {
            planes[Int16(index)] = try Self.packBits(&file, size: canvas, rows: rows)
        }
        preview = try Self.rgb(planes, size: canvas, hasAlpha: false)
    }

    private static func rgb(_ planes: [Int16: Raster], size: Size, hasAlpha: Bool) throws -> Raster {
        guard let red = planes[0], let green = planes[1], let blue = planes[2], !hasAlpha || planes[-1] != nil else {
            throw PackError("PSD layer is missing RGB or alpha channels")
        }
        let alpha = planes[-1]
        var rgba = Raster(size: size, channels: 4, value: 255)
        for i in red.pixels.indices {
            rgba.pixels[4 * i] = red.pixels[i]
            rgba.pixels[4 * i + 1] = green.pixels[i]
            rgba.pixels[4 * i + 2] = blue.pixels[i]
            if let alpha { rgba.pixels[4 * i + 3] = alpha.pixels[i] }
        }
        return rgba
    }

    private static func channel(_ reader: inout ByteCursor, size: Size) throws -> Raster {
        try size.validate()
        switch try reader.psd(UInt16.self) {
        case 0:
            return Raster(size: size, channels: 1, pixels: Array(try reader.take(size.width * size.height)))
        case 1:
            let rows = try (0..<size.height).map { _ in Int(try reader.psd(UInt16.self)) }
            return try packBits(&reader, size: size, rows: rows)
        default:
            throw PackError("Unsupported PSD channel compression")
        }
    }

    private static func packBits(_ reader: inout ByteCursor, size: Size, rows: [Int]) throws -> Raster {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(size.width * size.height)
        for length in rows {
            let bytes = Array(try reader.take(length))
            let end = pixels.count + size.width
            var offset = 0
            while offset < bytes.count {
                let run = Int(Int8(bitPattern: bytes[offset]))
                offset += 1
                switch run {
                case 0...127:
                    let count = run + 1
                    guard offset + count <= bytes.count, pixels.count + count <= end else {
                        throw PackError("Malformed PackBits literal run")
                    }
                    pixels.append(contentsOf: bytes[offset..<(offset + count)])
                    offset += count
                case -127 ... -1:
                    let count = 1 - run
                    guard offset < bytes.count, pixels.count + count <= end else {
                        throw PackError("Malformed PackBits repeat run")
                    }
                    pixels.append(contentsOf: repeatElement(bytes[offset], count: count))
                    offset += 1
                default: break
                }
            }
            guard pixels.count == end else { throw PackError("Truncated PackBits row") }
        }
        return Raster(size: size, channels: 1, pixels: pixels)
    }
}

extension ByteCursor {
    mutating func psd<T: FixedWidthInteger>(_ type: T.Type) throws -> T { try read(type, bigEndian: true) }
    mutating func length() throws -> Int { Int(try psd(UInt32.self)) }

    mutating func sectionEnd() throws -> Int {
        let size = try length()
        guard size <= remaining else { throw PackError("Truncated PSD section") }
        return offset + size
    }

    mutating func box() throws -> Box {
        let top = Int(try psd(Int32.self)), left = Int(try psd(Int32.self))
        let bottom = Int(try psd(Int32.self)), right = Int(try psd(Int32.self))
        guard top <= bottom, left <= right else { throw PackError("Invalid PSD layer bounds") }
        return Box(left, top, right, bottom)
    }

    mutating func floatingPoint() throws -> Double {
        let value = Double(bitPattern: try psd(UInt64.self))
        guard value.isFinite else { throw PackError("Invalid PSD coordinate") }
        return value
    }

    mutating func seekAfter(_ marker: String, limit: Int? = nil) -> Bool {
        let end = min(data.count, limit ?? data.count)
        guard offset <= end, let result = data.range(of: Data(marker.utf8), in: offset..<end) else { return false }
        offset = result.upperBound
        return true
    }
}
#endif

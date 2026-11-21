#if os(macOS)
import Foundation
import Testing
@testable import FramesPack

@Test func releaseAcceptsAPreviousZIPAndReproducesArchiveBytes() throws {
    try PackStorage.temp { root in
        let base = root.appending(path: "base")
        let built = root.appending(path: "built")
        let pack = root.appending(path: "first")
        let zip = root.appending(path: "first.zip")
        for folder in [base, built] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let previous: OrderedObject = ["100": .object(["name": "Phone", "x": "1", "y": "1"]), "variants": .object([:])]
        try PackStorage.write(previous, version: "4.2.1", to: base)
        let png = try Raster(size: Size(4, 4), channels: 4, value: 255).png()
        try png.write(to: base.appending(path: "Phone.png"))
        try PackStorage.copy(base, to: built)
        var updated = previous
        try updated.addVariant("Folded", entry: ["name": "Folded", "x": "0", "y": "0",
                                                 "warp": .object(["values": .array([.double(0.5), .double(0.00001)])])])
        try updated.addWidth(400, entry: ["name": "Other", "x": "0", "y": "0"], height: 700)
        try PackStorage.write(updated, version: "4.2.1", to: built)
        for name in ["Folded Night Sky.png", "Folded_mask.png", "Other.png"] {
            try png.write(to: built.appending(path: name))
        }
        let first = try ReleasePack.build(built, previous: base, version: "4.2.2", added: ["Folded", "Other"],
                                          output: pack, archive: zip)
        let baseZip = root.appending(path: "base.zip")
        try ZipPack.encode(folder: base).write(to: baseZip)
        let repeated = try ReleasePack.build(built, previous: baseZip, version: "4.2.2", added: ["Other", "Folded"],
                                             output: root.appending(path: "again"), archive: root.appending(path: "again.zip"))
        #expect(first.newFiles == ["Folded Night Sky.png", "Folded_mask.png", "Other.png"])
        #expect(first.digest == repeated.digest)
        #expect(try PackStorage.readPack(zip) == PackStorage.readPack(pack))
        #expect(try PackStorage.version(in: built) == "4.2.1")
        #expect(try Data(contentsOf: pack.appending(path: "Phone.png")) == png)

        try Data([1, 2, 3]).write(to: built.appending(path: "Phone.png"))
        let rejected = root.appending(path: "rejected")
        #expect(throws: PackError.self) {
            try ReleasePack.build(built, previous: base, version: "4.2.2", added: ["Folded", "Other"],
                                  output: rejected, archive: root.appending(path: "rejected.zip"))
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }
}

@Test func screenMaskRemainsUnderBezelAndCamera() throws {
    let view = ArtworkView(name: "Test", asset: "", canvas: Size(12, 10), screen: Box(3, 3, 9, 7), physicalHeight: 1)
    var frame = Raster(size: view.canvas, channels: 4, value: 255)
    for y in view.screen.top..<view.screen.bottom {
        for x in view.screen.left..<view.screen.right { frame.pixels[(y * frame.width + x) * 4 + 3] = 10 }
    }
    frame.pixels[(4 * frame.width + 5) * 4 + 3] = 255
    let mask = try view.screenMask(in: frame)
    #expect(mask.size == Size(6, 4))
    #expect(mask.pixels[1 * mask.width + 2] == 0)
    #expect(mask.pixels[0] == 255)
}

@Test func trimKeepsWarpedAssetsAndTheirCatalogCoordinatesIntact() throws {
    try PackStorage.temp { root in
        let source = root.appending(path: "source")
        let output = root.appending(path: "output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let pose: JSONValue = .object(["name": "Folded", "x": "0", "y": "0", "warp": .object([:])])
        try PackStorage.write(["variants": .object(["Folded": pose])], version: "4.2.1", to: source)
        let png = try Raster(size: Size(12, 10), channels: 4).png()
        let files = ["Folded Night Sky.png", "Folded_mask.png", "Folded_camera.png"]
        for file in files { try png.write(to: source.appending(path: file)) }

        let report = try TrimPack.build(source: source, output: output, version: "4.2.2")
        #expect(report.devices.isEmpty)
        #expect(report.untouched.contains("Folded Night Sky.png"))
        let entry = try PackStorage.readCatalog(in: output)["variants"]?.object?["Folded"]
        #expect(entry?.encoded() == pose.encoded())
        for file in files { #expect(try Data(contentsOf: output.appending(path: file)) == png) }
    }
}

@Test func preservesHiddenAndSemitransparentColorThroughPNG() throws {
    let input = Raster(size: Size(3, 2), channels: 4, pixels: [
        23, 67, 122, 0, 70, 30, 90, 128, 200, 115, 123, 255,
        0, 22, 90, 3, 21, 18, 222, 0, 33, 63, 199, 62,
    ])
    let png = try input.png()
    #expect(try Raster(png: png) == input)
    #expect(try Raster(png: PNGData.optimize(png, raster: input)) == input)
}

@Test func perspectiveFittingNeverEnlargesTheScreenshot() throws {
    let corners = [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)]
    let polygon = [Point(100, 0), Point(300, 0), Point(400, 200), Point(0, 200)]
    let quad = WarpQuad(polygon: polygon, source: corners)
    let canvas = Size(400, 200)
    let native = Size(100, 100)
    let fitted = try FoldedArtwork.fittedSize(quads: [quad], canvas: canvas, native: native)
    let region = try WarpRegion(quad: quad, canvas: canvas, scaled: fitted, crop: Box(fitted))
    let scale = try region.scale(for: native)
    #expect(scale.peak > 0.95 && scale.peak <= 1)
    #expect(region.points[2] == Point(Double(fitted.width), Double(fitted.height)))
    let cropped = try WarpRegion(quad: quad, canvas: canvas, scaled: fitted,
                                 crop: Box(3, 2, fitted.width, fitted.height))
    #expect(abs(try cropped.scale(for: native).peak - scale.peak) < 1e-10)
}

@Test func photoshopReadsTheScreenMaskAlongsideAnOversizedAuxiliaryMask() throws {
    func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
    func section(_ payload: [UInt8]) -> [UInt8] { bytes(UInt32(payload.count)) + payload }

    func maskRecord(name: String, side: UInt32, channelLength: Int) -> [UInt8] {
        let label = [UInt8(name.utf8.count)] + Array(name.utf8)
        let bounds = bytes(UInt64(0)) + bytes(side) + bytes(side)
        let mask = section(bounds + [0, 0, 0, 0])
        let extra = mask + section([]) + label + Array(repeating: 0, count: (4 - label.count % 4) % 4)
        var record = Array(repeating: UInt8(0), count: 16)
        record += bytes(UInt16(1)) + bytes(Int16(-2)) + bytes(UInt32(channelLength))
        record += Array("8BIMnorm".utf8) + [255, 0, 0, 0]
        return record + section(extra)
    }

    let screen: [UInt8] = [0, 0, 255, 120, 5, 0]
    // An 8000-pixel PackBits row with 62 runs of 128 and one run of 64.
    let row: [UInt8] = Array(repeating: [UInt8(129), 0], count: 62).flatMap { $0 } + [193, 0]
    var auxiliary = bytes(UInt16(1))
    auxiliary += Array(repeating: bytes(UInt16(row.count)), count: 8000).flatMap { $0 }
    auxiliary += Array(repeating: row, count: 8000).flatMap { $0 }
    var layerInfo = bytes(Int16(2))
    layerInfo += maskRecord(name: "Screen Content", side: 2, channelLength: screen.count)
    layerInfo += maskRecord(name: "Luminosity", side: 8000, channelLength: auxiliary.count)
    layerInfo += screen + auxiliary

    var file = Array("8BPS".utf8) + bytes(UInt16(1)) + Array(repeating: 0, count: 6)
    file += bytes(UInt16(3)) + bytes(UInt32(2)) + bytes(UInt32(2)) + bytes(UInt16(8)) + bytes(UInt16(3))
    file += section([]) + section([]) + section(section(layerInfo) + section([]))
    file += bytes(UInt16(1)) + Array(repeating: [UInt8(0), 3], count: 6).flatMap { $0 }
    file += Array(repeating: [UInt8(1), 0, 0], count: 6).flatMap { $0 }

    try PackStorage.temp { root in
        let url = root.appending(path: "Folded.psd")
        try Data(file).write(to: url)
        let artwork = try PhotoshopArtwork(url: url, imageLayers: [], maskLayers: ["screen content"])
        #expect(artwork.layers["screen content"]?.mask?.pixels == [255, 120, 5, 0])
        #expect(artwork.layers["luminosity"]?.mask == nil)
    }
}
#endif

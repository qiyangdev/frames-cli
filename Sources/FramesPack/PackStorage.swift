#if os(macOS)
import CryptoKit
import Foundation
import zlib

let catalogFile = "NewFrames.json"
let versionFile = "version.txt"
let licenseFile = "Apple Design Resources License.rtf"

struct ByteCursor {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset >= 0, count <= remaining else { throw PackError("Unexpected end of binary data") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset >= 0, count <= remaining else { throw PackError("Unexpected end of binary data") }
        offset += count
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type, bigEndian: Bool = false) throws -> T {
        let count = MemoryLayout<T>.size
        guard offset >= 0, count <= remaining else { throw PackError("Unexpected end of binary data") }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += count
        return bigEndian ? T(bigEndian: value) : T(littleEndian: value)
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(_ value: T, bigEndian: Bool = false) {
        var wire = bigEndian ? value.bigEndian : value.littleEndian
        Swift.withUnsafeBytes(of: &wire) { append(contentsOf: $0) }
    }

    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }

    var crc32Value: UInt32 {
        withUnsafeBytes { UInt32(truncatingIfNeeded: zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(count))) }
    }
}

enum PackStorage {
    static var files: FileManager { FileManager.default }

    static func contents(of folder: URL, allowHidden: Bool = false) throws -> [URL] {
        try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                      options: [])
            .filter { allowHidden || !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func checkRegular(_ url: URL) throws {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw PackError("Unexpected non-file in pack: \(url.path)")
        }
    }

    static func copy(_ base: URL, to stage: URL, matching: (String) -> Bool = { _ in true }) throws {
        for file in try contents(of: base) where matching(file.lastPathComponent) {
            try checkRegular(file)
            try files.copyItem(at: file, to: stage.appending(path: file.lastPathComponent))
        }
    }

    static func readCatalog(in folder: URL) throws -> OrderedObject {
        let catalog = try JSONValue.document(Data(contentsOf: folder.appending(path: catalogFile)))
        guard catalog["variants"]?.object != nil else { throw PackError("Base must be an Apple Frames 4 pack") }
        return catalog
    }

    static func version(in folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: versionFile), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ catalog: OrderedObject, version: String, to folder: URL) throws {
        try JSONValue.object(catalog).encoded().write(to: folder.appending(path: catalogFile), options: .atomic)
        try Data(version.utf8).write(to: folder.appending(path: versionFile), options: .atomic)
    }

    static func stage<Result>(output: URL, archive: URL? = nil, _ build: (URL) throws -> Result) throws -> Result {
        for path in [output, archive].compactMap({ $0 }) where files.fileExists(atPath: path.path) {
            throw PackError("Destination must not exist: \(path.path)")
        }
        if archive?.standardizedFileURL == output.standardizedFileURL {
            throw PackError("The pack and archive must use different paths")
        }
        let parent = output.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appending(path: ".frames-pack-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }
        let stage = temporary.appending(path: "pack")
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        let result = try build(stage)
        let zip = try archive.map { _ in try ZipPack.encode(folder: stage) }
        try files.moveItem(at: stage, to: output)
        if let archive, let zip {
            do {
                try zip.write(to: archive, options: .withoutOverwriting)
            } catch {
                try? files.removeItem(at: output)
                throw error
            }
        }
        return result
    }

    static func temp<Result>(_ work: (URL) throws -> Result) throws -> Result {
        let directory = files.temporaryDirectory.appending(path: "frames-pack-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        return try work(directory)
    }

    static func readPack(_ url: URL) throws -> [String: Data] {
        var directory: ObjCBool = false
        if files.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            var entries: [String: Data] = [:]
            for file in try contents(of: url) {
                try checkRegular(file)
                entries[file.lastPathComponent] = try Data(contentsOf: file, options: .mappedIfSafe)
            }
            return entries
        }
        return try ZipPack.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }
}

enum ZipPack {
    private static let maxEntry = 100_000_000
    private static let maxTotal = 1_000_000_000
    private static let date: UInt16 = (2026 - 1980) << 9 | 9 << 5 | 30

    static func encode(folder: URL) throws -> Data {
        let files = try PackStorage.contents(of: folder, allowHidden: true)
        guard files.count < Int(UInt16.max) else { throw PackError("Too many ZIP entries") }
        var archive = Data()
        var directory = Data()
        for file in files {
            try PackStorage.checkRegular(file)
            let name = file.lastPathComponent
            guard valid(name) else { throw PackError("Unexpected archive file: \(name)") }
            let path = Data(("Frames/" + name).utf8)
            guard let pathLength = UInt16(exactly: path.count), let offset = UInt32(exactly: archive.count) else {
                throw PackError("Archive exceeds ZIP limits")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count <= maxEntry else { throw PackError("ZIP entry exceeds size limit: \(name)") }
            let compressed = try zlibTransform(data, expected: nil)
            let crc = data.crc32Value
            let flags: UInt16 = path.allSatisfy { $0 < 128 } ? 0 : 0x800

            archive.append(UInt32(0x04034b50))
            appendFields(to: &archive, flags: flags, crc: crc, size: data.count, compressed: compressed.count, name: pathLength)
            archive.append(UInt16(0))
            archive.append(path)
            archive.append(compressed)

            directory.append(UInt32(0x02014b50))
            directory.append(UInt16(0x0314))
            appendFields(to: &directory, flags: flags, crc: crc, size: data.count, compressed: compressed.count, name: pathLength)
            for _ in 0..<4 { directory.append(UInt16(0)) }
            directory.append(UInt32(0o100644) << 16)
            directory.append(offset)
            directory.append(path)
        }
        guard let offset = UInt32(exactly: archive.count), let size = UInt32(exactly: directory.count) else {
            throw PackError("Archive exceeds ZIP limits")
        }
        archive.append(directory)
        archive.append(UInt32(0x06054b50))
        for field in [0, 0, UInt16(files.count), UInt16(files.count)] { archive.append(field) }
        archive.append(size)
        archive.append(offset)
        archive.append(UInt16(0))
        return archive
    }

    private static func appendFields(to data: inout Data, flags: UInt16, crc: UInt32, size: Int,
                                     compressed: Int, name: UInt16) {
        for field in [20, flags, 8, 0, date] { data.append(field) }
        data.append(crc)
        data.append(UInt32(compressed))
        data.append(UInt32(size))
        data.append(name)
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        let endMarker = Data([0x50, 0x4b, 5, 6])
        guard data.count >= 22,
              let record = data.range(of: endMarker, options: .backwards,
                                      in: max(0, data.count - 65_557)..<(data.count - 18))
        else { throw PackError("Missing ZIP end record") }
        var end = ByteCursor(data: data, offset: record.upperBound)
        let disk = try end.read(UInt32.self)
        let diskCount = try end.read(UInt16.self)
        let count = try end.read(UInt16.self)
        let length = Int(try end.read(UInt32.self))
        let offset = Int(try end.read(UInt32.self))
        let comment = Int(try end.read(UInt16.self))
        guard disk == 0, diskCount == count, offset + length == record.lowerBound, end.remaining == comment else {
            throw PackError("Invalid ZIP directory")
        }
        var entries: [String: Data] = [:]
        var total = 0
        var index = ByteCursor(data: data, offset: offset)
        for _ in 0..<count {
            guard try index.read(UInt32.self) == 0x02014b50 else { throw PackError("Invalid ZIP directory member") }
            try index.skip(4)
            let flags = try index.read(UInt16.self)
            let method = try index.read(UInt16.self)
            try index.skip(4)
            let crc = try index.read(UInt32.self)
            let compressed = Int(try index.read(UInt32.self))
            let size = Int(try index.read(UInt32.self))
            let nameLength = Int(try index.read(UInt16.self))
            let extra = Int(try index.read(UInt16.self))
            let note = Int(try index.read(UInt16.self))
            try index.skip(4)
            let attributes = try index.read(UInt32.self)
            let local = Int(try index.read(UInt32.self))
            let nameData = try index.take(nameLength)
            try index.skip(extra + note)
            total += size
            guard index.offset <= record.lowerBound, flags & 1 == 0,
                  (attributes >> 16) & 0xF000 != 0xA000, total <= maxTotal, size <= maxEntry,
                  let path = String(data: nameData, encoding: .utf8), path.hasPrefix("Frames/") else {
                throw PackError("Invalid or unsafe ZIP member")
            }
            let name = String(path.dropFirst(7))
            guard valid(name), entries[name] == nil, local + 30 <= offset else {
                throw PackError("Expected every ZIP member directly under Frames/: \(path)")
            }
            var file = ByteCursor(data: data, offset: local)
            guard try file.read(UInt32.self) == 0x04034b50 else { throw PackError("Invalid ZIP member header") }
            try file.skip(22)
            let localName = Int(try file.read(UInt16.self))
            let localExtra = Int(try file.read(UInt16.self))
            guard try file.take(localName) == nameData else { throw PackError("ZIP member name differs from directory") }
            try file.skip(localExtra)
            guard file.offset + compressed <= offset else { throw PackError("Truncated ZIP member") }
            let stored = try file.take(compressed)
            let bytes: Data
            switch method {
            case 0 where stored.count == size: bytes = stored
            case 8: bytes = try zlibTransform(stored, expected: size)
            default: throw PackError("Unsupported ZIP compression method")
            }
            guard bytes.crc32Value == crc else { throw PackError("ZIP checksum failed for \(name)") }
            entries[name] = bytes
        }
        guard index.offset == record.lowerBound else { throw PackError("ZIP member count differs from directory") }
        return entries
    }

    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func zlibTransform(_ data: Data, expected: Int?) throws -> Data {
        var stream = z_stream()
        let encode = expected == nil
        let version = zlibVersion()
        let structSize = Int32(MemoryLayout<z_stream>.size)
        let status = encode
            ? deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, version, structSize)
            : inflateInit2_(&stream, -15, version, structSize)
        guard status == Z_OK else { throw PackError("Could not initialize ZIP compression") }
        defer {
            if encode { deflateEnd(&stream) } else { inflateEnd(&stream) }
        }
        let capacity = max(1, expected ?? Int(deflateBound(&stream, uLong(data.count))))
        var result = Data(count: capacity)
        let final = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(capacity)
                return encode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_FINISH)
            }
        }
        guard final == Z_STREAM_END, stream.avail_in == 0,
              expected == nil || expected == Int(stream.total_out) else {
            throw PackError("Invalid ZIP compression stream")
        }
        result.count = Int(stream.total_out)
        return result
    }
}
#endif

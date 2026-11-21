import Compression
import CryptoKit
import Foundation

public enum FrameAssets {
    public static let releaseVersion = "4.3.1"
    public static let releaseURL = URL(string: "https://cdn.macstories.net/images/uploads/2026/11/18/appleframes431-1795036082113-06f3c2ecbf.zip")!
    private static let digest = "97c0009a9c0de1bd635bae74f2906d3036eadfe4cededc4bef27ab9894a5ad08"

    public static var applicationSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "frames/assets", directoryHint: .isDirectory)
    }

    public static func download(to destination: URL = applicationSupportDirectory) async throws -> FrameCatalog {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: releaseURL)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw FramesError("Could not download Apple Frames \(releaseVersion).")
        }
        try Task.checkCancellation()
        return try installReleaseArchive(at: file, to: destination)
    }

    /// Installs the published asset pack after verifying its release checksum.
    public static func installReleaseArchive(at file: URL, to destination: URL) throws -> FrameCatalog {
        let archive = try Data(contentsOf: file, options: .mappedIfSafe)
        guard SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw FramesError("Apple Frames \(releaseVersion) archive checksum did not match.")
        }

        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(path: ".frames-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try ReleaseZIP(data: archive).extract(to: staging)
        let catalog = try FrameCatalog(directory: staging)
        guard catalog.version == releaseVersion else { throw FramesError("Unexpected asset pack version.") }
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw FramesError("The asset destination must be a directory.")
            }
            for item in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
                let target = staging.appending(path: item.lastPathComponent)
                if !fm.fileExists(atPath: target.path) {
                    try Task.checkCancellation()
                    try fm.copyItem(at: item, to: target)
                }
            }
            _ = try fm.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        return try FrameCatalog(directory: destination)
    }
}

/// The release archive uses stored or raw DEFLATE entries and has a pinned digest.
private struct ReleaseZIP {
    let data: Data

    func extract(to directory: URL) throws {
        let fm = FileManager.default
        // Find the end record, allowing the ZIP comment defined by the format.
        let lower = max(0, data.count - 65_557)
        guard data.count >= 22,
              let end = (lower...(data.count - 22)).reversed().first(where: {
                  read($0, 4) == 0x06054b50 && $0 + 22 + read($0 + 20, 2) == data.count
              }) else { throw FramesError("Invalid asset ZIP directory.") }

        let count = read(end + 10, 2)
        var position = read(end + 16, 4)
        let limit = position + read(end + 12, 4)
        guard position >= 0, limit <= end else { throw FramesError("Invalid asset ZIP directory bounds.") }
        for _ in 0..<count {
            try Task.checkCancellation()
            guard position + 46 <= limit, read(position, 4) == 0x02014b50 else {
                throw FramesError("Invalid asset ZIP entry.")
            }
            let method = read(position + 10, 2)
            let compressedSize = read(position + 20, 4)
            let size = read(position + 24, 4)
            let nameLength = read(position + 28, 2)
            let local = read(position + 42, 4)
            let mode = read(position + 40, 2)
            let nameStart = position + 46
            position = nameStart + nameLength + read(position + 30, 2) + read(position + 32, 2)
            guard position <= limit,
                  let path = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8),
                  !path.contains("\\"), !path.contains("\0"), mode & 0xF000 != 0xA000 else {
                throw FramesError("Unsafe entry in the asset ZIP.")
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.first == "__MACOSX" || path == "Frames/" { continue }
            guard parts.first == "Frames", parts.count >= 2,
                  parts.dropFirst().allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw FramesError("Unsafe asset ZIP path: \(path).")
            }
            let names = path.hasSuffix("/") ? parts.dropLast().dropFirst() : parts.dropFirst()
            guard names.allSatisfy({ !$0.isEmpty }) else { throw FramesError("Unsafe asset ZIP path: \(path).") }
            let target = names.reduce(directory) { $0.appending(path: String($1)) }
            if path.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard local + 30 <= limit, read(local, 4) == 0x04034b50, size <= 100_000_000 else {
                throw FramesError("Invalid asset ZIP file: \(path).")
            }
            let start = local + 30 + read(local + 26, 2) + read(local + 28, 2)
            guard start + compressedSize <= limit else { throw FramesError("Truncated asset ZIP file: \(path).") }
            let contents: Data
            if method == 0, size == compressedSize {
                contents = Data(data[start..<(start + compressedSize)])
            } else if method == 8, compressedSize > 0, size > 0 {
                var decoded = Data(count: size)
                let written = decoded.withUnsafeMutableBytes { output in
                    data.withUnsafeBytes { input in
                        compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size,
                                                  input.bindMemory(to: UInt8.self).baseAddress! + start,
                                                  compressedSize, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == size else { throw FramesError("Could not decompress \(path).") }
                contents = decoded
            } else {
                throw FramesError("Unsupported ZIP compression for \(path).")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, options: .withoutOverwriting)
        }
        guard position == limit else { throw FramesError("Asset ZIP directory count did not match.") }
    }

    private func read(_ start: Int, _ count: Int) -> Int {
        data[start..<(start + count)].enumerated().reduce(0) { partial, pair in
            partial | (Int(pair.element) << (pair.offset * 8))
        }
    }
}

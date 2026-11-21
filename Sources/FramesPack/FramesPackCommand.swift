#if os(macOS)
import Darwin
import Foundation

@main
enum FramesPackCommand {
    enum Command: String, CaseIterable {
        case release, trim, optimize
        case duo = "build-duo"
        case folded = "build-duo-folded"
        case proled = "build-proled"
        case homeView = "build-homeview"
        case miniUltra = "build-mini-ultra4"

        var usage: String {
            switch self {
            case .release: "release BUILT --base PACK_OR_ZIP --version VERSION --added FRAME [--added FRAME …] --output DIR --archive ZIP"
            case .trim: "trim SOURCE OUTPUT --version VERSION [--archive ZIP] [--report JSON]"
            case .optimize: "optimize SOURCE OUTPUT"
            case .duo, .folded, .homeView: "\(rawValue) --source DIR --base-assets DIR --output DIR [--archive ZIP]"
            case .proled: "\(rawValue) --source DIR --base-assets DIR --output DIR [--version VERSION] [--archive ZIP]"
            case .miniUltra: "\(rawValue) --mini DIR --ultra DIR --base-assets DIR --output DIR --version VERSION [--archive ZIP] [--report JSON]"
            }
        }

        var switches: Set<String> {
            switch self {
            case .release: ["base", "version", "added", "output", "archive"]
            case .trim: ["version", "archive", "report"]
            case .optimize: []
            case .duo, .folded, .homeView: ["source", "base-assets", "output", "archive"]
            case .proled: ["source", "base-assets", "output", "version", "archive"]
            case .miniUltra: ["mini", "ultra", "base-assets", "output", "version", "archive", "report"]
            }
        }

        var operandCount: Int {
            switch self {
            case .release: 1
            case .trim, .optimize: 2
            default: 0
            }
        }
    }

    private struct Arguments {
        var sources: [URL] = []
        private var options: [String: [String]] = [:]

        init(_ args: ArraySlice<String>, for command: Command) throws {
            var pending = args.makeIterator()
            var literal = false
            while let token = pending.next() {
                if token == "--", !literal {
                    literal = true
                } else if token.hasPrefix("--"), !literal {
                    let pair = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let first = pair.first, command.switches.contains(String(first)) else { throw PackError("Unknown option: \(token)") }
                    guard let value = pair.count == 2 ? String(pair[1]) : pending.next(), !value.isEmpty else {
                        throw PackError("Missing value for --\(first)")
                    }
                    options[String(first), default: []].append(value)
                } else {
                    sources.append(Self.path(token))
                }
            }
            guard sources.count == command.operandCount else { throw PackError("Usage: frames-pack \(command.usage)") }
        }

        func read(_ name: String) -> String? { options[name]?.last }
        func all(_ name: String) -> [String] { options[name] ?? [] }
        func require(_ name: String) throws -> String {
            guard let value = read(name) else { throw PackError("--\(name) is required") }
            return value
        }

        func url(_ name: String) -> URL? { read(name).map(Self.path) }
        func requiredURL(_ name: String) throws -> URL { try Self.path(require(name)) }

        private static func path(_ input: String) -> URL {
            URL(filePath: (input as NSString).expandingTildeInPath).standardizedFileURL
        }
    }

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" {
            print("Maintain Apple Frames asset packs")
            for command in Command.allCases { print("  frames-pack \(command.usage)") }
            return
        }
        do {
            guard let command = arguments.first.flatMap(Command.init(rawValue:)) else {
                throw PackError("Unknown command: \(arguments.first ?? ""). Run frames-pack --help.")
            }
            let options = arguments.dropFirst()
            if options.first == "--help" || options.first == "-h" {
                print("Usage: frames-pack \(command.usage)")
                return
            }
            try run(command, with: Arguments(options, for: command))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ command: Command, with args: Arguments) throws {
        let archive = args.url("archive")
        switch command {
        case .release:
            let added = args.all("added")
            guard !added.isEmpty else { throw PackError("--added is required") }
            let zip = try args.requiredURL("archive")
            let summary = try ReleasePack.build(args.sources[0], previous: args.requiredURL("base"),
                                                version: args.require("version"), added: added,
                                                output: args.requiredURL("output"), archive: zip)
            print("Pack \(summary.version) (was \(summary.previous)): \(summary.fileCount) files, \(summary.pngCount) PNGs")
            print("Unchanged from \(summary.previous): \(summary.existingCount) files, byte-identical")
            print("New files (\(summary.newFiles.count)):")
            for file in summary.newFiles { print("  \(file)") }
            print("\(zip.lastPathComponent): \(summary.archiveBytes) bytes")
            print("SHA-256: \(summary.digest)")
        case .trim:
            let report = try TrimPack.build(source: args.sources[0], output: args.sources[1],
                                            version: args.require("version"), archive: archive)
            if let path = args.url("report") { try report.json.encoded(indent: 1).write(to: path, options: .atomic) }
            let devices = report.devices.values
            print("Trimmed \(devices.count) devices (\(devices.map(\.files).reduce(0, +)) PNGs); strongest dropped alpha \(devices.map(\.droppedAlpha).max() ?? 0); \(report.untouched.count) frames untouched")
        case .optimize:
            let rows = try PackOptimizer.build(source: args.sources[0], output: args.sources[1])
            let before = rows.map(\.sourceBytes).reduce(0, +)
            let after = rows.map(\.bytes).reduce(0, +)
            let quantized = rows.count(where: \.quantized)
            let fraction = before == 0 ? 0 : (1 - Double(after) / Double(before)) * 100
            print("\(rows.count) PNGs: \(before) → \(after) bytes (\(String(format: "%.1f", fraction))% smaller); \(quantized) quantized, \(rows.count - quantized) lossless")
        case .duo, .proled:
            try FlatArtwork.build(source: args.requiredURL("source"), base: args.requiredURL("base-assets"),
                                  output: args.requiredURL("output"), archive: archive, version: args.read("version"),
                                  isDuo: command == .duo)
        case .folded:
            try FoldedArtwork.build(source: args.requiredURL("source"), base: args.requiredURL("base-assets"),
                                    output: args.requiredURL("output"), archive: archive)
        case .homeView:
            try HomeViewArtwork.build(source: args.requiredURL("source"), base: args.requiredURL("base-assets"),
                                      output: args.requiredURL("output"), archive: archive)
        case .miniUltra:
            let report = try MiniUltraArtwork.build(mini: args.requiredURL("mini"), watch: args.requiredURL("ultra"),
                                                    base: args.requiredURL("base-assets"), output: args.requiredURL("output"),
                                                    version: args.require("version"), archive: archive)
            if let path = args.url("report") { try report.encoded(indent: 1).write(to: path, options: .atomic) }
        }
    }
}
#else
@main
enum FramesPackCommand {
    static func main() {
        print("frames-pack runs on macOS.")
    }
}
#endif

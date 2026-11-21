import Foundation
import FramesCore

struct Arguments {
    enum Command: String, CaseIterable {
        case frame, video, info, list, colors, setup, doctor
        case videoInfo = "video-info"
        case listColors = "list-colors"
    }

    var command = Command.frame
    private(set) var hasCommand = false
    var files: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ input: [String]) throws {
        let aliases = ["-h": "--help", "-v": "--verbose", "-c": "--color", "-d": "--device",
                       "-m": "--merge", "-b": "--batch", "-s": "--spacing", "-o": "--output", "-f": "--framed-subfolder"]
        let global: Set = ["--json", "--no-color", "--verbose", "--help", "--version", "--assets"]
        let framing: Set = ["--device", "--color", "--colors"]
        let layout: Set = ["--merge", "--spacing", "--no-scale", "--output"]
        let supported: [Command: Set<String>] = [
            .frame: framing.union(layout).union(["--batch", "--copy", "--subfolder", "--framed-subfolder"]),
            .video: framing.union(layout).union(["--playback-offset", "--strip-audio", "--background", "--codec",
                                                "--alpha", "--preset", "--quality", "--rotate"]),
            .videoInfo: framing.union(["--rotate"]),
            .setup: ["--subfolder", "--no-subfolder", "--archive"],
            .colors: ["--device", "--color"],
        ]
        let takesValue: Set = ["--assets", "--color", "--colors", "--device", "--spacing", "--output", "--batch",
                               "--background", "--codec", "--preset", "--quality", "--rotate", "--archive"]
        var iterator = input.makeIterator()
        var commandSeen = false
        var literal = false
        while let token = iterator.next() {
            if literal {
                files.append(token)
                commandSeen = true
            } else if token == "--" {
                literal = true
            } else if token.hasPrefix("-"), token != "-" {
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let option = aliases[String(pair[0])] ?? String(pair[0])
                if !global.contains(option) { commandSeen = true }
                guard global.union(supported[command] ?? []).contains(option) else {
                    throw FramesError("Unknown option '\(option)' for \(command.rawValue).")
                }
                if takesValue.contains(option) || (option == "--subfolder" && command == .frame) {
                    guard let value = pair.count == 2 ? String(pair[1]) : iterator.next() else {
                        throw FramesError("Missing value for \(option).")
                    }
                    if ["--spacing", "--batch", "--quality"].contains(option), Int(value) == nil {
                        throw FramesError("\(option) requires an integer.")
                    }
                    values[option] = value
                    if option == "--subfolder" { flags.remove("--framed-subfolder") }
                } else {
                    guard pair.count == 1 else { throw FramesError("\(option) does not accept a value.") }
                    flags.insert(option)
                    if option == "--framed-subfolder" { values.removeValue(forKey: "--subfolder") }
                    if option == "--subfolder" { flags.remove("--no-subfolder") }
                    if option == "--no-subfolder" { flags.remove("--subfolder") }
                }
            } else if !commandSeen, let explicit = Command(rawValue: token) {
                command = explicit
                commandSeen = true
            } else {
                files.append(token)
                commandSeen = true
            }
        }
        hasCommand = commandSeen
        guard !has("--help"), !has("--version") else { return }
        if (command == .info || command == .videoInfo || command == .listColors), files.isEmpty {
            throw FramesError(help)
        }
        if let codec = values["--codec"], VideoCodec(rawValue: codec) == nil {
            throw FramesError("Invalid codec '\(codec)'.")
        }
        if let preset = values["--preset"], VideoPreset(rawValue: preset) == nil {
            throw FramesError("Invalid preset '\(preset)'.")
        }
        if let rotation = values["--rotate"], VideoRotation(rawValue: rotation) == nil {
            throw FramesError("Invalid rotation '\(rotation)'.")
        }
    }

    func has(_ key: String) -> Bool { flags.contains(key) }

    subscript(_ key: String) -> String? { values[key] }

    func integer(_ flag: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = self[flag] else { return nil }
        guard let number = Int(value), range.contains(number) else {
            throw FramesError("\(flag) must be an integer between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }

    func selection<T: RawRepresentable>(_ flag: String, default fallback: T) throws -> T where T.RawValue == String {
        guard let name = self[flag] else { return fallback }
        guard let option = T(rawValue: name) else { throw FramesError("Invalid value '\(name)' for \(flag).") }
        return option
    }

    func frameOptions(count: Int, defaults: [String: String]) throws -> [FrameOptions] {
        if let list = self["--colors"] {
            guard self["--color"] == nil else { throw FramesError("--color and --colors cannot be used together.") }
            let selections = list.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !selections.contains("") else { throw FramesError("--colors cannot contain empty values.") }
            guard selections.count == count else {
                throw FramesError("--colors expected \(count) values, got \(selections.count).")
            }
            return selections.map { FrameOptions(device: self["--device"], color: $0, defaultColors: defaults, strictColor: true) }
        }
        let option = FrameOptions(device: self["--device"], color: self["--color"].flatMap { $0.isEmpty ? nil : $0 }, defaultColors: defaults)
        return Array(repeating: option, count: count)
    }

    var help: String {
        switch command {
        case .frame:
            """
            Usage: frames [frame] [options] <image-or-directory> …
            Commands: frame, info, video, video-info, list, list-colors, colors, setup, doctor
            Global options: --assets PATH, --json, --no-color, --verbose, --version, --help
            Frame options: -d, --device NAME | -c, --color NAME | --colors A,B
                           -m, --merge | -b, --batch N | -s, --spacing PX | --no-scale
                           -o, --output DIR | -f | --subfolder NAME | --copy
            """
        case .video:
            """
            Usage: frames video [options] <video-or-directory> …
            Frame options: -d, --device NAME | -c, --color NAME | --colors A,B
                           -m, --merge | --playback-offset | -s, --spacing PX | --no-scale
            Video options: --codec h264|hevc|prores|hevc-alpha | --alpha | --strip-audio
                           --background white|black|transparent|#RRGGBB | --preset compact|balanced|best
                           --quality 0…51 | --rotate none|clockwise|counterclockwise|180
                           -o, --output FILE_OR_DIR
            """
        case .videoInfo:
            "Usage: frames video-info [--json] [--rotate DIRECTION] [--device NAME] [--color NAME | --colors A,B] <video-or-directory> …"
        case .setup:
            "Usage: frames setup [ASSET_DIRECTORY | --archive ZIP] [--subfolder | --no-subfolder]"
        case .colors:
            "Usage: frames colors [--device NAME --color COLOR]"
        case .listColors:
            "Usage: frames list-colors <device-name>"
        case .info:
            "Usage: frames info [--json] <image-or-directory> …"
        case .list, .doctor:
            "Usage: frames \(command.rawValue) [--assets PATH] [--json]"
        }
    }
}

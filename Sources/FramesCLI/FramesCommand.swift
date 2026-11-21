#if os(macOS)
import AppKit
import Darwin
import Foundation
import FramesCore

@main
struct FramesCommand {
    static let version = "2.0.0"

    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let arguments: Arguments
        do {
            arguments = try Arguments(raw)
        } catch {
            log("frames: error: \(error.localizedDescription)")
            exit(2)
        }
        do {
            if arguments.has("--version") {
                print("frames v\(version)")
            } else if arguments.has("--help") {
                print(arguments.help)
            } else if arguments.hasCommand {
                try await run(arguments)
            } else if !arguments.has("--json") {
                try splash(arguments)
            }
        } catch {
            if raw.contains("--json") {
                var result: [String: Any] = ["error": error.localizedDescription]
                if error is AssetSetupRequired { result["setup_required"] = true }
                try? writeJSON(result)
            } else if let setup = error as? AssetSetupRequired {
                log("Error: Assets \(setup.reason). Run 'frames setup' interactively.")
            } else {
                log("Error: \(error.localizedDescription)")
            }
            exit(EXIT_FAILURE)
        }
    }

    static func run(_ args: Arguments) async throws {
        if args.command == .doctor {
            try doctor(args)
            return
        }

        var settings = try Settings()
        if args.command == .setup {
            try await setup(args, settings: &settings)
            return
        }

        let resolved = Settings.assets(override: args["--assets"], settings: settings)
        if args.command == .listColors {
            try listColors(args)
            return
        }
        if args.command == .colors {
            let catalog = try? FrameCatalog(directory: resolved.url)
            try colors(args, catalog: catalog, settings: &settings)
            return
        }

        let version = FrameCatalog.installationVersion(in: resolved.url)
        let catalog: FrameCatalog
        if let version, version >= 4 {
            catalog = try FrameCatalog(directory: resolved.url)
        } else {
            let reason = version.map { "outdated (version \($0))" } ?? "not found"
            guard acceptsInput, !args.has("--json") else { throw AssetSetupRequired(reason: reason) }
            catalog = try await guidedSetup(preferred: args["--assets"].map(fileURL) ?? Settings.shortcutsDirectory,
                                            reason: reason, settings: &settings)
        }

        switch args.command {
        case .frame:
            try await frameImages(args, renderer: FramesRenderer(catalog: catalog), settings: settings)
        case .info:
            try imageInfo(args, catalog: catalog)
        case .list:
            try requireNoInputs(args)
            listDevices(catalog, style: terminalStyle(args))
        case .video:
            try await exportVideos(args, renderer: FramesRenderer(catalog: catalog), settings: settings)
        case .videoInfo:
            try await videoInfo(args, renderer: FramesRenderer(catalog: catalog), settings: settings)
        case .setup, .listColors, .colors, .doctor:
            break
        }
    }

    static func setup(_ args: Arguments, settings: inout Settings) async throws {
        guard args.files.count <= 1, args.files.isEmpty || args["--archive"] == nil else {
            throw FramesError(args.help)
        }
        let changesSubfolder = args.has("--subfolder") || args.has("--no-subfolder")
        if changesSubfolder { settings.setSubfolder(args.has("--subfolder")) }
        if let path = args.files.first {
            let url = fileURL(path)
            let catalog = try FrameCatalog(directory: url)
            guard let version = catalog.version, (Int(version.split(separator: ".").first ?? "") ?? 0) >= 4 else {
                throw FramesError("Expected Apple Frames assets version 4 or newer at \(url.path).")
            }
            settings.setAssets(url)
            try settings.save()
            print("Apple Frames \(version) assets configured at \(url.path)")
        } else if let archive = args["--archive"] {
            let url = args["--assets"].map(fileURL) ?? Settings.appDataDirectory
            let catalog = try FrameAssets.installReleaseArchive(at: fileURL(archive), to: url)
            settings.setAssets(catalog.directory)
            try settings.save()
            print("Installed Apple Frames \(FrameAssets.releaseVersion) at \(url.path)")
        } else if changesSubfolder {
            try settings.save()
            print("Output subfolder \(args.has("--subfolder") ? "enabled" : "disabled").")
        } else {
            if let explicit = args["--assets"], !acceptsInput {
                _ = try await installAssets(to: fileURL(explicit), settings: &settings)
            } else {
                guard acceptsInput else {
                    throw FramesError("Run 'frames setup' in an interactive terminal, or provide a path.")
                }
                _ = try await guidedSetup(preferred: args["--assets"].map(fileURL) ?? Settings.shortcutsDirectory,
                                          settings: &settings)
            }
        }
    }

    private static func guidedSetup(preferred: URL, reason: String? = nil,
                                    settings: inout Settings) async throws -> FrameCatalog {
        if let reason { print("Apple Frames assets \(reason).") }
        print("Download Apple Frames \(FrameAssets.releaseVersion) (~55 MB) to \(preferred.path)?")
        print("Press Enter to confirm, q to cancel, or enter another path: ", terminator: "")
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !["q", "quit", "n", "no"].contains(response.lowercased()) else {
            throw FramesError("Asset installation cancelled.")
        }
        let destination = ["", "y", "yes"].contains(response.lowercased()) ? preferred : fileURL(response)
        return try await installAssets(to: destination, settings: &settings)
    }

    private static func installAssets(to url: URL, settings: inout Settings) async throws -> FrameCatalog {
        let catalog = try await FrameAssets.download(to: url)
        settings.setAssets(catalog.directory)
        try settings.save()
        print("Installed Apple Frames \(FrameAssets.releaseVersion) at \(url.path)")
        return catalog
    }

    private static func splash(_ args: Arguments) throws {
        let settings = try Settings()
        let resolved = Settings.assets(override: args["--assets"], settings: settings)
        let style = terminalStyle(args)
        print(style.bold("Apple Frames \(version)"))
        print("Frame screenshots and recordings with Apple device bezels.")
        print("Run 'frames --help' for commands.")
        if let version = FrameCatalog.installationVersion(in: resolved.url), version >= 4 {
            print("Assets installed at \(resolved.url.path)")
        } else {
            print("Assets not installed. Run 'frames setup' to download device frames.")
        }
    }

    private static func listDevices(_ catalog: FrameCatalog, style: TerminalStyle) {
        let categories = ["iPhone Duo", "iPhone 17", "iPhone Air", "iPhone 16", "iPhone 12-13", "iPhone 8",
                          "iPad", "MacBook", "iMac", "Studio Display", "Watch", "HomeView"]
        var grouped: [String: [String]] = [:]
        for width in catalog.inputWidths {
            for device in catalog.devices(atWidth: width) {
                let category = categories.first { device.name.hasPrefix($0) || device.name.contains($0) } ?? "Other"
                var labels: [String] = []
                let count = catalog.colors(for: device.name).count
                if device.hasColors && count > 0 { labels.append("\(count) colors") }
                if let target = device.catalogResizeWidth, target.value != width {
                    labels.append("scaled")
                }
                let details = labels.isEmpty ? "" : " (" + labels.joined(separator: ", ") + ")"
                grouped[category, default: []].append("  \(width)px → \(device.name)\(details)")
            }
        }
        print(style.bold("Supported Devices"))
        for category in categories + ["Other"] {
            if let entries = grouped[category] {
                print("\n" + style.bold(category))
                entries.forEach { print($0) }
            }
        }
        let matches = catalog.inputWidths.flatMap { catalog.automaticMatches(atWidth: $0) }
        let automatic = Set(matches.map { $0.device.name })
        let manual = catalog.variantNames.filter { !automatic.contains($0) }
        if !manual.isEmpty {
            print("\n" + style.bold("Manual frames") + " (select with --device)")
            for name in manual {
                let alias = catalog.aliases.first { $0.value == name }?.key
                print(alias.map { "  \($0) (\(name))" } ?? "  \(name)")
            }
        }
        print("\n" + style.bold("Default Variants"))
        let defaults = Set(matches.filter(\.isVariant).map { "\($0.primary) → \($0.device.name)" })
        defaults.sorted().forEach { print("  \($0)") }
    }

    static func doctor(_ args: Arguments) throws {
        try requireNoInputs(args)
        let config = Result { try Settings() }
        let resolved = Settings.assets(override: args["--assets"], settings: try? config.get())
        let fm = FileManager.default
        let version = FrameCatalog.installationVersion(in: resolved.url)
        let configPresent = fm.fileExists(atPath: Settings.configURL.path)
        let catalog = (try? FrameCatalog(directory: resolved.url))
        let pngs = (try? fm.contentsOfDirectory(atPath: resolved.url.path))?
            .filter { $0.hasSuffix(".png") }.count ?? 0
        var issues: [String] = []
        var notes: [String] = []
        var nextSteps: [String] = []
        if case let .failure(error) = config {
            issues.append("Config file is unreadable: \(error.localizedDescription)")
            nextSteps.append("Fix or remove \(Settings.configURL.path).")
        } else if !configPresent {
            notes.append("Config file not found. This is fine if you use defaults or FRAMES_ASSETS.")
        }

        let assetIssue: String?
        if !fm.fileExists(atPath: resolved.url.path) {
            assetIssue = "Assets directory does not exist: \(resolved.url.path)"
        } else if !fm.fileExists(atPath: resolved.url.appending(path: "NewFrames.json").path) {
            assetIssue = "NewFrames.json is missing from assets directory: \(resolved.url.path)"
        } else if let version, version < 4 {
            assetIssue = "Assets are outdated at \(resolved.url.path) (version \(version))."
        } else if version == nil || catalog == nil {
            assetIssue = "Assets at \(resolved.url.path) do not look like Apple Frames 4."
        } else if pngs == 0 {
            assetIssue = "No frame PNGs were found in \(resolved.url.path)."
        } else {
            assetIssue = nil
        }
        if let assetIssue {
            issues.append(assetIssue)
            nextSteps.append("Run `frames setup` to re-download or re-point your assets.")
        }
        if let catalog, (version ?? 0) >= 4 {
            let recent = [
                ("iPhone 18 Pro", "iPhone 18 Pro Portrait"), ("iPhone Duo", "iPhone Duo Outer Open"),
                ("MacBook Pro with PROLED XDR Display", "MacBook Pro PROLED 14"),
                ("iPad mini (A20 Pro)", "iPad mini A20 Pro Portrait"), ("Apple Watch Ultra 4", "Watch Ultra 4"),
                ("the iPhone Duo Book and Laptop poses", "iPhone Duo Inner Partially Open Portrait"),
                ("Apple HomeView", "HomeView"),
            ]
            let installed = Set(catalog.deviceNames)
            let missing = recent.compactMap { installed.contains($0.1) ? nil : $0.0 }
            if !missing.isEmpty {
                notes.append("This asset pack predates \(missing.joined(separator: " and ")). Run `frames setup` to download the current standard pack.")
            }
        }
        let stale = try FrameCatalog.staleColorGroups((try? config.get().colors) ?? [:])
        if !stale.isEmpty {
            issues.append("Some saved default colors no longer match supported device colors.")
            nextSteps.append("Run `frames colors` to save fresh defaults, or remove stale entries from config.")
        }
        switch resolved.source {
        case "FRAMES_ASSETS": notes.append("Using FRAMES_ASSETS from the environment.")
        case "--assets": notes.append("Using assets directory from the CLI flag.")
        case "default": notes.append("Using the Apple Frames Shortcuts/iCloud assets directory.")
        case "app-data": notes.append("Using the fallback Application Support assets directory.")
        default: break
        }
        if nextSteps.isEmpty { nextSteps.append("No action needed.") }
        if args.has("--json") {
            var report: [String: Any] = [
                "ok": issues.isEmpty, "assets_path": resolved.url.path, "assets_source": resolved.source,
                "assets_version": nullable(version), "asset_pack_version": nullable(catalog?.version), "frame_pngs": pngs,
                "config_path": Settings.configURL.path, "config_present": configPresent,
                "video_tools": ["ok": true, "error": NSNull(), "install": NSNull(), "backend": "AVFoundation"],
                "issues": issues, "notes": notes, "next_steps": nextSteps,
            ]
            if !stale.isEmpty { report["bad_default_colors"] = stale }
            try writeJSON(report)
        } else {
            print("Assets: \(resolved.url.path) (\(resolved.source), \(catalog?.version ?? "unknown version"), \(pngs) PNGs)")
            print("Config: \(Settings.configURL.path)")
            print("Video: AVFoundation")
            (issues + notes).forEach { print($0) }
        }
    }

    static func listColors(_ args: Arguments) throws {
        guard args.files.count == 1, let query = args.files.first else { throw FramesError(args.help) }
        let choices = try FrameCatalog.knownColors(matching: query)
        guard !choices.isEmpty else { throw FramesError("No device matching '\(query)'.") }
        for choice in choices {
            let alias = try FrameCatalog.knownAlias(for: choice.device)
            print(terminalStyle(args).bold(choice.device) + (alias.map { " (\($0))" } ?? ""))
            for (index, color) in choice.colors.enumerated() {
                print("  \(index + 1). \(color)\(index == 0 ? " (default)" : "")")
            }
        }
    }

    static func colors(_ args: Arguments, catalog: FrameCatalog?, settings: inout Settings) throws {
        try requireNoInputs(args)
        let groups = try FrameCatalog.colorGroups(installedNames: Set(catalog?.deviceNames ?? []))
        if let name = args["--device"], let selection = args["--color"] {
            let canonical = catalog?.aliases[name] ?? name
            let group = FrameCatalog.colorGroup(for: canonical)
            let choices = groups.first { $0.name == group }?.colors ?? []
            let color = try chooseColor(selection, from: choices)
            settings.colors[group] = color
            try settings.save()
            print("\(group): \(color)")
            return
        }
        guard args["--device"] == nil, args["--color"] == nil else { throw FramesError(args.help) }
        let stored = settings.colors
        let palettes = try groups.map { group, choices in
            let current = try FrameCatalog.effectiveDefault(for: group, choices: choices, defaults: stored)
            let inherits = try FrameCatalog.inheritsColorDefault(group)
            return TerminalColorPicker.Palette(name: group, colors: choices, selected: current,
                                               saveByDefault: !inherits || stored[group] != nil)
        }

        let style = terminalStyle(args)
        if interactive, ProcessInfo.processInfo.environment["TERM"] != "dumb",
           let picker = TerminalColorPicker(palettes: palettes, style: style) {
            if let updated = picker.select(), !updated.isEmpty {
                settings.colors = updated
                try settings.save()
                print("Defaults saved!")
                for palette in palettes {
                    if let color = updated[palette.name] { print("  ● \(palette.name): \(color)") }
                }
            } else {
                print("No changes saved.")
            }
        } else {
            print(style.bold("All Device Colors"))
            for palette in palettes {
                print("\n" + style.bold(palette.name))
                for color in palette.colors {
                    print("  \(color == palette.selected ? "●" : "○") \(color)")
                }
            }
        }
    }

    private static func chooseColor(_ input: String, from choices: [String]) throws -> String {
        if let index = Int(input), (1...choices.count).contains(index) { return choices[index - 1] }
        if let color = choices.first(where: { $0.caseInsensitiveCompare(input) == .orderedSame }) { return color }
        throw FramesError("Unknown color '\(input)'. Choose: \(choices.joined(separator: ", ")).")
    }

    static var acceptsInput: Bool { isatty(STDIN_FILENO) != 0 }
    static var interactive: Bool { acceptsInput && isatty(STDOUT_FILENO) != 0 }

    static func terminalStyle(_ args: Arguments) -> TerminalStyle {
        TerminalStyle(enabled: isatty(STDOUT_FILENO) != 0 && !args.has("--no-color") &&
                      (ProcessInfo.processInfo.environment["NO_COLOR"] ?? "").isEmpty)
    }

    static func requireNoInputs(_ args: Arguments) throws {
        guard args.files.isEmpty else { throw FramesError(args.help) }
    }

    static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static func writeJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

private struct AssetSetupRequired: LocalizedError {
    let reason: String
    var errorDescription: String? { "Assets \(reason)" }
}

struct TerminalStyle {
    let enabled: Bool

    func bold(_ text: String) -> String {
        enabled ? "\u{1b}[1m\(text)\u{1b}[0m" : text
    }
}

func nullable<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

#else
@main
enum FramesCommand {
    static func main() {
        print("The frames command is available on macOS. Import FramesCore in Apple platform apps.")
    }
}
#endif

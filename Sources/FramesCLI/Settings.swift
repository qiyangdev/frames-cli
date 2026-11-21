import CoreFoundation
import Foundation
import FramesCore

struct Settings {
    private var object: [String: Any]
    let url: URL

    static var homeDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["HOME"], !path.isEmpty { return fileURL(path) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var configURL: URL {
        homeDirectory.appending(path: ".config/frames/config.json")
    }

    init(url: URL = configURL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            object = [:]
            return
        }
        do {
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw FramesError("Config must contain a JSON object.")
            }
            if let setting = values["assets_path"],
               (setting as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw FramesError("assets_path must be a non-empty path string.")
            }
            if let setting = values["default_colors"], !(setting is [String: Any]) {
                throw FramesError("default_colors must be an object mapping devices to colors.")
            }
            if let setting = values["use_subfolder"] {
                if let name = setting as? String {
                    _ = try Self.validateSubfolder(name)
                } else if let bool = setting as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() {
                    // A boolean selects the built-in folder name or the input directory.
                } else {
                    throw FramesError("use_subfolder must be true, false, or a directory name.")
                }
            }
            object = values
        } catch {
            throw FramesError("Invalid config at \(url.path): \(error.localizedDescription) Run 'frames doctor' for details.")
        }
    }

    var colors: [String: String] {
        get { (object["default_colors"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String } }
        set { object["default_colors"] = newValue }
    }

    var subfolder: String? {
        if let value = object["use_subfolder"] as? String { return try? Self.validateSubfolder(value) }
        return object["use_subfolder"] as? Bool == true ? "framed" : nil
    }

    mutating func setSubfolder(_ enabled: Bool) { object["use_subfolder"] = enabled }

    mutating func setAssets(_ url: URL) { object["assets_path"] = url.path }

    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data([10])).write(to: url, options: .atomic)
    }

    static var shortcutsDirectory: URL {
        homeDirectory.appending(path: "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Frames")
    }

    static var appDataDirectory: URL {
        ProcessInfo.processInfo.environment["FRAMES_DATA_HOME"].map { fileURL($0).appending(path: "frames/assets") }
            ?? homeDirectory.appending(path: "Library/Application Support/frames/assets")
    }

    static func assets(override: String?, settings: Settings?) -> (url: URL, source: String) {
        if let override { return (fileURL(override), "--assets") }
        if let path = ProcessInfo.processInfo.environment["FRAMES_ASSETS"], !path.isEmpty {
            return (fileURL(path), "FRAMES_ASSETS")
        }
        if let path = settings?.object["assets_path"] as? String { return (fileURL(path), "config") }
        if (FrameCatalog.installationVersion(in: shortcutsDirectory) ?? 0) >= 4 {
            return (shortcutsDirectory, "default")
        }
        if (FrameCatalog.installationVersion(in: appDataDirectory) ?? 0) >= 4 {
            return (appDataDirectory, "app-data")
        }
        return (shortcutsDirectory, "default")
    }

    static func validateSubfolder(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != ".", name != ".." else {
            throw FramesError("Subfolder must be a single directory name without path separators or '..'.")
        }
        return name
    }
}

func fileURL(_ path: String) -> URL {
    URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

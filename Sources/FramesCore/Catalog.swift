import Foundation

public struct FramesError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

public struct PixelSize: Codable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }

    func validate() throws {
        guard (1...50_000).contains(width), (1...50_000).contains(height),
              width * height <= 89_478_485 else {
            throw FramesError("Unsupported image dimensions: \(self).")
        }
    }
}

struct Warp: Decodable, Sendable {
    struct Region: Decodable, Sendable {
        let polygon: [[Double]]
        let inverse: [Double]
        let extent: [Double]?
    }

    struct Camera: Decodable, Sendable {
        let x: Int
        let y: Int
        let blendIf: [[Int]]
    }

    let inputSizes: [[Int]]
    let regions: [Region]
    let blend: String?
    let reflections: [String: [UInt8]]?
    let reflectionSpan: [Double]?
    let reflectionAxis: String?
    let camera: Camera?

    func accepts(_ size: PixelSize, scaled: Bool) -> Bool {
        inputSizes.contains { pair in
            guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return false }
            if pair == [size.width, size.height] { return true }
            guard scaled else { return false }
            let aspect = Double(size.width) / Double(size.height)
            return abs(aspect / (Double(pair[0]) / Double(pair[1])) - 1) <= 0.01
        }
    }
}

public struct FrameDevice: Decodable, Sendable {
    package enum CatalogInteger: Sendable {
        case number(Int)
        case text(String, Int)

        package var value: Int {
            switch self {
            case let .number(value), let .text(_, value): value
            }
        }

        package var jsonValue: Any {
            switch self {
            case let .number(value): value
            case let .text(text, _): text
            }
        }
    }

    public let name: String
    public var x: Int { catalogX.value }
    public var y: Int { catalogY.value }
    package let catalogX: CatalogInteger
    package let catalogY: CatalogInteger
    package let catalogResizeWidth: CatalogInteger?
    package let catalogResizeHeight: CatalogInteger?
    public let physicalHeight: Double
    public let hasMask: Bool
    public let hasColors: Bool
    var resizeWidth: Int? { catalogResizeWidth?.value }
    var resizeHeight: Int? { catalogResizeHeight?.value }
    let warp: Warp?

    enum CodingKeys: String, CodingKey {
        case name, x, y, physicalHeight, mask, colors, resizeWidth, resizeHeight, warp
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        catalogX = try fields.integer(.x) ?? .number(0)
        catalogY = try fields.integer(.y) ?? .number(0)
        catalogResizeWidth = try fields.integer(.resizeWidth)
        catalogResizeHeight = try fields.integer(.resizeHeight)
        physicalHeight = (try? fields.decode(Double.self, forKey: .physicalHeight))
            ?? (try? fields.decode(String.self, forKey: .physicalHeight)).flatMap(Double.init) ?? 0
        hasMask = try fields.decodeIfPresent(String.self, forKey: .mask) == "yes"
        hasColors = try fields.decodeIfPresent(String.self, forKey: .colors) == "yes"
        warp = try fields.decodeIfPresent(Warp.self, forKey: .warp)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              (-50_000...50_000).contains(x), (-50_000...50_000).contains(y),
              resizeWidth.map({ (0...50_000).contains($0) }) ?? true,
              resizeHeight.map({ (0...50_000).contains($0) }) ?? true,
              physicalHeight.isFinite, physicalHeight >= 0 else {
            throw FramesError("Invalid metadata for device '\(name)'.")
        }
    }

    public func resizeTarget(for size: PixelSize) -> PixelSize? {
        guard let resizeWidth, resizeWidth > 0, size.width > 0, size.height > 0 else { return nil }
        let height = resizeHeight ?? Int(Double(size.height) * Double(resizeWidth) / Double(size.width))
        let target = PixelSize(width: resizeWidth, height: height)
        return target == size ? nil : target
    }
}

private extension KeyedDecodingContainer<FrameDevice.CodingKeys> {
    func integer(_ key: Key) throws -> FrameDevice.CatalogInteger? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let number = try? decode(Int.self, forKey: key) { return .number(number) }
        if let value = try? decode(String.self, forKey: key), let number = Int(value.trimmingCharacters(in: .whitespaces)) {
            return .text(value, number)
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected an integer.")
    }
}

private struct DeviceRules: Decodable, Sendable {
    let colors: [String: [String]]
    let variants: [String: [String]]
    let aliases: [String: String]
    let colorParents: [String: String]
    let colorOrder: [String]
}

private enum WidthEntry: Decodable, Sendable {
    case single(FrameDevice)
    case overlap([String: FrameDevice])

    private enum Key: String, CodingKey { case overlap }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        if let overlap = try fields.decodeIfPresent([String: FrameDevice].self, forKey: .overlap) {
            self = .overlap(overlap)
        } else {
            self = .single(try FrameDevice(from: decoder))
        }
    }
}

public struct DeviceMatch: Sendable {
    public let device: FrameDevice
    public let primary: String
    public let variants: [String]
    public var isVariant: Bool { primary != device.name }
}

public struct FrameCatalog: Sendable {
    public let directory: URL
    public let version: String?
    private let entries: [Int: WidthEntry]
    private let variants: [String: FrameDevice]
    private let named: [String: FrameDevice]
    private let rules: DeviceRules

    public init(directory: URL) throws {
        self.directory = directory
        let decoder = JSONDecoder()
        rules = try Self.loadRules()
        let url = directory.appending(path: "NewFrames.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FramesError("NewFrames.json not found at \(url.path). Run 'frames setup' or pass --assets.")
        }
        guard var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FramesError("Expected a device dictionary in \(url.path).")
        }
        let storedVariants = raw.removeValue(forKey: "variants")
        let rawVariants = storedVariants ?? [:]
        if raw["1125"] == nil {
            raw["1125"] = [
                "name": "iPhone 12-13 mini Portrait", "x": "80", "y": "80",
                "resizeWidth": 1080, "resizeHeight": 2340, "physicalHeight": 131.5,
            ]
        }
        for (width, suffix, x, y) in [("1488", "Portrait", "142", "146"), ("2266", "Landscape", "146", "142")] {
            if var rawEntry = raw[width] as? [String: Any],
               rawEntry["name"] as? String == "iPad mini 2021 \(suffix)",
               String(describing: rawEntry["x"] ?? "") == x, String(describing: rawEntry["y"] ?? "") == y {
                rawEntry["x"] = y
                rawEntry["y"] = x
                raw[width] = rawEntry
            }
        }

        var sized: [Int: WidthEntry] = [:]
        var names: [String: FrameDevice] = [:]
        for key in raw.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            guard let width = Int(key), let entry = raw[key], JSONSerialization.isValidJSONObject(entry) else { continue }
            let value = try decoder.decode(WidthEntry.self, from: JSONSerialization.data(withJSONObject: entry))
            sized[width] = value
            switch value {
            case let .single(device): names[device.name] = device
            case let .overlap(heights):
                for key in heights.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                    if let device = heights[key] { names[device.name] = device }
                }
            }
        }
        variants = try decoder.decode([String: FrameDevice].self, from: JSONSerialization.data(withJSONObject: rawVariants))
        names.merge(variants) { _, variant in variant }
        entries = sized
        named = names
        version = Self.readVersion(in: directory) ?? (storedVariants != nil ? "4" : nil)
    }

    private static func readVersion(in directory: URL) -> String? {
        let url = directory.appending(path: "version.txt")
        guard let line = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline)
            .first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              Int(line.split(separator: ".", omittingEmptySubsequences: false).first ?? "") != nil else { return nil }
        return line
    }

    package static func installationVersion(in directory: URL) -> Int? {
        let url = directory.appending(path: "NewFrames.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let version = readVersion(in: directory) {
            return Int(version.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
        }
        if let data = try? Data(contentsOf: url),
           let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           dictionary["variants"] != nil {
            return 4
        }
        return nil
    }

    public var deviceNames: [String] { named.keys.sorted() }
    public var aliases: [String: String] { rules.aliases }
    package var variantNames: [String] { variants.keys.sorted() }

    public var inputWidths: [Int] { entries.keys.sorted() }

    public func devices(atWidth width: Int) -> [FrameDevice] {
        switch entries[width] {
        case let .single(device): [device]
        case let .overlap(heights): heights.values.sorted { $0.name < $1.name }
        case nil: []
        }
    }

    public func colors(for name: String) -> [String] {
        rules.colors[rules.aliases[name] ?? name] ?? []
    }

    private static let bundledRules = Result {
        guard let url = Bundle.module.url(forResource: "Devices", withExtension: "json") else {
            throw FramesError("Bundled device rules are missing.")
        }
        return try JSONDecoder().decode(DeviceRules.self, from: Data(contentsOf: url))
    }

    private static func loadRules() throws -> DeviceRules { try bundledRules.get() }

    public static func knownColors(matching query: String) throws -> [(device: String, colors: [String])] {
        let rules = try loadRules()
        return rules.colorOrder.compactMap { name in
            let matches = name.localizedCaseInsensitiveContains(query) || rules.aliases.contains {
                $0.value == name && $0.key.localizedCaseInsensitiveContains(query)
            }
            return matches ? (name, rules.colors[name] ?? []) : nil
        }
    }

    package static func knownAlias(for name: String) throws -> String? {
        try loadRules().aliases.first { $0.value == name }?.key
    }

    package static func colorGroups(installedNames: Set<String>) throws -> [(name: String, colors: [String])] {
        let rules = try loadRules()
        let poses = Set(rules.aliases.values)
        var seen: Set<String> = []
        return rules.colorOrder.compactMap { name in
            let group = colorGroup(for: name)
            guard (!poses.contains(name) || installedNames.contains(name)), let colors = rules.colors[name],
                  seen.insert(group).inserted else { return nil }
            return (group, colors)
        }
    }

    package static func inheritsColorDefault(_ group: String) throws -> Bool {
        try loadRules().colorParents[group] != nil
    }

    package static func effectiveDefault(for group: String, choices: [String], defaults: [String: String]) throws -> String? {
        let rules = try loadRules()
        return defaultColor(for: group, choices: choices, defaults: defaults, rules: rules)
    }

    package static func staleColorGroups(_ defaults: [String: String]) throws -> [String] {
        let rules = try loadRules()
        return defaults.keys.sorted().compactMap { group in
            let palettes = rules.colors.filter { colorGroup(for: $0.key) == group }.values
            guard let color = defaults[group], !palettes.isEmpty, palettes.allSatisfy({ !$0.contains(color) }) else { return nil }
            return "\(group): \(color)"
        }
    }

    public func automaticMatches(atWidth width: Int) -> [DeviceMatch] {
        devices(atWidth: width).map(automaticMatch)
    }

    public static func colorGroup(for name: String) -> String {
        for suffix in [" Portrait", " Landscape"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    public func color(for device: FrameDevice, selection: String? = nil,
                      defaults: [String: String] = [:], strict: Bool = false) throws -> String? {
        let choices = colors(for: device.name)
        guard device.hasColors, !choices.isEmpty else { return nil }
        if let selection, selection != "default" {
            if selection == "random" { return choices.randomElement() }
            if let exact = choices.first(where: { $0.caseInsensitiveCompare(selection) == .orderedSame }) { return exact }
            if let index = Int(selection), (1...choices.count).contains(index) { return choices[index - 1] }
            if strict { throw FramesError("Unknown color '\(selection)' for \(device.name). Choose: \(choices.joined(separator: ", ")).") }
        }
        let group = Self.colorGroup(for: device.name)
        return Self.defaultColor(for: group, choices: choices, defaults: defaults, rules: rules)
    }

    private static func defaultColor(for group: String, choices: [String], defaults: [String: String],
                                     rules: DeviceRules) -> String? {
        for key in [group, rules.colorParents[group]].compactMap({ $0 }) {
            if let color = defaults[key], choices.contains(color) { return color }
        }
        return choices.first
    }

    package func isInvalidColor(_ selection: String?, for device: FrameDevice) -> Bool {
        guard let selection, device.hasColors, selection != "default", selection != "random" else { return false }
        let choices = colors(for: device.name)
        guard !choices.isEmpty else { return false }
        return !choices.contains { $0.caseInsensitiveCompare(selection) == .orderedSame }
            && !(Int(selection).map { (1...choices.count).contains($0) } ?? false)
    }

    public func resolve(_ size: PixelSize, device explicit: String? = nil) throws -> DeviceMatch {
        if let explicit {
            guard let device = named[rules.aliases[explicit] ?? explicit] else {
                throw FramesError("Device '\(explicit)' is missing from this asset pack. Run 'frames setup' for the current pack.")
            }
            return DeviceMatch(device: device, primary: device.name, variants: [])
        }
        let primary: FrameDevice?
        switch entries[size.width] {
        case let .single(device): primary = device
        case let .overlap(heights): primary = heights[String(size.height)]
        case nil: primary = nil
        }
        guard let primary else {
            throw FramesError("Unknown device for \(size) input. Use 'frames list' to see supported devices.")
        }
        return automaticMatch(primary)
    }

    private func automaticMatch(_ primary: FrameDevice) -> DeviceMatch {
        let row = rules.variants[primary.name] ?? []
        let selected = row.prefix { $0 != primary.name }.compactMap { variants[$0] }.first ?? primary
        var installed = row.filter { $0 == primary.name || variants[$0] != nil }
        if installed == [primary.name], row.filter({ $0 != primary.name }).allSatisfy({ rules.aliases.values.contains($0) }) {
            installed = []
        }
        return DeviceMatch(device: selected, primary: primary.name, variants: installed)
    }

    func frameURL(device: FrameDevice, color: String?) -> URL {
        if let color {
            let colored = directory.appending(path: "\(device.name) \(color).png")
            if FileManager.default.fileExists(atPath: colored.path) { return colored }
        }
        return directory.appending(path: "\(device.name).png")
    }

    func accessoryURL(device: FrameDevice, suffix: String) -> URL {
        directory.appending(path: "\(device.name)_\(suffix).png")
    }
}

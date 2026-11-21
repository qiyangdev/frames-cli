#if os(macOS)
import CoreImage
import Foundation
import FramesCore
import Testing

@Test func missingAndOutdatedAssetsHaveTheSetupRequiredContract() throws {
    let fixture = try CLIFixture()
    let missing = try fixture.run(["--json", "--assets", "missing", "info", "shot.png"])
    #expect(missing.status == 1)
    #expect(try missing.json()["setup_required"] as? Bool == true)
    #expect(try missing.json()["error"] as? String == "Assets not found")
    try fixture.write("3.5.0", to: "assets/version.txt")
    let outdated = try fixture.run(["info", "--json", "--assets", "assets", "shot.png"])
    #expect(outdated.status == 1)
    #expect(try outdated.json()["setup_required"] as? Bool == true)
    #expect(try outdated.json()["error"] as? String == "Assets outdated (version 3)")
    let bare = try fixture.run(["--json"])
    #expect(bare.status == 0)
    #expect(bare.output.isEmpty && bare.errors.isEmpty)
    let usage = try fixture.run(["info", "--json"])
    #expect(usage.status == 2)
    #expect(usage.output.isEmpty && usage.errors.contains("Usage:"))
    let headless = try fixture.run(["setup", "--json"])
    #expect(headless.status == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: ".config/frames").path))
}

@Test func imageCLIHasLegacyMetadataAndSubfolderFlagPrecedence() throws {
    let fixture = try CLIFixture()
    let info = try fixture.run(["--json", "info", "./shot.png"])
    #expect(info.status == 0)
    let fields = try info.json()
    #expect(fields["file"] as? String == "shot.png")
    #expect(fields["x"] as? String == "2")
    #expect(fields["y"] as? Int == 1)
    #expect(fields["resize_width"] as? String == "4")
    #expect(fields["resize_height"] is NSNull)

    let framed = try fixture.run(["--json", "--subfolder", "unused", "-f", "--verbose", "shot.png"])
    #expect(framed.status == 0, Comment(rawValue: framed.errors))
    let result = try framed.json()
    #expect(result["source"] as? String == "shot.png")
    #expect(result["output"] as? String == "framed/shot_framed.png")
    #expect(result["masked"] as? Bool == true)
    #expect(result["resized"] as? Bool == true)
    #expect(framed.errors.contains("Resized:") && framed.errors.contains("Mask applied"))

    let noMatch = try fixture.run(["--json", "info", "does-not-exist.png"])
    #expect(noMatch.status == 0)
    #expect(noMatch.output.isEmpty && noMatch.errors.contains("No images found."))
}

@Test func doctorReportsInvalidDefaultsAndKeepsAssetPrecedence() throws {
    let fixture = try CLIFixture()
    try fixture.write("""
        {"assets_path": "missing", "default_colors": {"iPhone Duo Inner": "Invalid finish"}}
        """, to: ".config/frames/config.json")
    let checked = try fixture.run(["doctor", "--json", "--assets", "assets"])
    #expect(checked.status == 0)
    let report = try checked.json()
    #expect(report["assets_source"] as? String == "--assets")
    #expect(report["bad_default_colors"] as? [String] == ["iPhone Duo Inner: Invalid finish"])
    #expect(report["ok"] as? Bool == false)

    try fixture.write("null", to: ".config/frames/config.json")
    let broken = try fixture.run(["doctor", "--json", "--assets", "assets"])
    let brokenReport = try broken.json()
    #expect(brokenReport["assets_source"] as? String == "--assets")
    #expect((brokenReport["issues"] as? [String])?.contains { $0.contains("Config file is unreadable") } == true)
    let skipped = try fixture.run(["--json"])
    #expect(skipped.status == 0 && skipped.output.isEmpty && skipped.errors.isEmpty)
    let bare = try fixture.run([])
    #expect(bare.status == 1 && bare.errors.contains("frames doctor"))
}

@Test func setupPreservesLegacySettingsAndUnknownKeys() throws {
    let fixture = try CLIFixture()
    let configPath = ".config/frames/config.json"
    let config = fixture.directory.appending(path: configPath)
    try fixture.write("""
        {"assets_path": "assets", "default_colors": {"iPhone Duo Inner": "Star White"},
         "use_subfolder": "mockups", "future_setting": {"preserve": [1, 2]}}
        """, to: configPath)
    let initial = try fixture.run(["--json", "shot.png"], assets: nil)
    #expect(initial.status == 0)
    #expect(try initial.json()["output"] as? String == "mockups/shot_framed.png")
    let doctor = try fixture.run(["doctor", "--json"], assets: nil)
    #expect(try doctor.json()["assets_source"] as? String == "config")

    for (flag, enabled) in [("--subfolder", true), ("--no-subfolder", false)] {
        let setup = try fixture.run(["setup", flag], assets: nil)
        #expect(setup.status == 0, Comment(rawValue: setup.errors))
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        #expect(saved["use_subfolder"] as? Bool == enabled)
        #expect(saved["assets_path"] as? String == "assets")
        #expect(saved["default_colors"] as? [String: String] == ["iPhone Duo Inner": "Star White"])
        #expect(saved["future_setting"] as? [String: [Int]] == ["preserve": [1, 2]])
    }
}

@Test func malformedSettingsPreventFramingAndSetupFromWriting() throws {
    let fixture = try CLIFixture()
    let configPath = ".config/frames/config.json"
    for content in ["null", #"{"default_colors":[]}"#, #"{"use_subfolder":"../outside"}"#] {
        try fixture.write(content, to: configPath)
        for command in [["shot.png"], ["setup", "assets"], ["setup", "--subfolder"], ["setup", "--no-subfolder"]] {
            let result = try fixture.run(["--json"] + command)
            #expect(result.status == 1)
            #expect((try result.json()["error"] as? String)?.contains("frames doctor") == true)
            let config = fixture.directory.appending(path: configPath)
            #expect(try String(contentsOf: config, encoding: .utf8) == content)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "shot_framed.png").path))
        }
    }
}

@Test func videoRejectsOutputThatWouldReplaceAnotherSourceBeforeDecoding() throws {
    let fixture = try CLIFixture()
    try fixture.write("first source", to: "videos/a.mp4")
    try fixture.write("second source", to: "videos/a_framed.mp4")
    let result = try fixture.run(["--json", "video", "videos"])
    #expect(result.status == 1)
    #expect((try result.json()["error"] as? String)?.contains("would replace an input") == true)
    let folder = fixture.directory.appending(path: "videos")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a.mp4", "a_framed.mp4"])
    #expect(try String(contentsOf: folder.appending(path: "a.mp4"), encoding: .utf8) == "first source")
    #expect(try String(contentsOf: folder.appending(path: "a_framed.mp4"), encoding: .utf8) == "second source")
}

private final class CLIFixture {
    struct Run {
        let status: Int32
        let output: Data
        let errors: String

        func json() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: output) as? [String: Any],
                         Comment(rawValue: errors))
        }
    }

    let directory: URL
    private let executable: URL

    init() throws {
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appending(path: "frames-cli-tests-\(UUID().uuidString)")
        var directory = Bundle(for: TestBundleAnchor.self).bundleURL
        var candidates: [URL] = []
        for _ in 0..<6 {
            candidates.append(directory.appending(path: "frames"))
            directory = directory.deletingLastPathComponent()
        }
        executable = try #require(candidates.first { fm.isExecutableFile(atPath: $0.path) })
        try write("""
            {"8": {"name": "Fixture", "x": "2", "y": 1, "mask": "yes", "resizeWidth": "4"}, "variants": {}}
            """, to: "assets/NewFrames.json")
        try write("4.3.1", to: "assets/version.txt")
        let context = CIContext()
        for (file, color, size) in [("assets/Fixture.png", CIColor.clear, CGSize(width: 8, height: 8)),
                                     ("assets/Fixture_mask.png", .white, CGSize(width: 4, height: 4)),
                                     ("shot.png", .red, CGSize(width: 8, height: 8))] {
            let bounds = CGRect(origin: .zero, size: size)
            let render = try #require(context.createCGImage(CIImage(color: color).cropped(to: bounds), from: bounds))
            try FramesRenderer.writePNG(render, to: self.directory.appending(path: file))
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ content: String, to path: String) throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    func run(_ arguments: [String], assets: String? = "assets") throws -> Run {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = directory.path
        env["FRAMES_ASSETS"] = assets.map { directory.appending(path: $0).path }
        env["NO_COLOR"] = "1"
        process.environment = env
        process.arguments = arguments

        let out = directory.appending(path: "stdout")
        let err = directory.appending(path: "stderr")
        try Data().write(to: out)
        try Data().write(to: err)
        let stdout = try FileHandle(forWritingTo: out)
        let stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: try Data(contentsOf: out),
                   errors: try String(contentsOf: err, encoding: .utf8))
    }
}

private final class TestBundleAnchor {}
#endif

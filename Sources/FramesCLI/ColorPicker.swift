#if os(macOS)
import Darwin
import Foundation

struct TerminalColorPicker {
    struct Palette {
        let name: String
        let colors: [String]
        let selected: String?
        let saveByDefault: Bool
    }

    private enum Row {
        case title(String)
        case choice(group: String, color: String)
    }

    private let palettes: [Palette]
    private let style: TerminalStyle
    private let rowItems: [Row]
    private let choiceRows: [Int]
    private let terminalSettings: termios

    init?(palettes: [Palette], style: TerminalStyle) {
        guard !palettes.isEmpty else { return nil }
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return nil }
        self.terminalSettings = current
        self.palettes = palettes
        self.style = style
        var rows: [Row] = []
        var choices: [Int] = []
        for palette in palettes {
            rows.append(.title(palette.name))
            for color in palette.colors {
                choices.append(rows.count)
                rows.append(.choice(group: palette.name, color: color))
            }
        }
        guard !choices.isEmpty else { return nil }
        self.rowItems = rows
        self.choiceRows = choices
    }

    func select() -> [String: String]? {
        var raw = terminalSettings
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        defer {
            var restored = terminalSettings
            tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            write("\u{1b}[?25h\u{1b}[?1049l")
        }

        write("\u{1b}[?1049h\u{1b}[?25l")
        var cursor = 0
        var touched: Set<String> = []
        var selections = Dictionary(uniqueKeysWithValues: palettes.compactMap { palette in
            palette.selected.map { (palette.name, $0) }
        })
        while true {
            let current = choiceRows[cursor]
            draw(cursor: current, selections: selections)
            guard let key = readKey() else { return nil }
            switch key {
            case .up: cursor = max(0, cursor - 1)
            case .down: cursor = min(choiceRows.count - 1, cursor + 1)
            case .select:
                if case let .choice(group, color) = rowItems[current] {
                    selections[group] = color
                    touched.insert(group)
                }
            case .save:
                guard !touched.isEmpty else { return nil }
                let saved = Set(palettes.lazy.filter(\.saveByDefault).map(\.name)).union(touched)
                return selections.filter { saved.contains($0.key) }
            case .cancel: return nil
            case .other: break
            }
        }
    }

    private func draw(cursor: Int, selections: [String: String]) {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let count = max(1, min(Int(size.ws_row == 0 ? 24 : size.ws_row) - 3, rowItems.count))
        let start = min(max(0, cursor - count / 2), rowItems.count - count)
        var lines = [style.bold("Default Colors"), "↑↓ navigate  Space select  Enter save  q cancel"]
        for row in start..<(start + count) {
            switch rowItems[row] {
            case let .title(group):
                lines.append(style.bold(group))
            case let .choice(group, color):
                let indicator = row == cursor ? "▸" : " "
                let mark = selections[group] == color ? "●" : "○"
                lines.append("\(indicator) \(mark) \(color)")
            }
        }
        write("\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n"))
    }

    private enum Key { case up, down, select, save, cancel, other }

    private func readKey() -> Key? {
        switch readByte() {
        case 3, 113: return .cancel
        case 10, 13: return .save
        case 32: return .select
        case 27:
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 80) > 0,
                  let bracket = readByte(), bracket == 91 || bracket == 79 else { return .cancel }
            switch readByte() {
            case 65: return .up
            case 66: return .down
            default: return .other
            }
        case nil: return nil
        default: return .other
        }
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(STDIN_FILENO, &byte, 1)
            if result == 1 { return byte }
            if result == 0 || errno != EINTR { return nil }
        }
    }

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
#endif

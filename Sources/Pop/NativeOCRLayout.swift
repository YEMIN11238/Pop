import Foundation

/// Geometry heuristics, not document semantics: horizontal text and well-separated
/// columns are supported; tables, vertical writing and arbitrary magazines remain ambiguous.
enum OCRTextLayout {
    static func orderedLines(_ input: [OCRLine]) -> [OCRLine] {
        order(input.filter { $0.width > 0 && $0.height > 0 }, depth: 0)
    }

    static func text(from lines: [OCRLine], smartParagraphs: Bool = true) -> String {
        if !smartParagraphs { return orderedLines(lines).map(\.text).joined(separator: "\n") }
        return paragraphs(from: lines).joined(separator: "\n\n")
    }

    static func paragraphs(from lines: [OCRLine]) -> [String] {
        let sorted = orderedLines(lines)
        guard !sorted.isEmpty else { return [] }
        let typicalHeight = median(sorted.map(\.height))
        var result: [String] = []
        var paragraph = sorted[0].text
        for index in 1..<sorted.count {
            let previous = sorted[index - 1], next = sorted[index]
            let previousCenter = previous.y + previous.height / 2
            let nextCenter = next.y + next.height / 2
            let sameRow = abs(previousCenter - nextCenter) < min(previous.height, next.height) * 0.5
            let gap = previous.y - (next.y + next.height)
            let newColumn = nextCenter > previousCenter + typicalHeight * 0.6
            let paragraphGap = !sameRow && gap > typicalHeight * 0.85
            let indentation = !sameRow && next.x - previous.x > max(0.035, typicalHeight * 0.8)
            if newColumn || paragraphGap || indentation {
                result.append(paragraph)
                paragraph = next.text
            } else {
                paragraph = join(paragraph, next.text, sameRow: sameRow)
            }
        }
        result.append(paragraph)
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Uses the same local geometry rules as paragraph text. These are Pop's
    /// reconstruction heuristics; they do not claim Bob's segmentation algorithm.
    static func paragraphBoxes(from lines: [OCRLine]) -> [OCRLine] {
        let sorted = orderedLines(lines)
        guard let first = sorted.first else { return [] }
        let typicalHeight = median(sorted.map(\.height))
        var groups: [[OCRLine]] = [[first]]
        for index in 1..<sorted.count {
            let previous = sorted[index - 1], next = sorted[index]
            let previousCenter = previous.y + previous.height / 2
            let nextCenter = next.y + next.height / 2
            let sameRow = abs(previousCenter - nextCenter) < min(previous.height, next.height) * 0.5
            if nextCenter > previousCenter + typicalHeight * 0.6
                || (!sameRow && previous.y - (next.y + next.height) > typicalHeight * 0.85)
                || (!sameRow && next.x - previous.x > max(0.035, typicalHeight * 0.8)) {
                groups.append([next])
            } else { groups[groups.count - 1].append(next) }
        }
        return groups.map { group in
            let x = group.map(\.x).min()!, y = group.map(\.y).min()!
            let right = group.map { $0.x + $0.width }.max()!, top = group.map { $0.y + $0.height }.max()!
            return OCRLine(text: paragraphs(from: group).joined(separator: "\n\n"), x: x, y: y,
                           width: right - x, height: top - y, confidence: group.map(\.confidence).min() ?? 0)
        }
    }

    private static func join(_ first: String, _ second: String, sameRow: Bool) -> String {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = left.unicodeScalars.last, let next = right.unicodeScalars.first else { return left + right }
        if last.value == 0x00AD { return String(left.dropLast()) + right }
        if !sameRow && last == "-" { return left + right }
        if cjk(last) && cjk(next) { return left + right }
        let noSpaceBefore = CharacterSet(charactersIn: ",.!?;:，。！？；：、）》】」』")
        let noSpaceAfter = CharacterSet(charactersIn: "（《【「『")
        if noSpaceBefore.contains(next) || noSpaceAfter.contains(last) { return left + right }
        return left + " " + right
    }
    private static func cjk(_ scalar: UnicodeScalar) -> Bool {
        (0x2E80...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) ||
        (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }

    private static func order(_ lines: [OCRLine], depth: Int) -> [OCRLine] {
        guard lines.count > 1, depth < 12 else { return lines }
        let typicalHeight = median(lines.map(\.height))
        // A vertical gutter shared by at least three lines on each side is likely
        // two columns. The threshold avoids interpreting a pair of row cells as columns.
        let xGaps = gaps(lines.map { ($0.x, $0.x + $0.width) })
            .filter { $0.1 - $0.0 >= max(0.045, typicalHeight * 0.9) }
            .sorted { $0.1 - $0.0 > $1.1 - $1.0 }
        for gap in xGaps {
            let split = (gap.0 + gap.1) / 2
            let left = lines.filter { $0.x + $0.width / 2 < split }
            let right = lines.filter { $0.x + $0.width / 2 >= split }
            if left.count >= 3, right.count >= 3 {
                return order(left, depth: depth + 1) + order(right, depth: depth + 1)
            }
        }
        // Full-width headings may prevent the first vertical split. Large horizontal
        // gutters isolate these blocks before trying columns again within each block.
        let yGaps = gaps(lines.map { ($0.y, $0.y + $0.height) })
            .filter { $0.1 - $0.0 >= typicalHeight * 1.05 }
        if let gap = yGaps.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) {
            let split = (gap.0 + gap.1) / 2
            let upper = lines.filter { $0.y + $0.height / 2 > split }
            let lower = lines.filter { $0.y + $0.height / 2 <= split }
            if !upper.isEmpty, !lower.isEmpty { return order(upper, depth: depth + 1) + order(lower, depth: depth + 1) }
        }
        let byTop = lines.sorted {
            let a = $0.y + $0.height, b = $1.y + $1.height
            return a == b ? $0.x < $1.x : a > b
        }
        var rows: [[OCRLine]] = []
        for line in byTop {
            if let last = rows.last, let first = last.first {
                let center = line.y + line.height / 2
                let rowCenter = last.reduce(0) { $0 + $1.y + $1.height / 2 } / Double(last.count)
                if abs(center - rowCenter) <= max(0.003, min(line.height, first.height) * 0.5) {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
    }

    private static func gaps(_ ranges: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = ranges.sorted { $0.0 < $1.0 }
        guard let first = sorted.first else { return [] }
        var end = first.1
        var output: [(Double, Double)] = []
        for range in sorted.dropFirst() {
            if range.0 > end { output.append((end, range.0)) }
            end = max(end, range.1)
        }
        return output
    }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0.03 : sorted[sorted.count / 2]
    }
}


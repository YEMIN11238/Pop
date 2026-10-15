import Foundation

struct PluginUpdate: Identifiable, Equatable {
    var id: String { pluginID }
    let pluginID: String
    let name: String
    let currentVersion: String
    let version: String
    let notes: String
    let downloadURL: URL
    let sha256: String
    let minBobVersion: String?
    let publishedAt: Date?
    let appcastURL: URL
}

enum PluginVersions {
    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        func tokens(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "[0-9]+|[a-z]+", options: .caseInsensitive)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased() } }
        }
        let a = tokens(left), b = tokens(right)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : nil, y = index < b.count ? b[index] : nil
            let xNumber = x?.first?.isNumber ?? true, yNumber = y?.first?.isNumber ?? true
            if xNumber && yNumber {
                let xs = String((x ?? "0").drop(while: { $0 == "0" })), ys = String((y ?? "0").drop(while: { $0 == "0" }))
                if xs.count != ys.count { return xs.count < ys.count ? .orderedAscending : .orderedDescending }
                if xs != ys { return xs < ys ? .orderedAscending : .orderedDescending }
            } else if x == nil { return .orderedDescending }
            else if y == nil { return .orderedAscending }
            else if xNumber != yNumber { return xNumber ? .orderedDescending : .orderedAscending }
            else if x != y { return x! < y! ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

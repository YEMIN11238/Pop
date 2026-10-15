import Foundation

/// Reconstructed from Bob Selection.swift (REA/Ghidra 0x10034bea4,
/// 0x100347e48, 0x1003486f0 and 0x100348a84). Modes change Copy retries and
/// 100 ms pasteboard polls; they do not select an unrelated OCR/AX algorithm.
struct SelectionTiming: Equatable {
    let attempts: Int
    let polls: Int
    static func resolve(mode: String, applicationID: String?) -> SelectionTiming {
        switch mode {
        case "effect": return SelectionTiming(attempts: 2, polls: 10)
        case "speed": return SelectionTiming(attempts: 1, polls: 1)
        default:
            switch applicationID {
            case "com.apple.iBooksX", "com.parallels.desktop.console": return SelectionTiming(attempts: 2, polls: 10)
            case "com.foxit-software.Foxit PDF Reader": return SelectionTiming(attempts: 2, polls: 6)
            case "com.google.Chrome", "com.tencent.qq", "com.tencent.xinWeChat": return SelectionTiming(attempts: 2, polls: 3)
            default: return SelectionTiming(attempts: 1, polls: 2)
            }
        }
    }
}

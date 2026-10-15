import SwiftUI

struct DictionaryResultView: View {
    let dictionary: DictionaryResult
    let fontSize: Double
    let speak: (DictionaryResult.Audio?, String) -> Void
    var lookup: (String) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let word = dictionary.word { Text(word).font(.system(size: fontSize + 2, weight: .semibold)) }
            ForEach(Array(dictionary.phonetics.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.type).foregroundStyle(.secondary)
                    Text(item.value ?? "").textSelection(.enabled)
                    if let word = dictionary.word { Button { speak(item.tts, word) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless) }
                }.font(.system(size: max(11, fontSize - 1)))
            }
            ForEach(Array(dictionary.parts.enumerated()), id: \.offset) { _, part in
                HStack(alignment: .top) {
                    if let name = part.part, !name.isEmpty { Text(name).italic().foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading) }
                    Text(part.means.joined(separator: "；")).textSelection(.enabled)
                }
            }
            ForEach(Array(dictionary.exchanges.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top) { Text(item.name).foregroundStyle(.secondary); ForEach(item.words, id: \.self) { word in Button(word) { lookup(word) }.buttonStyle(.borderless).foregroundStyle(.blue) } }
            }
            ForEach(Array(dictionary.relatedWordParts.enumerated()), id: \.offset) { _, group in
                if let part = group.part { Text(part).foregroundStyle(.secondary) }
                ForEach(Array(group.words.enumerated()), id: \.offset) { _, word in
                    HStack(alignment: .top) { Button(word.word) { lookup(word.word) }.buttonStyle(.borderless).foregroundStyle(.blue); Text(word.means.joined(separator: "；")).textSelection(.enabled) }
                }
            }
            ForEach(Array(dictionary.additions.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.caption).foregroundStyle(.secondary); Text(item.value).textSelection(.enabled) }
            }
        }.font(.system(size: max(11, fontSize - 1))).frame(maxWidth: .infinity, alignment: .leading)
    }
}

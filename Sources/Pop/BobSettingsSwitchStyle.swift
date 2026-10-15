import SwiftUI

/// Settings use a fixed 36×16 track rather than the host OS's changing switch
/// appearance. Its accessibility representation remains a labelled Toggle.
struct BobSettingsSwitchStyle: ToggleStyle {
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                Capsule().fill(configuration.isOn ? Color(red: 0, green: 122.0/255, blue: 1) : Color(red: 220.0/255, green: 220.0/255, blue: 222.0/255))
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.10), radius: 0.6, y: 0.4)
                    .offset(x: configuration.isOn ? 10 : -10)
            }.frame(width: 36, height: 16).opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }.buttonStyle(.plain)
            .accessibilityRepresentation { Toggle(label, isOn: configuration.$isOn).toggleStyle(.checkbox) }
    }
}

#if os(iOS)
import SwiftUI

/// Settings > App Icon: the four colorways, the current one checked. Picking one changes the Home
/// Screen icon at once (the system confirms it with its own alert).
struct AppIconView: View {
    @Binding var current: AppIconChoice
    @State private var previews: [AppIconChoice: UIImage] = [:]

    var body: some View {
        List {
            Section {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        guard choice != current else { return }
                        let previous = current
                        current = choice
                        Task { if await !AppIcons.set(choice) { current = previous } }
                    } label: {
                        HStack(spacing: 14) {
                            Group {
                                if let image = previews[choice] {
                                    Image(uiImage: image).resizable()
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(.rect(cornerRadius: 11, style: .continuous))
                            .accessibilityHidden(true)
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if choice == current {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Style.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .tint(.primary)
                    .accessibilityLabel(choice.accessibilityDescription)
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                }
            } footer: {
                Text("The icon on your Home Screen.")
            }
            .paperRows()
        }
        .paperSheet()
        .sheetTitle("App Icon")
        .task {
            for choice in AppIconChoice.allCases where previews[choice] == nil {
                previews[choice] = await AppIcons.preview(choice)
            }
        }
    }
}
#endif

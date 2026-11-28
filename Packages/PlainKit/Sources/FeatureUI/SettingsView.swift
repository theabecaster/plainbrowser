#if os(iOS)
import BrowserCore
import DesignSystem
import SwiftUI

/// The Settings sheet: seven rows (six where the icon can't change), each showing its value, and
/// one Done button.
///
/// Present it in a sheet. `onDone` runs when Done is tapped; without it the view dismisses itself.
public struct SettingsView: View {
    @Bindable private var model: SettingsModel
    private let onDone: (() -> Void)?
    @State private var confirmingClear = false
    /// The Home Screen icon. Read from the system, not stored: the system owns it.
    @State private var appIcon = AppIcons.current
    /// The App Icon row shows only where the icon can change (`AppIconSupport`).
    private let showsAppIcon: Bool

    /// - Parameter showsAppIcon: whether the icon can change here; the system's answer unless a
    ///   caller (a preview, a test) says otherwise.
    public init(model: SettingsModel, showsAppIcon: Bool = AppIcons.isSupported, onDone: (() -> Void)? = nil) {
        self.model = model
        self.showsAppIcon = showsAppIcon
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        NavigationLink {
                            SearchEngineView(model: model)
                        } label: {
                            ValueLabel("Search Engine", value: model.isLoaded ? model.settings.searchEngine.name : "")
                        }
                        .disabled(!model.isLoaded)
                    } footer: {
                        SettingsFooter(Wording.searchEngineFooter)
                    }

                    Section {
                        Picker("Tab Layout", selection: Binding(
                            get: { model.settings.tabLayout }, set: { model.setTabLayout($0) }
                        )) {
                            ForEach(TabLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.isLoaded || !model.isTabLayoutAvailable)
                        .accessibilityIdentifier("settings.tabLayout")
                    } footer: {
                        SettingsFooter(model.isTabLayoutAvailable ? Wording.tabLayoutFooter : Wording.tabLayoutUnavailableFooter)
                    }

                    Section {
                        Picker("Archive Tabs", selection: Binding(
                            get: { model.settings.archiveAfter }, set: { model.setArchiveAfter($0) }
                        )) {
                            ForEach(ArchiveAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.isLoaded)
                    } footer: {
                        SettingsFooter(model.settings.archiveAfter.footer)
                    }

                    Section {
                        Picker("Appearance", selection: Binding(
                            get: { model.settings.appearance }, set: { model.setAppearance($0) }
                        )) {
                            ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.isLoaded)
                        .accessibilityIdentifier("settings.appearance")
                    } footer: {
                        SettingsFooter(model.settings.appearance.footer)
                    }

                    // Under Appearance, but its own row: it is how websites look, never Plain itself.
                    Section {
                        Picker("Page Appearance", selection: Binding(
                            get: { model.settings.pageAppearance ?? .off }, set: { model.setPageAppearance($0) }
                        )) {
                            ForEach(PageAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.isLoaded)
                        .accessibilityIdentifier("settings.pageAppearance")
                    } footer: {
                        SettingsFooter(Wording.pageAppearanceFooter)
                    }

                    if showsAppIcon {
                        Section {
                            NavigationLink {
                                AppIconView(current: $appIcon)
                            } label: {
                                ValueLabel("App Icon", value: appIcon.title)
                            }
                            .accessibilityIdentifier("settingsAppIcon")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            HStack {
                                // Its own red: the sheet's ink would otherwise override the role's color.
                            Text("Clear History and Data").foregroundStyle(Color(uiColor: .systemRed))
                                Spacer()
                                if model.isClearing { ProgressView() }
                            }
                        }
                        .disabled(model.isClearing)
                        .confirmationDialog(Wording.clearConfirmTitle, isPresented: $confirmingClear, titleVisibility: .visible) {
                            Button("Clear History and Data", role: .destructive) {
                                Task { await model.clearHistoryAndData() }
                            }
                        } message: {
                            Text(Wording.clearConfirmMessage)
                        }
                    } footer: {
                        SettingsFooter(Wording.clearFooter)
                    }

                    Section {
                        NavigationLink {
                            AboutView(info: model.about)
                        } label: {
                            ValueLabel("About", value: model.about.version)
                        }
                    }
                }
                .paperRows()
            }
            .paperSheet()
            .sheetTitle("Settings", onDone: onDone)
            .alert(model.errorMessage ?? "", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        .tint(Style.accent)
        .task { await model.load() }
    }
}

/// Settings > Search Engine: the catalog, the custom engine when there is one, and the field to
/// set a custom engine.
struct SearchEngineView: View {
    @Bindable var model: SettingsModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(model.engineChoices) { engine in
                        Button {
                            model.selectSearchEngine(engine)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.name).foregroundStyle(.primary)
                                    if engine.isCustom {
                                        Text("Custom").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if engine == model.settings.searchEngine {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Style.accent)
                                        .accessibilityLabel("Selected")
                                }
                            }
                            .contentShape(.rect)
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(engine == model.settings.searchEngine ? .isSelected : [])
                    }
                }

                Section {
                    TextField("https://example.com/search?q=%s", text: $model.customTemplate)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit { if model.useCustomTemplate() { fieldFocused = false } }
                    let noTemplate = model.customTemplate.trimmingCharacters(in: .whitespaces).isEmpty
                    Button("Use Custom Engine") {
                        if model.useCustomTemplate() { fieldFocused = false }
                    }
                    // An action in the accent: the sheet's ink would otherwise take the button's tint.
                    .foregroundStyle(noTemplate ? Style.inkSecondary : Style.accent)
                    .disabled(noTemplate)
                } header: {
                    Text("Custom")
                } footer: {
                    if let error = model.customError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(Wording.customEngineFooter).foregroundStyle(.secondary)
                    }
                }
            }
            .paperRows()
        }
        .paperSheet()
        .sheetTitle("Search Engine")
    }
}

/// A section footer that breaks its lines as plain text does. SwiftUI's `Text` keeps a last
/// word from standing alone by pushing the one before it down too (`NSLineBreakStrategy
/// .pushOut`), so "Tabs you haven't opened in a week move to / the archive." broke a word early,
/// under the picker's value (clarity audit 23). A label with no line-break strategy fills each
/// line. Low-frequency screen: one label per footer.
struct SettingsFooter: UIViewRepresentable {
    let text: String

    init(_ text: String) { self.text = text }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakStrategy = []
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.inkSecondary
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        if label.text != text { label.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? label.intrinsicContentSize.width
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: PreviewData.settingsModel())
}
#endif
#endif

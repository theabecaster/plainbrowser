#if os(iOS)
import BrowserCore
import SwiftUI

/// The Settings sheet: six rows, each showing its value, and one Done button.
///
/// Present it in a sheet. `onDone` runs when Done is tapped; without it the view dismisses itself.
public struct SettingsView: View {
    @Bindable private var model: SettingsModel
    private let onDone: (() -> Void)?
    @State private var confirmingClear = false
    /// The Home Screen icon. Read from the system, not stored: the system owns it.
    @State private var appIcon = AppIcons.current

    public init(model: SettingsModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SearchEngineView(model: model)
                    } label: {
                        LabeledContent("Search Engine", value: model.isLoaded ? model.settings.searchEngine.name : "")
                    }
                    .disabled(!model.isLoaded)
                } footer: {
                    Text(Wording.searchEngineFooter)
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
                    Text(model.isTabLayoutAvailable ? Wording.tabLayoutFooter : Wording.tabLayoutUnavailableFooter)
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
                    Text(model.settings.archiveAfter.footer)
                }

                Section {
                    NavigationLink {
                        AppIconView(current: $appIcon)
                    } label: {
                        LabeledContent("App Icon", value: appIcon.title)
                    }
                    .accessibilityIdentifier("settingsAppIcon")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        HStack {
                            Text("Clear History and Data")
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
                    Text(Wording.clearFooter)
                }

                Section {
                    NavigationLink {
                        AboutView(info: model.about)
                    } label: {
                        LabeledContent("About", value: model.about.version)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton(onDone: onDone) }
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
                Button("Use Custom Engine") {
                    if model.useCustomTemplate() { fieldFocused = false }
                }
                .disabled(model.customTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Custom")
            } footer: {
                if let error = model.customError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(Wording.customEngineFooter)
                }
            }
        }
        .navigationTitle("Search Engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: PreviewData.settingsModel())
}
#endif
#endif

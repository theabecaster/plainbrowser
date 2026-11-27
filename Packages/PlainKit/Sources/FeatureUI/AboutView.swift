#if os(iOS)
import SwiftUI

/// Settings > About: the version, the source code link and the license texts.
public struct AboutView: View {
    private let info: AboutInfo

    public init(info: AboutInfo = .current) {
        self.info = info
    }

    public var body: some View {
        List {
            // The name on the paper itself, in the intro's New York with its coral fold.
            Section {
                VStack(spacing: 6) {
                    DisplayText(lead: "", emphasis: info.name, trail: "")
                    Text(info.versionLine).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: info.sourceURL) {
                    LabeledContent("Source Code") {
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                ForEach(info.documents) { document in
                    NavigationLink(document.title) {
                        DocumentView(document: document)
                    }
                }
            } footer: {
                Text("Plain is free software under the GNU Affero General Public License 3.0.")
            }
            .paperRows()
        }
        .paperSheet()
        .sheetTitle("About")
    }
}

/// One license or notice text, read off the main thread when it opens.
struct DocumentView: View {
    let document: AboutInfo.Document
    @State private var text: String?
    @State private var failed = false

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else if failed {
                ContentUnavailableView("Plain couldn't open this file.", systemImage: "doc")
            }
        }
        .paperSheet()
        .sheetTitle(document.title)
        .task {
            text = await AboutInfo.text(of: document)
            failed = text == nil
        }
    }
}

#if DEBUG
#Preview("About") {
    NavigationStack { AboutView(info: PreviewData.about) }
}
#endif
#endif

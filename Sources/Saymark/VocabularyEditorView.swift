import SaymarkKit
import SwiftUI

/// Editor for the custom dictionary: each row is a canonical term plus the
/// comma-separated mishearings that get rewritten to it. Edits persist immediately
/// via `VocabularyStore` and take effect on the next dictation.
struct VocabularyEditorView: View {
    @Bindable var store: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($store.entries) { $entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        TextField("Term", text: $entry.term, prompt: Text("Saymark"))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.remove(entry)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this term")
                    }
                    TextField("Heard as", text: aliasesText($entry),
                              prompt: Text("cmarc, say mark"))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    store.addEntry()
                } label: {
                    Label("Add term", systemImage: "plus")
                }
                Spacer()
                if store.entries != VocabularyStore.seed {
                    Button("Restore example") { store.resetToDefaults() }
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    /// Bridges the entry's `[String]` aliases to a comma-separated text field.
    private func aliasesText(_ entry: Binding<VocabularyEntry>) -> Binding<String> {
        Binding(
            get: { entry.wrappedValue.aliases.joined(separator: ", ") },
            set: { newValue in
                entry.wrappedValue.aliases = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

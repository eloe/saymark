import AppKit
import Observation
import SaymarkKit
import SwiftUI

/// Main-actor façade for the explicitly local vocabulary document. It exposes
/// no transcript or rule value to analytics/diagnostics.
@MainActor
@Observable
final class VocabularySettingsModel {
    static let shared = VocabularySettingsModel()

    private let store: VocabularyStore
    private(set) var entries: [VocabularyEntry] = []
    private(set) var errorMessage: String?
    var search = ""
    var showEditor = false
    var editing: VocabularyEntry?
    var importPreview: VocabularyImportPreview?
    var importURL: URL?
    var importStrategy: VocabularyImportStrategy = .mergeByID
    var acknowledgedURLs = false
    var showImportPreview = false

    private init() {
        let directory = VocabularyStore.applicationSupportURL(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.eloe.saymark")
        do { store = try VocabularyStore(directoryURL: directory) }
        catch {
            // A read failure keeps dictation raw-first and the existing document
            // untouched; this empty store does not overwrite it.
            store = try! VocabularyStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("saymark-vocabulary-recovery"))
            errorMessage = "Vocabulary could not be opened. Dictation will use raw text until it is recovered."
        }
        reload()
    }

    var snapshot: VocabularySnapshot { store.snapshot() }
    var filteredEntries: [VocabularyEntry] {
        guard !search.isEmpty else { return entries }
        let query = search.localizedCaseInsensitiveContains
        return entries.filter { query($0.written) || $0.heard.contains(where: query) }
    }

    func reload() { entries = store.currentDocument().entries.sorted { $0.written.localizedStandardCompare($1.written) == .orderedAscending } }
    func beginAdd() { editing = nil; showEditor = true }
    func beginEdit(_ entry: VocabularyEntry) { editing = entry; showEditor = true }
    func save(_ entry: VocabularyEntry) {
        do { try store.upsert(entry); reload(); showEditor = false; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    func setEnabled(_ entry: VocabularyEntry, _ enabled: Bool) {
        var updated = entry; updated.enabled = enabled; updated.updatedAt = Date(); save(updated)
    }
    func delete(_ entry: VocabularyEntry) {
        do { try store.delete(id: entry.id); reload(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importURL = url; importStrategy = .mergeByID; acknowledgedURLs = false
            importPreview = try store.importDocument(from: url, strategy: .mergeByID)
            showImportPreview = true; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshImportPreview() {
        guard let importURL else { return }
        do { importPreview = try store.importDocument(from: importURL, strategy: importStrategy); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func applyImport() {
        guard let importURL else { return }
        do {
            try store.applyImport(from: importURL, strategy: importStrategy, acknowledgedURLs: acknowledgedURLs)
            reload(); showImportPreview = false; self.importURL = nil; importPreview = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "saymark-vocabulary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(to: url); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

struct VocabularySettingsSection: View {
    @State private var model = VocabularySettingsModel.shared

    var body: some View {
        Section {
            TextField("Search Vocabulary", text: $model.search)
                .accessibilityLabel("Search Vocabulary")
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).accessibilityLabel("Vocabulary error: \(message)")
            }
            if model.filteredEntries.isEmpty {
                ContentUnavailableView("No vocabulary yet", systemImage: "text.book.closed",
                    description: Text("Add explicit local rules for words Saymark hears incorrectly. Saymark never learns from your dictation."))
            } else {
                ForEach(model.filteredEntries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.written).fontWeight(.medium)
                            Text(entry.heard.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enable \(entry.written)", isOn: Binding(get: { entry.enabled }, set: { model.setEnabled(entry, $0) }))
                            .labelsHidden()
                        Button("Edit") { model.beginEdit(entry) }
                        Button("Delete", role: .destructive) { model.delete(entry) }
                    }
                }
            }
            Button("Add vocabulary") { model.beginAdd() }
                .accessibilityHint("Add a written replacement and explicit heard-as phrases")
            HStack {
                Button("Import…") { model.chooseImport() }
                Button("Export…") { model.export() }
            }
        } header: { Text("Vocabulary") }
        footer: { Text("Rules change written text only. They do not train the speech model and stay on this Mac.") }
        .sheet(isPresented: $model.showEditor) { VocabularyRuleEditor(model: model, existing: model.editing) }
        .sheet(isPresented: $model.showImportPreview) { VocabularyImportPreviewView(model: model) }
    }
}

private struct VocabularyImportPreviewView: View {
    let model: VocabularySettingsModel
    @State private var confirmReplace = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review vocabulary import").font(.headline)
            Picker("Import", selection: Binding(get: { model.importStrategy }, set: { model.importStrategy = $0; model.refreshImportPreview() })) {
                Text("Merge by ID").tag(VocabularyImportStrategy.mergeByID)
                Text("Replace all").tag(VocabularyImportStrategy.replaceAll)
            }
            .pickerStyle(.segmented)
            if let preview = model.importPreview {
                Text("\(preview.newCount) new, \(preview.updatedCount) updated, \(preview.unchangedCount) unchanged, \(preview.disabledCount) disabled")
                List(preview.diffs, id: \.id) { diff in
                    VStack(alignment: .leading) {
                        Text(diff.new.written)
                        if let old = diff.old { Text("Replaces \(old.written)").foregroundStyle(.secondary) }
                        Text("When I say: \(diff.new.heard.joined(separator: ", "))").foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 140)
                if preview.containsURL {
                    Toggle("I understand this import changes a written value to a URL.", isOn: Binding(get: { model.acknowledgedURLs }, set: { model.acknowledgedURLs = $0 }))
                }
            }
            if model.importStrategy == .replaceAll {
                Toggle("I understand Replace all removes my current vocabulary.", isOn: $confirmReplace)
                    .accessibilityHint("Destructive confirmation")
            }
            HStack {
                Button("Cancel") { model.showImportPreview = false }
                Spacer()
                Button("Import") { model.applyImport() }
                    .disabled((model.importPreview?.containsURL == true && !model.acknowledgedURLs) || (model.importStrategy == .replaceAll && !confirmReplace))
            }
        }.padding().frame(width: 540, height: 460)
    }
}

private struct VocabularyRuleEditor: View {
    let model: VocabularySettingsModel
    let existing: VocabularyEntry?
    @State private var written = ""
    @State private var heard = ""

    init(model: VocabularySettingsModel, existing: VocabularyEntry?) {
        self.model = model; self.existing = existing
        _written = State(initialValue: existing?.written ?? "")
        _heard = State(initialValue: existing?.heard.joined(separator: ", ") ?? "")
    }

    private var candidate: VocabularyEntry {
        VocabularyEntry(id: existing?.id ?? UUID(), kind: existing?.kind ?? .vocabulary, written: written,
                        heard: heard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                        enabled: existing?.enabled ?? true, createdAt: existing?.createdAt ?? Date(), updatedAt: Date())
    }
    private var preview: String { (try? VocabularySnapshot(document: VocabularyDocument(entries: [candidate])))?.correct("Try \(heard)").renderedText ?? "Add a valid rule to preview it." }

    var body: some View {
        Form {
            TextField("Write", text: $written).accessibilityLabel("Write")
            TextField("When I say", text: $heard).accessibilityLabel("When I say")
            Text("Separate alternatives with commas.").foregroundStyle(.secondary)
            LabeledContent("Preview", value: preview).accessibilityLabel("Deterministic preview: \(preview)")
            Text("This changes written text only. It does not train the speech model.").foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.showEditor = false }
                Spacer()
                Button("Save") { model.save(candidate) }.disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding().frame(width: 460)
    }
}

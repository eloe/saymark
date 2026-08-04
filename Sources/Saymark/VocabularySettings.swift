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

    nonisolated private let store: VocabularyStore?
    private(set) var entries: [VocabularyEntry] = []
    private(set) var errorMessage: String?
    private(set) var recoveryFileURL: URL?
    private(set) var isReadOnly = false
    private(set) var isStorageAvailable = false
    private(set) var preservesOpaqueDocumentForExport = false
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
        do {
            let opened = try VocabularyStore(directoryURL: directory)
            store = opened
            errorMessage = opened.recoveryMessage ?? opened.readOnlyReason
            recoveryFileURL = opened.recoveryFileURL
            isReadOnly = opened.readOnlyReason != nil
            isStorageAvailable = true
            preservesOpaqueDocumentForExport = opened.preservesOpaqueDocumentForExport
        }
        catch {
            // Never divert sensitive vocabulary to /tmp.  The store itself can
            // recover a valid backup; a directory creation failure is surfaced
            // as an unavailable local settings surface rather than copied to a
            // less private fallback location.
            store = nil
            errorMessage = "Vocabulary could not be opened. Dictation will use raw text until local storage is available."
            isReadOnly = true
        }
        reload()
    }

    init(store: VocabularyStore?) {
        self.store = store
        guard let store else {
            errorMessage = "Vocabulary could not be opened. Dictation will use raw text until local storage is available."
            isReadOnly = true
            return
        }
        errorMessage = store.recoveryMessage ?? store.readOnlyReason
        recoveryFileURL = store.recoveryFileURL
        isReadOnly = store.readOnlyReason != nil
        isStorageAvailable = true
        preservesOpaqueDocumentForExport = store.preservesOpaqueDocumentForExport
        reload()
    }

    nonisolated var snapshot: VocabularySnapshot { store?.snapshot() ?? .empty }
    var filteredEntries: [VocabularyEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { entry in
            entry.written.localizedCaseInsensitiveContains(search)
                || entry.heard.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var canExport: Bool { isStorageAvailable && (!isReadOnly || preservesOpaqueDocumentForExport) }
    var exportAccessibilityHint: String {
        if !isStorageAvailable {
            return "Export is unavailable because local vocabulary storage could not be opened"
        }
        if preservesOpaqueDocumentForExport {
            return "Saves the original newer-format JSON file without changes"
        }
        if isReadOnly {
            return "Export is unavailable; use the Finder recovery action"
        }
        return "Saves a private local schema version 2 JSON file"
    }

    func reload() { entries = store?.currentDocument().entries.sorted { $0.written.localizedStandardCompare($1.written) == .orderedAscending } ?? [] }
    func beginAdd() { editing = nil; showEditor = true }
    func beginEdit(_ entry: VocabularyEntry) { editing = entry; showEditor = true }
    func save(_ entry: VocabularyEntry) {
        guard let store else { errorMessage = "Vocabulary storage is unavailable."; return }
        do { try store.upsert(entry); reload(); showEditor = false; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    func setEnabled(_ entry: VocabularyEntry, _ enabled: Bool) {
        var updated = entry; updated.enabled = enabled; updated.updatedAt = Date(); save(updated)
    }
    func delete(_ entry: VocabularyEntry) {
        guard let store else { errorMessage = "Vocabulary storage is unavailable."; return }
        do { try store.delete(id: entry.id); reload(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func chooseImport() {
        guard let store else { errorMessage = "Vocabulary storage is unavailable."; return }
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
        guard let importURL, let store else { return }
        do { importPreview = try store.importDocument(from: importURL, strategy: importStrategy); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func applyImport() {
        guard let importURL, let store else { return }
        do {
            try store.applyImport(from: importURL, strategy: importStrategy, acknowledgedURLs: acknowledgedURLs, previewToken: importPreview?.sourceToken)
            reload(); showImportPreview = false; self.importURL = nil; importPreview = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func export() {
        guard let store else { errorMessage = "Vocabulary storage is unavailable."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "saymark-vocabulary.json"
        panel.message = "Vocabulary files may contain names and internal terms. Store the export somewhere private."
        panel.prompt = "Export vocabulary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(to: url); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func revealRecoveryFile() {
        guard let recoveryFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryFileURL])
    }
}

struct VocabularySettingsSection: View {
    @State private var model: VocabularySettingsModel

    @MainActor
    init() {
        _model = State(initialValue: .shared)
    }

    @MainActor
    init(model: VocabularySettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section {
            TextField("Search Vocabulary", text: $model.search)
                .accessibilityLabel("Search Vocabulary")
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).accessibilityLabel("Vocabulary error: \(message)")
            }
            if model.recoveryFileURL != nil {
                Button("Show retained vocabulary file in Finder") {
                    model.revealRecoveryFile()
                }
                .accessibilityHint("Locates the original unreadable file for manual recovery")
            }
            if !model.isStorageAvailable {
                ContentUnavailableView(
                    "Vocabulary storage unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Editing, import, export, and correction are disabled until local storage can be opened.")
                )
            } else if model.isReadOnly {
                ContentUnavailableView(
                    model.preservesOpaqueDocumentForExport
                        ? "Vocabulary requires a newer Saymark"
                        : "Vocabulary is unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        model.preservesOpaqueDocumentForExport
                            ? "This file may contain rules. Editing and correction are disabled, but Export saves the original file unchanged."
                            : "The retained file may contain rules. Editing and correction are disabled; use the Finder recovery action above."
                    )
                )
            } else if model.filteredEntries.isEmpty {
                ContentUnavailableView(
                    model.entries.isEmpty ? "No vocabulary yet" : "No matching vocabulary",
                    systemImage: model.entries.isEmpty ? "text.book.closed" : "magnifyingglass",
                    description: Text(
                        model.entries.isEmpty
                            ? "Add explicit local rules for words Saymark hears incorrectly. Saymark never learns from your dictation."
                            : "Change or clear the search to show your local rules."
                    )
                )
            } else {
                ForEach(model.filteredEntries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.written).fontWeight(.medium)
                            Text(entry.heard.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Vocabulary entry \(entry.written)")
                        .accessibilityValue("When I say: \(entry.heard.joined(separator: ", ")).")
                        Spacer()
                        Toggle("Enable \(entry.written)", isOn: Binding(get: { entry.enabled }, set: { model.setEnabled(entry, $0) }))
                            .labelsHidden()
                            .accessibilityLabel("Enable \(entry.written)")
                            .accessibilityValue(entry.enabled ? "On" : "Off")
                            .accessibilityHint("Controls whether this rule changes dictated text")
                            .disabled(model.isReadOnly)
                        Button("Edit") { model.beginEdit(entry) }
                            .accessibilityLabel("Edit \(entry.written)")
                            .disabled(model.isReadOnly)
                        Button("Delete", role: .destructive) { model.delete(entry) }
                            .accessibilityLabel("Delete \(entry.written)")
                            .accessibilityHint("Permanently removes this local rule")
                            .disabled(model.isReadOnly)
                    }
                }
            }
            Button("Add vocabulary") { model.beginAdd() }
                .accessibilityHint("Add a written replacement and explicit heard-as phrases")
                .disabled(model.isReadOnly)
            HStack {
                Button("Import…") { model.chooseImport() }
                    .disabled(model.isReadOnly)
                Button("Export…") { model.export() }
                    .accessibilityHint(model.exportAccessibilityHint)
                    .disabled(!model.canExport)
            }
        } header: { Text("Vocabulary") }
        footer: { Text("Rules change written text only. They do not train the speech model and stay on this Mac.") }
        .sheet(isPresented: $model.showEditor) { VocabularyRuleEditor(model: model, existing: model.editing) }
        .sheet(isPresented: $model.showImportPreview) { VocabularyImportPreviewView(model: model) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityIdentifier("settings.vocabulary")
    }
}

enum VocabularyImportDiffPresentation {
    static func lines(for diff: VocabularyEntryDiff) -> [String] {
        lines(id: diff.id, old: diff.old, new: diff.new)
    }

    static func lines(id: UUID, old: VocabularyEntry?, new: VocabularyEntry?) -> [String] {
        switch (old, new) {
        case (nil, let new?):
            return ["Change: Added", "ID: \(id.uuidString)"] + entryLines(new)
        case (let old?, nil):
            return ["Change: Deleted", "ID: \(id.uuidString)"] + entryLines(old)
        case (let old?, let new?):
            var result = ["Change: Updated", "ID: \(id.uuidString)"]
            if old.kind != new.kind { result.append("Kind: \(old.kind.rawValue) → \(new.kind.rawValue)") }
            if old.written != new.written { result.append("Write: \(old.written) → \(new.written)") }
            if old.heard != new.heard {
                result.append("When I say: \(old.heard.joined(separator: ", ")) → \(new.heard.joined(separator: ", "))")
            }
            if old.enabled != new.enabled {
                result.append("Enabled: \(enabled(old.enabled)) → \(enabled(new.enabled))")
            }
            if old.createdAt != new.createdAt {
                result.append("Created: \(timestamp(old.createdAt)) → \(timestamp(new.createdAt))")
            }
            if old.updatedAt != new.updatedAt {
                result.append("Modified: \(timestamp(old.updatedAt)) → \(timestamp(new.updatedAt))")
            }
            return result
        case (nil, nil):
            return ["Change: Invalid", "ID: \(id.uuidString)"]
        }
    }

    private static func entryLines(_ entry: VocabularyEntry) -> [String] {
        [
            "Kind: \(entry.kind.rawValue)",
            "Write: \(entry.written)",
            "When I say: \(entry.heard.joined(separator: ", "))",
            "Enabled: \(enabled(entry.enabled))",
            "Created: \(timestamp(entry.createdAt))",
            "Modified: \(timestamp(entry.updatedAt))",
        ]
    }

    private static func enabled(_ value: Bool) -> String { value ? "Enabled" : "Disabled" }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
                Text("\(preview.newCount) new, \(preview.updatedCount) updated, \(preview.unchangedCount) unchanged, \(preview.disabledCount) disabled, \(preview.conflictCount) conflicts")
                if preview.conflictCount > 0 {
                    Label(
                        "Resolve duplicate “When I say” phrases before importing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(preview.conflictCount) vocabulary conflicts. Resolve duplicate When I say phrases before importing.")
                    ForEach(preview.conflicts, id: \.canonicalTrigger) { conflict in
                        Text(
                            "“\(conflict.canonicalTrigger)” conflicts in entries "
                                + conflict.entryIDs.map(\.uuidString).joined(separator: ", ")
                        )
                        .foregroundStyle(.red)
                    }
                }
                List(preview.diffs, id: \.id) { diff in
                    VStack(alignment: .leading) {
                        Text(diff.new?.written ?? diff.old?.written ?? "Vocabulary rule")
                        if diff.containsURL {
                            Label("Written value contains a URL", systemImage: "link")
                                .foregroundStyle(.orange)
                        }
                        ForEach(
                            Array(VocabularyImportDiffPresentation.lines(for: diff).enumerated()),
                            id: \.offset
                        ) { _, line in
                            if diff.change == .deleted {
                                Text(line).foregroundStyle(.red)
                            } else {
                                Text(line).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(minHeight: 140)
                if preview.containsURL {
                    Toggle("I understand this import changes a written value to a URL.", isOn: Binding(get: { model.acknowledgedURLs }, set: { model.acknowledgedURLs = $0 }))
                        .accessibilityHint("Required before importing URL-valued replacements")
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
                    .disabled(
                        (model.importPreview?.conflictCount ?? 0) > 0
                            || (model.importPreview?.containsURL == true && !model.acknowledgedURLs)
                            || (model.importStrategy == .replaceAll && !confirmReplace)
                    )
            }
        }.padding().frame(width: 540, height: 460)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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

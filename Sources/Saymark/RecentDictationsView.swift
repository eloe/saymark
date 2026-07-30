import AppKit
import SwiftUI
import SaymarkKit

struct RecentDictationsView: View {
    let controller: RecentDictationsController
    @State private var selectedID: String?
    @State private var search = ""

    private var selected: HistoryRecord? {
        controller.records.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HistorySearchField(text: $search)
                .frame(height: 28)
                .padding(12)
                .onChange(of: search) { _, value in
                    controller.scheduleSearch(value)
                }

            Text(controller.resultSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityIdentifier("recent-dictations.result-count")

            HSplitView {
                VStack(spacing: 0) {
                    List(controller.records, selection: $selectedID) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.text.historyExcerpt)
                                .lineLimit(2)
                            Text(record.deliveryState.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                        .accessibilityLabel("Dictation preview")
                        .accessibilityValue(record.text.historyExcerpt)
                    }
                    .accessibilityIdentifier("recent-dictations.list")
                    if controller.canLoadMore {
                        Button("Load 5 More") { controller.loadMore() }
                            .buttonStyle(.plain)
                            .padding(8)
                            .accessibilityHint("Shows up to 25 recent dictations")
                    }
                }
                .frame(minWidth: 250)

                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        SelectableHistoryText(text: selected.text)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(selected.deliveryState.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy") { controller.copy(selected) }
                            Button("Reinsert") { controller.requestReinsert(selected) }
                            Spacer()
                            Button("Delete", role: .destructive) { controller.requestDelete(selected) }
                        }
                    } else {
                        ContentUnavailableView("No Recent Dictations", systemImage: "clock")
                    }
                    if let error = controller.errorMessage {
                        Text(error).foregroundStyle(.secondary).font(.caption)
                    }
                }
                .padding(16)
                .frame(minWidth: 300)
            }
        }
        .onAppear { Task { await controller.refresh() } }
        .confirmationDialog(
            "Reinsert into \(controller.reinsertTargetName)?",
            isPresented: Binding(
                get: { controller.pendingReinsert != nil },
                set: { if !$0 { controller.cancelReinsert() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reinsert") { controller.confirmReinsert() }
            Button("Cancel", role: .cancel) { controller.cancelReinsert() }
        } message: {
            Text("Saymark will switch back to \(controller.reinsertTargetName). If it is unavailable or protected, the exact text will be copied instead.")
        }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: Binding(
                get: { controller.pendingDeletion != nil },
                set: { if !$0 { controller.cancelDelete() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { controller.confirmDelete() }
            Button("Cancel", role: .cancel) { controller.cancelDelete() }
        } message: {
            Text("This removes the saved text from Saymark’s current local history store.")
        }
        .onDisappear { search = "" }
    }
}

extension String {
    /// Lists are deliberately preview-only. Full transcript text is exposed
    /// solely in the selected detail pane or by an explicit Copy/Reinsert.
    var historyExcerpt: String {
        let limit = 180
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}

private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = makePrivateHistorySearchField()
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: HistorySearchField
        init(_ parent: HistorySearchField) { self.parent = parent }
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }
            configurePrivateHistoryTextView(editor)
        }
        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSSearchField)?.stringValue ?? ""
        }
    }
}

private struct SelectableHistoryText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        configurePrivateHistoryTextView(view)
        view.setAccessibilityIdentifier("recent-dictations.detail")
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.string = text
    }
}

func makePrivateHistorySearchField() -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search recent dictations"
    field.recentsAutosaveName = nil
    field.setAccessibilityIdentifier("recent-dictations.search")
    return field
}

func configurePrivateHistoryTextView(_ view: NSTextView) {
    view.isContinuousSpellCheckingEnabled = false
    view.isGrammarCheckingEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextCompletionEnabled = false
}

private extension HistoryDeliveryState {
    var displayName: String {
        switch self {
        case .pending: return "Delivery status unknown"
        case .inserted: return "Inserted"
        case .copiedAccessibility: return "Copied — Accessibility needed"
        case .insertionFailed: return "Copied — couldn’t paste"
        }
    }
}

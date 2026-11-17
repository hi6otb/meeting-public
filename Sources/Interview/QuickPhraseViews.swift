import SwiftUI
import AppKit

struct QuickPhraseBar: View {
    @ObservedObject var app: AppModel
    @State private var expanded = false
    @State private var hovered: UUID?
    @Environment(\.colorScheme) private var colorScheme
    private let rowHeight: CGFloat = 34
    var body: some View {
        VStack(spacing: 0) {
            if app.quickPhraseLibrary.phrases.isEmpty {
                Button("定型文を追加") { app.openQuickPhraseSettings() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading).padding(.horizontal, 10)
            } else if expanded {
                PersistentPhraseScrollView(contentHeight: CGFloat(app.quickPhraseLibrary.phrases.count) * rowHeight) {
                    VStack(spacing: 0) {
                        ForEach(Array(app.quickPhraseLibrary.phrases.enumerated()), id: \.element.id) { index, phrase in
                            row(phrase, number: index + 1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading).focusEffectDisabled()
                }.frame(maxWidth: .infinity).frame(height: rowHeight * CGFloat(min(3, app.quickPhraseLibrary.phrases.count)))
            } else if let phrase = app.quickPhraseLibrary.selected {
                row(phrase, number: nil).padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
            }
        }
        .padding(.bottom, 8)
        .background(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.975), in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .padding(.leading, 32).padding(.trailing, 20)
        // The bottom edge sits under the composer, like a tab emerging from it.
        .padding(.bottom, -8)
        .focusEffectDisabled()
        .onExitCommand { expanded = false }
        .onChange(of: app.selectedTemplate.id) { _, _ in expanded = false; hovered = nil }
    }
    private func row(_ phrase: QuickPhrase, number: Int?) -> some View {
        HStack(spacing: 0) {
            Group {
                if let number {
                    Text(String(number)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Button { expanded = true } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: rowHeight).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("定型文を展開")
                        .accessibilityLabel("定型文を展開")
                }
            }.frame(width: 28, height: rowHeight)
            Button {
                if expanded { app.selectQuickPhrase(phrase.id); expanded = false }
                else { expanded = true }
            } label: {
                Text(phrase.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).help(phrase.text)
                .accessibilityLabel(expanded ? "定型文を選択：\(phrase.text)" : "定型文を展開：\(phrase.text)")
            Button { app.sendQuickPhrase(phrase); expanded = false } label: {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 4)
                .disabled(app.busy || app.applyingTemplate).help("Codexへ送信")
                .accessibilityLabel("定型文を送信：\(phrase.text)")
        }.background(Color.primary.opacity(hovered == phrase.id ? 0.008 : 0))
            .onHover { hovered = $0 ? phrase.id : nil }
    }
}

struct QuickPhraseSettingsView: View {
    @ObservedObject var app: AppModel
    let templateID: UUID
    private var library: QuickPhraseLibrary { app.quickPhrases(for: templateID) }
    @State private var editingID: UUID?
    @State private var text = ""
    @State private var adding = false
    @State private var initialized = false
    @State private var saveError: String?
    @State private var editorFocusRequest = 0
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(library.phrases) { phrase in
                                Button { edit(phrase) } label: {
                                    HStack(spacing: 5) {
                                        Text(String((library.phrases.firstIndex(where: { $0.id == phrase.id }) ?? 0) + 1))
                                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                                        Text(phrase.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        if phrase.id == library.defaultPhrase?.id {
                                            Text("標準").font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                    }.padding(8).contentShape(Rectangle())
                                        .background(editingID == phrase.id && !adding ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).id(phrase.id.uuidString)
                            }
                            if adding {
                                Text("新しい定型文").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                                    .id("newPhrase")
                            }
                        }
                    }.onChange(of: adding) { _, value in if value { proxy.scrollTo("newPhrase", anchor: .bottom) } }
                }
                HStack {
                    Button { beginAdding() } label: { Label("追加", systemImage: "plus") }
                    Spacer()
                    Button { if let id = editingID { app.moveQuickPhrase(id, offset: -1, templateID: templateID) } } label: { Image(systemName: "arrow.up") }
                        .disabled(adding || editingID == nil || editingID == library.phrases.first?.id)
                        .help("上に移動").accessibilityLabel("上に移動")
                    Button { if let id = editingID { app.moveQuickPhrase(id, offset: 1, templateID: templateID) } } label: { Image(systemName: "arrow.down") }
                        .disabled(adding || editingID == nil || editingID == library.phrases.last?.id)
                        .help("下に移動").accessibilityLabel("下に移動")
                }
            }.frame(width: 132)
            VStack(alignment: .leading, spacing: 10) {
                SubmitTextEditor(text: $text, focusRequest: editorFocusRequest, accessibilityLabel: "定型文", placeholder: "定型文を入力…") { savePhrase() }
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
                if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    if let id = editingID, !adding {
                        Button("削除") {
                            app.deleteQuickPhrase(id, templateID: templateID)
                            if let first = library.phrases.first { edit(first) }
                            else { beginAdding() }
                        }
                    }
                    if let id = editingID, !adding {
                        Button(id == library.defaultPhrase?.id ? "標準" : "標準にする") { app.setDefaultQuickPhrase(id, templateID: templateID) }
                            .disabled(id == library.defaultPhrase?.id)
                    }
                    Spacer()
                    Button("保存") { savePhrase() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.frame(maxHeight: .infinity).focusEffectDisabled()
            .onAppear {
                guard !initialized else { return }
                initialized = true
                if let phrase = library.selected { edit(phrase) }
                else { beginAdding() }
            }
    }
    private func savePhrase() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = app.saveQuickPhrase(id: adding ? nil : editingID, text: text, templateID: templateID),
           let saved = library.phrases.first(where: { $0.id == id }) {
            edit(saved)
            app.selectQuickPhrase(id, templateID: templateID)
        } else { saveError = app.error ?? "定型文を保存できませんでした。" }
    }
    private func beginAdding() {
        adding = true; editingID = nil; text = ""; saveError = nil; editorFocusRequest += 1
    }
    private func edit(_ phrase: QuickPhrase) {
        adding = false; editingID = phrase.id; text = phrase.text; saveError = nil
    }
}

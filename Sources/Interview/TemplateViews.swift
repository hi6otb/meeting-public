import SwiftUI

struct RecordingButton: View {
    @ObservedObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !app.recording || reduceMotion)) { context in
            let illuminated = !app.recording || reduceMotion || Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
            Button {
                Task { if app.recording { await app.stopRecording() } else { await app.startRecording() } }
            } label: {
                Image(systemName: app.recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 14)).foregroundStyle(.red)
                    .opacity(illuminated ? 1 : 0.22).frame(width: 30, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).focusEffectDisabled().disabled(app.preparing || app.stopping)
                .help(app.recording ? "記録を停止" : "記録を開始")
                .accessibilityLabel(app.recording ? "記録を停止" : "記録を開始")
        }
    }
}

struct TemplateSettingsView: View {
    @ObservedObject var app: AppModel
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("既定のテンプレート")
                Spacer()
                Picker("既定のテンプレート", selection: Binding(get: { app.templateLibrary.defaultID }, set: { app.setDefaultTemplate($0) })) {
                    ForEach(app.templateLibrary.templates) { template in Text(template.name).tag(template.id) }
                }.labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(app.templateLibrary.templates) { template in
                                Button { edit(template) } label: {
                                    HStack {
                                        Text(template.name).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if template.id == app.templateLibrary.defaultID { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.secondary) }
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .background(editingID == template.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        if let id = app.saveTemplate(id: nil, name: "新しいテンプレート", prompt: PromptTemplate.standard.prompt),
                           let saved = app.templateLibrary.templates.first(where: { $0.id == id }) {
                            app.settingsTemplateSection = 0; edit(saved)
                        } else { saveError = app.error }
                    } label: { Label("追加", systemImage: "plus") }.frame(maxWidth: .infinity)
                }.frame(width: 125)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("編集内容", selection: $app.settingsTemplateSection) {
                        Text("プロンプト").tag(0)
                        Text("定型文").tag(1)
                    }.pickerStyle(.segmented).labelsHidden()
                    if app.settingsTemplateSection == 1, let editingID {
                        QuickPhraseSettingsView(app: app, templateID: editingID).id(editingID)
                    } else {
                        TextField("テンプレート名", text: $name).textFieldStyle(.roundedBorder)
                        TextEditor(text: $prompt).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
                            .accessibilityLabel("システムプロンプト")
                        HStack {
                            Spacer()
                            Button("保存") {
                                if let id = app.saveTemplate(id: editingID, name: name, prompt: prompt),
                                   let saved = app.templateLibrary.templates.first(where: { $0.id == id }) { edit(saved) }
                                else { saveError = app.error }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(.red) }
                }
            }.frame(height: 320)
        }.padding(18).focusEffectDisabled().onAppear {
            let target = app.templateLibrary.templates.first { $0.id == app.settingsTemplateID } ?? app.selectedTemplate
            edit(target)
        }
    }
    private func edit(_ template: PromptTemplate) {
        editingID = template.id; app.settingsTemplateID = template.id
        name = template.name; prompt = template.prompt; saveError = nil
    }
}

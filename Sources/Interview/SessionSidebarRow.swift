import SwiftUI

struct SessionSidebarRow: View {
    @ObservedObject var app: AppModel
    let session: Session
    @State private var hovered = false
    @State private var renaming = false
    @State private var title = ""
    @State private var confirmingDeletion = false

    var body: some View {
        HStack(spacing: 0) {
            Button { app.select(session.id) } label: {
                HStack(spacing: 10) {
                    if app.generatingTitleIDs.contains(session.id) {
                        ProgressView().controlSize(.mini).frame(width: 14).help("タイトルを生成中")
                    } else {
                        Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(session.title).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.leading, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(session.title)
            Menu {
                Button("タイトルを変更") { title = session.title; renaming = true }
                Button(session.isArchived == true ? "一覧に戻す" : "アーカイブ") {
                    app.setSessionArchived(session.id, archived: session.isArchived != true)
                }
                Divider()
                Button("削除", role: .destructive) { confirmingDeletion = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 30).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 4)
                .help("セッションの操作").accessibilityLabel("\(session.title)の操作")
        }
        .background(Color.primary.opacity(hovered ? 0.10 : (app.selection == session.id ? 0.065 : 0)), in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .disabled(app.locked)
        .alert("タイトルを変更", isPresented: $renaming) {
            TextField("タイトル", text: $title)
            Button("キャンセル", role: .cancel) { }
            Button("保存") { app.renameSession(session.id, title: title) }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("「\(session.title)」を削除しますか？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("削除", role: .destructive) { app.deleteSession(session.id) }
            Button("キャンセル", role: .cancel) { }
        } message: { Text("このアプリの履歴から削除します。") }
    }
}

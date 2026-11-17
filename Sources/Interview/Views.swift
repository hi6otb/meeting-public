import SwiftUI
import AppKit
import PDFKit
import WebKit
import AVFoundation

struct IconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

struct ContentView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var codex: CodexClient
    @AppStorage("dark") private var dark = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var search = ""
    @State private var searchVisible = false
    @State private var archivesExpanded = false
    @StateObject private var browser = BrowserModel()
    private var surface: Color { dark ? Color(white: 0.085) : .white }
    private var sidebarSurface: Color { dark ? Color(white: 0.11) : Color(white: 0.97) }

    init(app: AppModel) { self.app = app; self.codex = app.codex }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if sidebarVisible { sidebar.frame(minWidth: 190, idealWidth: 250, maxWidth: 340) }
                VSplitView {
                    referencePane.frame(minHeight: 180, idealHeight: 400)
                    conversationPane.frame(minHeight: 220, idealHeight: 330)
                }.frame(minWidth: 430, maxWidth: .infinity)
                coachPane.frame(minWidth: 270, idealWidth: 340, maxWidth: 520)
            }
            if let error = app.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(symbol: "xmark", help: "閉じる") { app.error = nil }
                }.padding(.horizontal, 16).padding(.vertical, 8).background(sidebarSurface)
            }
        }
        .background(surface).font(.system(size: 13)).preferredColorScheme(dark ? .dark : .light)
        .focusEffectDisabled()
        .overlay {
            if app.showSettings {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { app.showSettings = false }
                    SettingsView(app: app, codex: codex) { app.showSettings = false }
                        .background {
                            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                                .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture { }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await app.connect() }
        .onChange(of: app.selection) { _, _ in browser.clear() }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            Button { app.newSession() } label: {
                HStack(spacing: 10) {
                    Text("新しいセッション").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 13)).frame(width: 30, height: 28)
                }.padding(.leading, 20).padding(.trailing, 12).frame(height: 38).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(app.locked)
            HStack { Text("一覧").font(.system(size: 11)).foregroundStyle(.secondary); Spacer()
                IconButton(symbol: "magnifyingglass", help: "セッションを検索") { searchVisible.toggle() }
            }.padding(.leading, 20).padding(.trailing, 12).padding(.top, 8)
            if searchVisible { TextField("検索", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 8) }
            ScrollView {
                LazyVStack(spacing: 2) {
                    let matches = app.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } }
                    ForEach(matches.filter { $0.isArchived != true }) { session in
                        SessionSidebarRow(app: app, session: session)
                    }
                    let archived = matches.filter { $0.isArchived == true }
                    if !archived.isEmpty {
                        DisclosureGroup(isExpanded: $archivesExpanded) {
                            ForEach(archived) { session in SessionSidebarRow(app: app, session: session) }
                        } label: {
                            Text("アーカイブ").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 12).padding(.horizontal, 4)
                    }
                }.padding(.horizontal, 8)
            }
            HStack(spacing: 6) {
                Circle().fill(codex.connected ? Color.green.opacity(0.7) : .gray).frame(width: 5, height: 5)
                Text(codex.accountLabel).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary).help(codex.accountLabel)
                Spacer(minLength: 2)
                IconButton(symbol: dark ? "sun.max" : "moon", help: "外観を切り替え") { dark.toggle() }
                IconButton(symbol: "gearshape", help: "設定") { app.showSettings = true }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.background(sidebarSurface)
    }
    private var referencePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("メモ", value: "notes")
                tab("ブラウザ", value: "browser")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(app.session?.openReferences ?? []) { reference in referenceTabButton(reference) }
                    }
                }
                IconButton(symbol: "plus", help: "ファイルを追加") { app.importReferences() }
            }.padding(.horizontal, 12).frame(height: 38)
            Divider().opacity(0.45)
            if app.referenceTab == "notes" {
                ZStack(alignment: .topLeading) {
                    if app.session?.notes.isEmpty != false {
                        Text("メモを記載…").foregroundStyle(.tertiary).padding(.leading, 20).padding(.top, 19).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { app.session?.notes ?? "" }, set: { app.editNotes($0) }))
                        .font(.system(size: 14)).scrollContentBackground(.hidden).padding(14).accessibilityLabel("メモ")
                }
            } else if app.referenceTab == "browser" {
                BrowserPane(browser: browser, initialURL: app.session?.browserURL ?? "", onNavigate: { url in app.updateSession { $0.browserURL = url } })
            } else if let reference = app.session?.openReferences.first(where: { $0.id.uuidString == app.referenceTab }) {
                ReferencePane(reference: reference)
            } else { Spacer() }
        }.background(surface)
    }
    private func tab(_ title: String, value: String) -> some View {
        Button { app.referenceTab = value } label: {
            Text(title).font(.system(size: 12)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(app.referenceTab == value ? .primary : .secondary)
                .background(app.referenceTab == value ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
    private func referenceTabButton(_ reference: Reference) -> some View {
        HStack(spacing: 2) {
            Button { app.referenceTab = reference.id.uuidString } label: {
                HStack(spacing: 5) {
                    Text(reference.name).lineLimit(1).frame(maxWidth: 180)
                }.font(.system(size: 12)).padding(.leading, 10).padding(.vertical, 5)
            }.buttonStyle(.plain).help(reference.name)
            Button {
                app.closeReference(reference.id)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.hierarchical)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("\(reference.name)を閉じる").accessibilityLabel("\(reference.name)を閉じる")
        }.foregroundStyle(app.referenceTab == reference.id.uuidString ? .primary : .secondary)
            .background(app.referenceTab == reference.id.uuidString ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
    private var conversationPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if (app.session?.messages.filter(\.isConversation).isEmpty ?? true) && app.drafts.values.allSatisfy(\.isEmpty) {
                            Text("記録を始めると、ここに会話が表示されます。")
                                .foregroundStyle(.tertiary).font(.system(size: 13)).padding(.vertical, 32).frame(maxWidth: .infinity)
                        }
                        ForEach(app.session?.messages.filter(\.isConversation) ?? []) { message in
                            ConversationBubble(message: message, provisional: message.isProvisional == true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 22).padding(.vertical, 24)
                }
                .onChange(of: app.session?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: app.drafts) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }.background(surface)
    }
    private var coachPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Codex")
                Spacer()
                if app.applyingTemplate { ProgressView().controlSize(.mini) }
                Menu {
                    ForEach(app.templateLibrary.templates) { template in
                        Button { app.selectTemplate(template.id) } label: {
                            if app.selectedTemplate.id == template.id { Label(template.name, systemImage: "checkmark") }
                            else { Text(template.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.selectedTemplate.name).lineLimit(1).frame(maxWidth: 110)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(app.preparing).help("会話テンプレート").accessibilityLabel("テンプレートを選択")
                Button { app.autoCoach.toggle() } label: {
                    Image(systemName: app.autoCoach ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 13)).foregroundStyle(app.autoCoach ? Color.orange : Color.secondary)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(app.autoCoach ? "自動対応オン — クリックでオフ" : "自動対応オフ — クリックでオン")
                    .accessibilityLabel(app.autoCoach ? "自動対応をオフにする" : "自動対応をオンにする")
                    .accessibilityValue(app.autoCoach ? "オン" : "オフ")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 18).frame(height: 38)
            Divider().opacity(0.45)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        let messages = app.session?.messages.filter(\.isCoachChat) ?? []
                        if messages.isEmpty && !app.busy {
                            Text("会話についてCodexに質問できます。")
                                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(.tertiary).padding(.vertical, 24)
                        }
                        ForEach(messages) { message in
                            if message.speaker == .codex || message.speaker == .system { MessageRow(message: message) }
                            else { ConversationBubble(message: message, showIdentity: true) }
                        }
                        if app.busy {
                            if !app.assistantDraft.isEmpty { MessageRow(message: Message(speaker: .codex, text: app.assistantDraft), animateInitial: true) }
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.mini)
                                Text(app.compacting ? "圧縮しています…" : "考えています…").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                IconButton(symbol: "stop.fill", help: "Codexを停止") { app.stopAdvice() }
                            }
                        }
                        Color.clear.frame(height: 1).id("coachBottom")
                    }.padding(22)
                }
                .onChange(of: app.assistantDraft) { _, _ in proxy.scrollTo("coachBottom", anchor: .bottom) }
                .onChange(of: app.session?.messages.count) { _, _ in proxy.scrollTo("coachBottom", anchor: .bottom) }
            }
            QuickPhraseBar(app: app)
            VStack(alignment: .leading, spacing: 5) {
                SubmitTextEditor(text: $app.draft, compact: true, accessibilityLabel: "Codexへのメッセージ", placeholder: "Codexに質問…") { app.sendDraft() }
                HStack(spacing: 6) {
                    ComposerControls(app: app, codex: codex)
                    Spacer(minLength: 0)
                    Button { app.sendDraft() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                            .foregroundStyle(surface).background(Color.primary, in: Circle())
                    }.buttonStyle(.plain).help("Codexへ送信").accessibilityLabel("Codexへ送信")
                        .disabled(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.busy || app.applyingTemplate)
                }
            }.padding(10).background(dark ? Color(white: 0.16) : Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.bottom, 16).zIndex(1)
        }.background(surface)
    }
}

private enum ChatPalette {
    static func fill(for speaker: Speaker) -> Color {
        switch speaker {
        case .me: Color(red: 0.03, green: 0.40, blue: 1.0)
        case .partner: Color.primary.opacity(0.085)
        case .codex: Color(red: 1.0, green: 0.63, blue: 0.24)
        case .system: Color(red: 0.30, green: 0.75, blue: 0.43)
        }
    }
    static func text(for speaker: Speaker) -> Color {
        switch speaker {
        case .me: .white
        case .partner: .primary
        case .codex, .system: Color(white: 0.12)
        }
    }
}

struct ConversationBubble: View {
    let message: Message
    var provisional = false
    var showIdentity = false
    private var isMe: Bool { message.speaker == .me }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: isMe ? 16 : 4,
                               bottomTrailingRadius: isMe ? 4 : 16, topTrailingRadius: 16)
    }
    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 7) {
            if showIdentity {
                HStack(spacing: 8) {
                    Text(message.speaker.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            }
        HStack(alignment: .bottom, spacing: 7) {
            if isMe { Spacer(minLength: 64); if !showIdentity { timestamp } }
            BlurRevealText(text: message.text, animateInitial: provisional || Date().timeIntervalSince(message.date) < 3)
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(ChatPalette.text(for: message.speaker).opacity(provisional ? 0.7 : 1))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(ChatPalette.fill(for: message.speaker), in: shape)
                .accessibilityLabel("\(message.speaker.label): \(message.text)")
            if !isMe { if !showIdentity { timestamp }; Spacer(minLength: 64) }
        }.frame(maxWidth: .infinity)
        }
    }
    private var timestamp: some View {
        Text(provisional ? "…" : message.date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize().padding(.bottom, 3)
    }
}

struct MessageRow: View {
    let message: Message
    var provisional = false
    var animateInitial = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(message.speaker.label).font(.system(size: 11, weight: .medium))
                Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                if provisional { Text("…").foregroundStyle(.tertiary) }
            }.foregroundStyle(.secondary)
            BlurRevealText(text: message.text, animateInitial: animateInitial || provisional || (message.speaker == .system && Date().timeIntervalSince(message.date) < 3)).font(.system(size: 14)).lineSpacing(5)
                .foregroundStyle(ChatPalette.text(for: message.speaker).opacity(provisional ? 0.7 : 1))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(ChatPalette.fill(for: message.speaker), in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReferencePane: View {
    let reference: Reference
    var body: some View {
        let url = URL(fileURLWithPath: reference.path)
        if url.pathExtension.lowercased() == "pdf" { PDFPane(url: url) }
        else if let image = NSImage(contentsOf: url) {
            GeometryReader { size in ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(width: size.size.width, height: size.size.height).padding(8) } }
        } else { ScrollView { Text(reference.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) } }
    }
}
struct PDFPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view = WKWebView(frame: .zero)
    @Published var address = ""
    @Published var loading = false
    @Published var error: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    override init() { super.init(); view.navigationDelegate = self; view.uiDelegate = self; view.allowsBackForwardNavigationGestures = true }
    func load(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let candidate = clean.contains("://") ? clean : "https://" + clean
        guard let url = URL(string: candidate), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { error = "WebページのURLを入力してください。"; return }
        error = nil; view.load(URLRequest(url: url)); address = url.absoluteString
    }
    func clear() { view.stopLoading(); view.loadHTMLString("", baseURL: nil); address = ""; error = nil }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        if let url = webView.url, ["http", "https"].contains(url.scheme ?? "") { address = url.absoluteString }
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false; self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false; self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["https", "http", "about"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { webView.load(action.request) }
        return nil
    }
}
struct WebPane: NSViewRepresentable {
    let browser: BrowserModel
    func makeNSView(context: Context) -> WKWebView { browser.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
struct BrowserPane: View {
    @ObservedObject var browser: BrowserModel
    let initialURL: String
    var onNavigate: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconButton(symbol: "chevron.left", help: "戻る") { browser.view.goBack() }.disabled(!browser.canGoBack)
                IconButton(symbol: "chevron.right", help: "進む") { browser.view.goForward() }.disabled(!browser.canGoForward)
                TextField("URLを入力", text: $browser.address).textFieldStyle(.plain).onSubmit { browser.load(browser.address); onNavigate(browser.address) }
                IconButton(symbol: "arrow.clockwise", help: "再読み込み") { browser.view.reload() }
                IconButton(symbol: "arrow.up.right.square", help: "標準ブラウザで開く") { if let url = browser.view.url { NSWorkspace.shared.open(url) } }
            }.padding(.horizontal, 10).frame(height: 34)
            if browser.loading { ProgressView().progressViewStyle(.linear).frame(height: 2) }
            if let error = browser.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(8) }
            WebPane(browser: browser)
        }.onAppear { if browser.address.isEmpty && !initialURL.isEmpty { browser.load(initialURL) } }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var codex: CodexClient
    var onClose: () -> Void
    @State private var path = UserDefaults.standard.string(forKey: "codexPath") ?? ""
    @State private var draftPath = ""
    private var selectedTab: Int { app.settingsTab }
    @State private var showCLIEditor = false
    @State private var connecting = false
    @State private var connectionError: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                settingsTab("一般", symbol: "slider.horizontal.3", id: 0)
                settingsTab("テンプレート", symbol: "text.alignleft", id: 1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.top, 40).padding(.bottom, 12)
                .frame(width: 132).background(Color.primary.opacity(0.025))
            Divider().opacity(0.5)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    IconButton(symbol: "xmark", help: "閉じる") { onClose() }
                }.padding(.trailing, 8).frame(height: 32)
                if selectedTab == 0 { generalSettings }
                else { TemplateSettingsView(app: app) }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }.font(.system(size: 12)).controlSize(.small).frame(width: 720)
            .fixedSize(horizontal: false, vertical: true)
            .focusEffectDisabled()
            .onExitCommand { onClose() }
            .task { if codex.connected { try? await codex.refreshLimits() } }
    }
    private func settingsTab(_ title: String, symbol: String, id: Int) -> some View {
        Button { app.settingsTab = id } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).fontWeight(selectedTab == id ? .medium : .regular)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(height: 31).contentShape(Rectangle())
                .foregroundStyle(selectedTab == id ? .primary : .secondary)
                .background(selectedTab == id ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).focusEffectDisabled()
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 18) {
            Text(title).frame(width: 114, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }.frame(minHeight: 29)
    }
    private var generalSettings: some View {
        VStack(spacing: 7) {
            row("マイク") {
                Picker("マイク", selection: $app.microphoneID) {
                    Text("システムの既定入力").tag("")
                    ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                }.labelsHidden().fixedSize().disabled(app.recording || app.preparing)
            }
            row("相手の音声") {
                Picker("相手の音声", selection: $app.applicationID) {
                    Text("PC全体の出力").tag("")
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }, id: \.processIdentifier) { item in Text(item.localizedName ?? "アプリ").tag(item.bundleIdentifier ?? "") }
                }.labelsHidden().fixedSize().disabled(app.recording || app.preparing)
            }
            row("文字起こし") {
                Picker("文字起こし", selection: $app.locale) {
                    Text("日本語").tag("ja-JP"); Text("English").tag("en-US")
                }.labelsHidden().fixedSize().disabled(app.recording || app.preparing)
            }
            row("発話の区切り") {
                HStack(spacing: 8) {
                    Slider(value: $app.pauseSeconds, in: 0.6...2.0, step: 0.1).frame(width: 180)
                    Text(String(format: "%.1f 秒", app.pauseSeconds)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Divider().opacity(0.45).padding(.vertical, 5)
            row("Codex CLIのパス") {
                Text(path.isEmpty ? "自動検出" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).help(path.isEmpty ? "自動検出" : path)
                Button("設定") {
                    draftPath = path; connectionError = nil; showCLIEditor = true
                }.disabled(app.busy || app.applyingTemplate)
                    .popover(isPresented: $showCLIEditor, arrowEdge: .top) { cliEditor }
            }
            row("権限設定") {
                Button("設定") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Divider().opacity(0.45).padding(.vertical, 5)
            row("アカウント") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(codex.accountLabel).lineLimit(1).textSelection(.enabled)
                    if !codex.rateDetails.isEmpty {
                        Text(codex.rateDetails).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 18)
    }
    private var cliEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("自動検出", text: $draftPath).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Codex CLIのパス")
                Button("選択") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { draftPath = url.path }
                }
            }
            if let connectionError { Text(connectionError).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("自動検出") { draftPath = "" }
                Spacer()
                if connecting { ProgressView().controlSize(.mini) }
                Button("接続") {
                    connecting = true; connectionError = nil
                    path = draftPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(path, forKey: "codexPath")
                    codex.shutdown()
                    Task {
                        await app.connect()
                        connecting = false
                        if codex.connected { showCLIEditor = false }
                        else { connectionError = app.error ?? "接続できませんでした。" }
                    }
                }.disabled(connecting)
            }
        }.padding(12).frame(width: 380)
    }
}

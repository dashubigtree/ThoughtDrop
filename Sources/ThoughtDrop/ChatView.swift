import SwiftUI
import ThoughtCore

// Use the property wrapper explicitly: CLT SDKs may omit SwiftUI's newer macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.showingChat {
                ChatView(model: model)
            } else {
                CaptureView(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.showingChat)
    }
}

struct ChatView: View {
    @ObservedObject var model: AppModel
    @ViewState private var input = ""
    private let ink = Color(red: 0.18, green: 0.24, blue: 0.23)
    private let green = Color(red: 0.24, green: 0.48, blue: 0.38)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: model.dismissChat) {
                    Label("返回", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("返回錄音")
                .accessibilityLabel("返回錄音")
                Text("與知識庫對話").font(.system(size: 15, weight: .medium, design: .serif))
                Spacer()
                Button("新對話") { model.newChat() }.disabled(model.asking || model.chat.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.chat.isEmpty {
                            Text("問問你過去說過的想法。回答只會根據 wiki 裡找得到的內容；找不到就會直接告訴你，不會憑空補充。")
                                .font(.callout).foregroundStyle(ink.opacity(0.6))
                        }
                        ForEach(model.chat) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.question).textSelection(.enabled).padding(10)
                                    .background(green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                if let answer = turn.answer {
                                    Text(answer.text).textSelection(.enabled)
                                    if !answer.sources.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("來源（點開在 Obsidian 核對）").font(.caption2).foregroundStyle(ink.opacity(0.5))
                                            ForEach(answer.sources, id: \.id) { source in
                                                Button("\(source.id) · \(source.title)") { model.openSource(source) }
                                                    .buttonStyle(.link).font(.caption)
                                            }
                                        }
                                    } else {
                                        Text("未引用任何來源").font(.caption2).foregroundStyle(ink.opacity(0.5))
                                    }
                                } else if let error = turn.error {
                                    Text(error).font(.callout).foregroundStyle(Color(red: 0.62, green: 0.29, blue: 0.2)).textSelection(.enabled)
                                }
                            }
                        }
                        if model.asking { ProgressView("檢索並思考中…").controlSize(.small) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                .onChange(of: model.asking) { _, _ in withAnimation { proxy.scrollTo("end") } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("問問你的知識庫…", text: $input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("送出", action: send).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.asking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 20).padding(.top, 12)
            Text("只檢索 wiki；片段送至 \(model.provider.title) 回答。對話存於 ThoughtDrop/chats/。")
                .font(.caption2).foregroundStyle(ink.opacity(0.5)).padding(.horizontal, 20).padding(.vertical, 8)
        }
        .frame(width: 440, height: 540)
        .foregroundStyle(ink)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .preferredColorScheme(.light)
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !model.asking else { return }
        input = ""
        model.ask(question)
    }
}

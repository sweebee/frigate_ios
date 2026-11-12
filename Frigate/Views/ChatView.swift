import SwiftUI

/// One conversation with Frigate's GenAI chat on a server. Frigate returns the whole
/// conversation (with its system prompt and tool calls) after each answer; it is sent back
/// as is on the next question so the model keeps its context.
@Observable @MainActor
final class ChatSession {
    struct Line: Identifiable {
        enum Kind { case user, assistant, tools }
        let id: Int
        let kind: Kind
        let text: String
    }

    private(set) var chain: [[String: Any]] = []
    /// Answer text arriving while Frigate streams.
    private(set) var streaming = ""
    private(set) var busy = false
    private(set) var error: String?
    private var task: Task<Void, Never>?

    var isEmpty: Bool { lines.isEmpty && !busy }

    /// What to show: questions, answers and which tools the model used.
    var lines: [Line] {
        var out: [Line] = []
        for (i, msg) in chain.enumerated() {
            let role = msg["role"] as? String
            let content = msg["content"] as? String ?? ""
            switch role {
            case "user":
                // Frigate adds camera frames for the model as user messages without text; skip those.
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(Line(id: i, kind: .user, text: content))
                }
            case "assistant":
                if let calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    let names = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                    // "Get live context ×7" instead of the same name seven times.
                    var order: [String] = []
                    var counts: [String: Int] = [:]
                    for n in names { if counts[n] == nil { order.append(n) }; counts[n, default: 0] += 1 }
                    let text = order.map { n in counts[n]! > 1 ? "\(Self.toolName(n)) ×\(counts[n]!)" : Self.toolName(n) }
                    out.append(Line(id: i, kind: .tools, text: text.joined(separator: ", ")))
                }
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(Line(id: i * 1000 + 1, kind: .assistant, text: content))
                }
            default: break
            }
        }
        return out
    }

    static func toolName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    func send(_ text: String, client: FrigateClient) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        chain.append(["role": "user", "content": question])
        let messages = chain
        busy = true
        error = nil
        streaming = ""
        task = Task {
            do {
                for try await event in client.chat(messages: messages) {
                    switch event["type"] as? String {
                    case "content":
                        streaming += event["delta"] as? String ?? ""
                    case "messages":
                        if let list = event["messages"] as? [[String: Any]] {
                            chain = list
                            streaming = ""
                        }
                    case "error":
                        error = event["error"] as? String ?? L("Something went wrong")
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            // Keep an answer that streamed but never came back in the conversation.
            if !streaming.isEmpty {
                chain.append(["role": "assistant", "content": streaming])
                streaming = ""
            }
            busy = false
        }
    }

    func stop() {
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        chain = []
        streaming = ""
        error = nil
        busy = false
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var connections: [ServerConnection] { model.chatConnections }
    /// The server picked in the chat, else the first server that has chat.
    private var conn: ServerConnection? {
        connections.first { $0.server.id == model.chatServerID } ?? connections.first
    }
    private var session: ChatSession? { conn.map { model.chatSession(for: $0.server.id) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if let session, let conn {
                    if session.isEmpty {
                        intro(session: session, conn: conn)
                    } else {
                        conversation(session)
                    }
                    inputBar(session: session, conn: conn)
                } else {
                    Spacer()
                    EmptyStateView(systemImage: "bubble.left.and.text.bubble.right", title: L("Chat is not available"),
                                   message: L("Configure a GenAI provider with the chat role in Frigate to ask questions about your cameras."))
                    Spacer()
                }
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LargeTitle(text: L("Chat"))
                Spacer()
                if let session, !session.isEmpty {
                    Button { session.reset() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("New chat")
                }
            }
            // Frigate's chat answers for one server; with several, pick or show which one.
            if let conn, connections.count > 1 {
                Menu {
                    ForEach(connections) { c in
                        Button { model.chatServerID = c.server.id } label: {
                            if c.server.id == conn.server.id { Label(c.server.name, systemImage: "checkmark") } else { Text(c.server.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Ask")
                            .foregroundStyle(Theme.textSecondary)
                        ServerBadge(initial: conn.server.initial, tint: conn.server.tint, size: 18)
                        Text(conn.server.name).foregroundStyle(Theme.text)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .padding(.top, -8)
            } else if model.orderedConnections.count > 1, let conn {
                Text(L("Asking \(conn.server.name), the server with chat."))
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .padding(.top, -8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func intro(session: ChatSession, conn: ServerConnection) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    .padding(.top, 60)
                Text("Ask about your cameras").font(.system(size: 20, weight: .semibold))
                Text("Frigate's AI assistant looks at your events, cameras and recordings to answer.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                VStack(spacing: 8) {
                    ForEach([L("Show recent events"), L("Show camera status"), L("What happened while I was away?")], id: \.self) { q in
                        Button { send(q, session: session, conn: conn) } label: {
                            Text(q).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 16).frame(height: 40)
                                .card(radius: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func conversation(_ session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.lines) { line in
                        ChatLineView(line: line)
                    }
                    if session.busy {
                        if session.streaming.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Thinking…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.leading, 4)
                        } else {
                            ChatLineView(line: .init(id: -1, kind: .assistant, text: session.streaming))
                        }
                    }
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14)).foregroundStyle(Theme.recording)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.lines.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.busy) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func inputBar(session: ChatSession, conn: ServerConnection) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input, session: session, conn: conn) }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.controlBorder, lineWidth: 1))
            Button {
                if session.busy { session.stop() } else { send(input, session: session, conn: conn) }
            } label: {
                Image(systemName: session.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onColor)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(!session.busy && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(session.busy ? "Stop" : "Send")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func send(_ text: String, session: ChatSession, conn: ServerConnection) {
        guard let client = conn.client else { return }
        session.send(text, client: client)
        input = ""
    }
}

struct ChatLineView: View {
    let line: ChatSession.Line

    var body: some View {
        switch line.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(line.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.onColor)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                Text(Self.markdown(line.text))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cardBorder, lineWidth: 1))
                    .textSelection(.enabled)
                Spacer(minLength: 32)
            }
        case .tools:
            Label(L("Used \(line.text)"), systemImage: "wrench.and.screwdriver")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
        }
    }

    /// Markdown from the model, with lists and headings turned into plain lines.
    static func markdown(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { raw -> String in
            var l = raw
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(repeating: "  ", count: (l.count - l.drop(while: { $0 == " " }).count) / 2)
                l = indent + "• " + trimmed.dropFirst(2)
            } else if trimmed.hasPrefix("#") {
                l = "**" + trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**"
            }
            return l
        }
        let joined = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(joined)
    }
}

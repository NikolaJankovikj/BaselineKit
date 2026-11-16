import Insights
import SwiftUI

/// The weekly report and the way into Ask.
struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                WeeklyReportCard(report: model.weeklyReport)
                NavigationLink {
                    AskView(session: AskSession(snapshot: model.snapshot))
                } label: {
                    Card {
                        HStack {
                            CardTitle(title: "Ask about your data", symbol: "bubble.left.and.text.bubble.right.fill", tint: .brand)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        Text("“Why was Tuesday flagged?” “How has my sleep been this month?” Answers come from your own data, on this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Card {
                    CardTitle(title: "How this works", symbol: "info.circle.fill", tint: .brand)
                    Text("A forecasting model on this device learns your usual ranges and flags what falls outside them. Every number and flag comes from that model and from fixed rules.")
                    Text("Apple Intelligence, when your device has it, puts the flags into words and suggests what to do. It never calculates, and it does not diagnose. Without it you get the same facts and suggestions, written from templates.")
                    Text("Nothing leaves your device.")
                        .fontWeight(.medium)
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.page)
        .navigationTitle("Insights")
    }
}

private struct WeeklyReportCard: View {
    var report: Sourced<WeeklyReport>?

    var body: some View {
        Card {
            CardTitle(title: "This week", symbol: "calendar", tint: .brand)
            if let report {
                Text(report.content.headline).font(.title3.bold())
                ForEach(report.content.highlights, id: \.self) { highlight in
                    Label(highlight, systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                ForEach(report.content.concerns, id: \.self) { concern in
                    Label(concern, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Divider()
                Label(report.content.focusForNextWeek, systemImage: "scope")
                    .foregroundStyle(.secondary)
                InsightSourceLabel(source: report.source)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Putting your week together…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
    }
}

/// A chat restricted to the user's own data. Without Apple Intelligence it still answers,
/// with the summaries the question is about.
struct AskView: View {
    @State var session: AskSession
    @State private var draft = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !session.usesLanguageModel {
                        Label("Apple Intelligence is not available on this device, so answers are the parts of your data your question is about.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if session.messages.isEmpty {
                        QuickQuestions { question in
                            Task { await session.ask(question.rawValue) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.last?.text) {
                withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
            }
        }
        .background(Color.page)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about your data", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isTyping)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.card, in: .rect(cornerRadius: 20))
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.isResponding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !session.isResponding else { return }
        draft = ""
        Task { await session.ask(question) }
    }
}

private struct MessageBubble: View {
    var message: AskSession.Message

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(message.text)
                }
                if let facts = message.facts {
                    DisclosureGroup("From your data") {
                        Text(facts).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Color.brand : Color.card, in: .rect(cornerRadius: 18))
            .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

private struct QuickQuestions: View {
    var ask: (QuickQuestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(QuickQuestion.allCases) { question in
                Button(question.rawValue) { ask(question) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.brand)
            }
        }
    }
}

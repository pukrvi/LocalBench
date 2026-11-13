import SwiftUI
import LocalBenchCore

/// Cross-tab navigation: chat and benchmark views can send a request straight
/// to the Traces browser.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case individual
        case chat
        case benchmarks
        case traces
        case review

        var id: String { rawValue }

        var label: String {
            switch self {
            case .individual: return "Chat"
            case .chat: return "Compare"
            case .benchmarks: return "Benchmarks"
            case .traces: return "Traces"
            case .review: return "Review"
            }
        }

        var systemImage: String {
            switch self {
            case .individual: return "bubble.left"
            case .chat: return "bubble.left.and.text.bubble.right"
            case .benchmarks: return "gauge.with.needle"
            case .traces: return "list.bullet.rectangle"
            case .review: return "checkmark.seal"
            }
        }
    }

    @Published var selectedTab: Tab = .individual
    @Published var focusedRequestID: String?

    // Trace → Conversation reverse navigation payload.
    @Published var focusedConversationID: String?
    @Published var focusedTurnID: String?
    @Published var focusedBackend: BackendID?

    func openTraces(requestID: String) {
        focusedRequestID = requestID
        selectedTab = .traces
    }

    func openConversation(conversationID: String, turnID: String?, backend: BackendID?) {
        focusedConversationID = conversationID
        focusedTurnID = turnID
        focusedBackend = backend
        selectedTab = .chat
    }
}

@main
struct LocalBenchApp: App {
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup("LocalBench") {
            TabView(selection: $router.selectedTab) {
                IndividualChatScreen()
                    .tabItem { Label(AppRouter.Tab.individual.label, systemImage: AppRouter.Tab.individual.systemImage) }
                    .tag(AppRouter.Tab.individual)
                ChatScreen()
                    .tabItem { Label(AppRouter.Tab.chat.label, systemImage: AppRouter.Tab.chat.systemImage) }
                    .tag(AppRouter.Tab.chat)
                DashboardScreen()
                    .tabItem { Label(AppRouter.Tab.benchmarks.label, systemImage: AppRouter.Tab.benchmarks.systemImage) }
                    .tag(AppRouter.Tab.benchmarks)
                TraceScreen()
                    .tabItem { Label(AppRouter.Tab.traces.label, systemImage: AppRouter.Tab.traces.systemImage) }
                    .tag(AppRouter.Tab.traces)
                ReviewScreen()
                    .tabItem { Label(AppRouter.Tab.review.label, systemImage: AppRouter.Tab.review.systemImage) }
                    .tag(AppRouter.Tab.review)
            }
            .environmentObject(router)
            .frame(minWidth: 1180, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
    }
}

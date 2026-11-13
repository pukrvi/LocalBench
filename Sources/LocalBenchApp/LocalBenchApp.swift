import SwiftUI
import LocalBenchCore

/// Cross-tab navigation: chat and benchmark views can send a request straight
/// to the Traces browser.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case chat
        case benchmarks
        case traces

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chat: return "Compare Chat"
            case .benchmarks: return "Benchmarks"
            case .traces: return "Traces"
            }
        }

        var systemImage: String {
            switch self {
            case .chat: return "bubble.left.and.text.bubble.right"
            case .benchmarks: return "gauge.with.needle"
            case .traces: return "list.bullet.rectangle"
            }
        }
    }

    @Published var selectedTab: Tab = .chat
    @Published var focusedRequestID: String?

    func openTraces(requestID: String) {
        focusedRequestID = requestID
        selectedTab = .traces
    }
}

@main
struct LocalBenchApp: App {
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup("LocalBench") {
            TabView(selection: $router.selectedTab) {
                ChatScreen()
                    .tabItem { Label(AppRouter.Tab.chat.label, systemImage: AppRouter.Tab.chat.systemImage) }
                    .tag(AppRouter.Tab.chat)
                DashboardScreen()
                    .tabItem { Label(AppRouter.Tab.benchmarks.label, systemImage: AppRouter.Tab.benchmarks.systemImage) }
                    .tag(AppRouter.Tab.benchmarks)
                TraceScreen()
                    .tabItem { Label(AppRouter.Tab.traces.label, systemImage: AppRouter.Tab.traces.systemImage) }
                    .tag(AppRouter.Tab.traces)
            }
            .environmentObject(router)
            .frame(minWidth: 1180, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
    }
}

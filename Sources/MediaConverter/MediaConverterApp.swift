import SwiftUI

@main
struct MediaConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        Window("Media Converter", id: "converter") {
            ContentView(model: model)
                .frame(minWidth: 560, idealWidth: 600, maxWidth: 760, minHeight: 480)
                .onAppear { delegate.model = model }
                .onDisappear { model.cancelAllWork() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 510)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasBackgroundWork else { return .terminateNow }
        model.cancelAllWork()
        Task {
            while model.hasBackgroundWork { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

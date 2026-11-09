import SwiftUI

@main
struct PrivateSubtitlesApp: App {
    @State private var pipeline = SubtitlePipeline()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
        }
    }
}

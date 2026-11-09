import SwiftUI

@main
struct PrivateSubtitlesApp: App {
    @State private var pipeline = SubtitlePipeline()
    @State private var pip = PiPSubtitleController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pipeline)
                .environment(pip)
                .task {
                    pipeline.onSubtitleChange = { [pip] english, chinese, isVolatile in
                        pip.update(english: english, chinese: chinese, isVolatile: isVolatile)
                    }
                }
        }
    }
}

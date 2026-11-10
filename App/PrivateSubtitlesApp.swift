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
                    pipeline.onSubtitleChange = { [pip] snap in
                        pip.update(snap)
                    }
                    pipeline.onStatusChange = { [pip] level, warning in
                        pip.updateStatus(level: level, warning: warning)
                    }
                }
        }
    }
}

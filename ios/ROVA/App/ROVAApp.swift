import SwiftUI

@main
struct ROVAApp: App {
    @StateObject private var settings = Settings.shared
    @StateObject private var engine = JourneyEngine()
    @StateObject private var location = LocationService()
    @State private var launched = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if launched {
                    RootView()
                        .environmentObject(settings)
                        .environmentObject(engine)
                        .environmentObject(location)
                        .environmentObject(engine.motion)
                        .transition(.opacity)
                }
                if !launched {
                    SplashView { withAnimation(.easeOut(duration: 0.45)) { launched = true } }
                        .transition(.opacity)
                }
            }
            // Ink, not blue. The only colour in ROVA carries meaning.
            .tint(.primary)
            .preferredColorScheme(nil)
        }
    }
}

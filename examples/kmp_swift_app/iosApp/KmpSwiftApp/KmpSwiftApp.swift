import SwiftUI
import Shared

@main
struct KmpSwiftApp: App {
    var body: some Scene {
        WindowGroup {
            Text(Greeting().text())
                .padding()
        }
    }
}

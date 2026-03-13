import SwiftUI

@main
struct LCEApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1280, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Metal4View()
                .ignoresSafeArea()

            CrosshairView()

            VStack(alignment: .leading, spacing: 6) {
                Text("WASD move  Shift sprint  Space jump")
                Text("Left click capture mouse  Right click release")
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
            .padding(12)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        }
    }
}

private struct CrosshairView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 18, height: 2)
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: 18)
        }
        .shadow(color: .black.opacity(0.6), radius: 1)
    }
}

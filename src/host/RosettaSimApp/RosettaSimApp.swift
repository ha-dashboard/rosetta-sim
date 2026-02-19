import SwiftUI
import AppKit

// MARK: - Device Configuration
struct DeviceConfig {
    let name: String
    let width: Int
    let height: Int
    let scale: CGFloat

    static let iPhone6s = DeviceConfig(
        name: "iPhone 6s",
        width: 375,
        height: 667,
        scale: 2.0
    )
}

// MARK: - Frame Loader
class FrameLoader: ObservableObject {
    @Published var currentFrame: NSImage?
    private let pngPath = "/tmp/rosettasim_text.png"
    private let rawPath = "/tmp/rosettasim_render.raw"

    func loadFrame() {
        // Try PNG first (already rendered)
        if let image = NSImage(contentsOfFile: pngPath) {
            DispatchQueue.main.async {
                self.currentFrame = image
            }
            return
        }

        // Try raw BGRA data (future implementation)
        loadRawBGRA()
    }

    private func loadRawBGRA() {
        // For now, just create a placeholder
        // In the future, this will read the raw BGRA bitmap
        let size = NSSize(width: 375, height: 667)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.darkGray.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Draw "No Frame" text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.white
        ]
        let text = "No Frame Available"
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()

        DispatchQueue.main.async {
            self.currentFrame = image
        }
    }
}

// MARK: - Device Chrome View
struct DeviceChromeView: View {
    let device: DeviceConfig
    @ObservedObject var frameLoader: FrameLoader

    var body: some View {
        ZStack {
            // Device bezel
            RoundedRectangle(cornerRadius: 40)
                .fill(Color(NSColor.darkGray))
                .shadow(radius: 20)

            // Screen area
            VStack(spacing: 0) {
                Spacer().frame(height: 60) // Top bezel

                if let frame = frameLoader.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: CGFloat(device.width),
                            height: CGFloat(device.height)
                        )
                        .background(Color.black)
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .frame(
                            width: CGFloat(device.width),
                            height: CGFloat(device.height)
                        )
                        .cornerRadius(8)
                        .overlay(
                            Text("Loading...")
                                .foregroundColor(.white)
                        )
                }

                Spacer().frame(height: 60) // Bottom bezel
            }
        }
        .frame(
            width: CGFloat(device.width) + 40,
            height: CGFloat(device.height) + 140
        )
    }
}

// MARK: - Main Content View
struct ContentView: View {
    let device = DeviceConfig.iPhone6s
    @StateObject private var frameLoader = FrameLoader()

    var body: some View {
        VStack {
            // Toolbar
            HStack {
                Button(action: launchSimulator) {
                    Label("Launch Sim", systemImage: "play.fill")
                }
                .disabled(true) // Will be implemented later

                Button(action: captureFrame) {
                    Label("Capture Frame", systemImage: "arrow.clockwise")
                }

                Spacer()

                Text("RosettaSim - \(device.name) (iOS 10.3)")
                    .font(.headline)

                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Device display
            DeviceChromeView(device: device, frameLoader: frameLoader)
                .padding()
        }
        .frame(minWidth: 500, minHeight: 800)
        .onAppear {
            frameLoader.loadFrame()
        }
    }

    private func launchSimulator() {
        // Placeholder for launching the simulated process
        print("Launch simulator - not implemented yet")
    }

    private func captureFrame() {
        frameLoader.loadFrame()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the window
        let contentView = ContentView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.center()
        window.title = "RosettaSim"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

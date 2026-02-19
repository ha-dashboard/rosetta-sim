import SwiftUI
import AppKit

// MARK: - Framebuffer Constants (must match rosettasim_framebuffer.h)
private let kFBMagic: UInt32     = 0x4D495352  // 'RSIM'
private let kFBHeaderSize        = 64
private let kFBFlagFrameReady: UInt32 = 0x01
private let kFBFlagAppRunning: UInt32 = 0x02
private let kFBDefaultPath       = "/tmp/rosettasim_framebuffer"

// MARK: - Device Configuration
struct DeviceConfig {
    let name: String
    let width: Int      // points
    let height: Int     // points
    let scale: CGFloat

    var pixelWidth: Int  { Int(CGFloat(width) * scale) }
    var pixelHeight: Int { Int(CGFloat(height) * scale) }

    static let iPhone6s = DeviceConfig(
        name: "iPhone 6s",
        width: 375,
        height: 667,
        scale: 2.0
    )
}

// MARK: - Simulator Process Manager
class SimulatorProcess: ObservableObject {
    @Published var isRunning = false
    @Published var logLines: [String] = []
    private var process: Process?
    private var stderrPipe: Pipe?

    /// Detect project root by walking up from the executable/working directory
    private var projectRoot: String {
        if let env = ProcessInfo.processInfo.environment["ROSETTASIM_PROJECT_ROOT"] {
            return env
        }
        // Walk up from cwd looking for scripts/run_sim.sh
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: dir + "/scripts/run_sim.sh") {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return FileManager.default.currentDirectoryPath
    }

    func launch(binary: String = "tests/phase5_continuous") {
        guard !isRunning else { return }

        let root = projectRoot
        let scriptPath = root + "/scripts/run_sim.sh"
        let binaryPath: String
        if binary.hasPrefix("/") {
            binaryPath = binary
        } else {
            binaryPath = root + "/" + binary
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logLines.append("ERROR: run_sim.sh not found at \(scriptPath)")
            return
        }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            logLines.append("ERROR: Binary not found at \(binaryPath)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath, binaryPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: root)

        // Capture stderr (bridge logs go there)
        let pipe = Pipe()
        proc.standardError = pipe
        stderrPipe = pipe

        // Read bridge logs asynchronously
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    self?.logLines.append(contentsOf: lines)
                    // Keep last 200 lines
                    if let count = self?.logLines.count, count > 200 {
                        self?.logLines.removeFirst(count - 200)
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.logLines.append("-- Process exited --")
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            logLines.append("Launched: \(binaryPath)")
        } catch {
            logLines.append("ERROR: \(error.localizedDescription)")
        }
    }

    func terminate() {
        process?.terminate()
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        isRunning = false
    }
}

// MARK: - Live Frame Loader (mmap-based)
class FrameLoader: ObservableObject {
    @Published var currentFrame: NSImage?
    @Published var fps: Double = 0
    @Published var frameCount: UInt64 = 0
    @Published var isConnected = false

    private var displayTimer: Timer?
    private var mmapPtr: UnsafeMutableRawPointer?
    private var mmapSize: Int = 0
    private var lastFrameCounter: UInt64 = 0

    // FPS tracking
    private var fpsFrameCount = 0
    private var fpsLastTime = Date()

    private let fbPath: String = {
        ProcessInfo.processInfo.environment["ROSETTASIM_FB_PATH"] ?? kFBDefaultPath
    }()

    /// Start polling the shared framebuffer for new frames
    func startLiveDisplay() {
        // Start a timer that tries to connect and poll
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.pollFrame()
        }
    }

    func stopLiveDisplay() {
        displayTimer?.invalidate()
        displayTimer = nil
        disconnect()
    }

    private func connect() -> Bool {
        guard mmapPtr == nil else { return true }
        guard FileManager.default.fileExists(atPath: fbPath) else { return false }

        let fd = open(fbPath, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > kFBHeaderSize else { return false }
        mmapSize = Int(st.st_size)

        let ptr = mmap(nil, mmapSize, PROT_READ, MAP_SHARED, fd, 0)
        guard ptr != MAP_FAILED else { return false }
        mmapPtr = ptr

        // Verify magic
        let magic = ptr!.load(as: UInt32.self)
        guard magic == kFBMagic else {
            munmap(ptr!, mmapSize)
            mmapPtr = nil
            return false
        }

        DispatchQueue.main.async { self.isConnected = true }
        return true
    }

    private func disconnect() {
        if let ptr = mmapPtr, mmapSize > 0 {
            munmap(ptr, mmapSize)
        }
        mmapPtr = nil
        mmapSize = 0
        isConnected = false
    }

    private func pollFrame() {
        // Try to connect if not yet connected
        if mmapPtr == nil {
            guard connect() else { return }
        }

        guard let ptr = mmapPtr else { return }

        // Read frame counter (offset 24 = 6*4 bytes into header)
        let counter = ptr.load(fromByteOffset: 24, as: UInt64.self)
        guard counter != lastFrameCounter else { return }
        lastFrameCounter = counter

        // Read dimensions
        let width  = Int(ptr.load(fromByteOffset: 8, as: UInt32.self))
        let height = Int(ptr.load(fromByteOffset: 12, as: UInt32.self))
        let stride = Int(ptr.load(fromByteOffset: 16, as: UInt32.self))

        guard width > 0, height > 0, stride > 0 else { return }

        // Pixel data starts at offset kFBHeaderSize
        let pixelPtr = ptr.advanced(by: kFBHeaderSize)
        let dataSize = height * stride

        // Copy pixel data to avoid issues with the mmap being updated mid-read
        let dataCopy = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16)
        memcpy(dataCopy, pixelPtr, dataSize)

        // Create CGImage from BGRA data
        // 0x2002 = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(dataInfo: nil,
                                            data: dataCopy,
                                            size: dataSize,
                                            releaseData: { _, data, _ in data.deallocate() })
        else {
            dataCopy.deallocate()
            return
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return }

        // Display at point size (pixel size / scale)
        let displaySize = NSSize(width: width / 2, height: height / 2)
        let image = NSImage(cgImage: cgImage, size: displaySize)

        DispatchQueue.main.async {
            self.currentFrame = image
            self.frameCount = counter
        }

        // FPS calculation
        fpsFrameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsLastTime)
        if elapsed >= 1.0 {
            let measuredFPS = Double(fpsFrameCount) / elapsed
            DispatchQueue.main.async { self.fps = measuredFPS }
            fpsFrameCount = 0
            fpsLastTime = now
        }
    }

    /// Load a single frame from a PNG file (legacy/fallback)
    func loadStaticFrame() {
        let pngPath = "/tmp/rosettasim_text.png"
        if let image = NSImage(contentsOfFile: pngPath) {
            DispatchQueue.main.async { self.currentFrame = image }
            return
        }
        // Placeholder
        let size = NSSize(width: 375, height: 667)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.3, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor.white
        ]
        let text = "Launch Simulator\nto start rendering"
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        DispatchQueue.main.async { self.currentFrame = image }
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
                Spacer().frame(height: 60)

                if let frame = frameLoader.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .interpolation(.high)
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
                            Text("No Frame")
                                .foregroundColor(.gray)
                        )
                }

                Spacer().frame(height: 60)
            }
        }
        .frame(
            width: CGFloat(device.width) + 40,
            height: CGFloat(device.height) + 140
        )
    }
}

// MARK: - Status Bar View
struct StatusBarView: View {
    @ObservedObject var frameLoader: FrameLoader
    @ObservedObject var simProcess: SimulatorProcess

    var body: some View {
        HStack(spacing: 12) {
            // Connection indicator
            Circle()
                .fill(frameLoader.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            if frameLoader.isConnected {
                Text(String(format: "%.0f FPS", frameLoader.fps))
                    .font(.system(.caption, design: .monospaced))
                Text("Frame \(frameLoader.frameCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if simProcess.isRunning {
                Text("Connecting...")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("Not running")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    let device = DeviceConfig.iPhone6s
    @StateObject private var frameLoader = FrameLoader()
    @StateObject private var simProcess = SimulatorProcess()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if simProcess.isRunning {
                    Button(action: stopSimulator) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .tint(.red)
                } else {
                    Button(action: launchSimulator) {
                        Label("Launch", systemImage: "play.fill")
                    }
                }

                Spacer()

                StatusBarView(frameLoader: frameLoader, simProcess: simProcess)

                Spacer()

                Text("RosettaSim - \(device.name)")
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Device display
            DeviceChromeView(device: device, frameLoader: frameLoader)
                .padding()
        }
        .frame(minWidth: 500, minHeight: 850)
        .onAppear {
            frameLoader.loadStaticFrame()
            frameLoader.startLiveDisplay()
        }
        .onDisappear {
            frameLoader.stopLiveDisplay()
            simProcess.terminate()
        }
    }

    private func launchSimulator() {
        simProcess.launch()
    }

    private func stopSimulator() {
        simProcess.terminate()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 950),
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

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up framebuffer mmap on exit
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()

#!/usr/bin/env swift
// Minimal raw framebuffer viewer — displays /tmp/sim_framebuffer.raw (750x1334 BGRA)
// Refreshes automatically when the file changes.

import AppKit

let W = 750, H = 1334
let rawPath = "/tmp/sim_framebuffer.raw"
let expectedSize = W * H * 4

class FBWindow: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var imageView: NSImageView!
    var timer: Timer?
    var lastModTime: TimeInterval = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W/2, height: H/2),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iOS 9.3 Framebuffer"
        window.center()

        imageView = NSImageView(frame: window.contentView!.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView!.addSubview(imageView)
        window.makeKeyAndOrderFront(nil)

        loadFrame()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.checkAndLoad()
        }
    }

    func checkAndLoad() {
        var st = stat()
        guard stat(rawPath, &st) == 0 else { return }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if mtime != lastModTime {
            lastModTime = mtime
            loadFrame()
        }
    }

    func loadFrame() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
              data.count >= expectedSize else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: data.prefix(expectedSize) as CFData),
              let cgImage = CGImage(
                  width: W, height: H,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                  space: colorSpace, bitmapInfo: bitmapInfo,
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        imageView.image = NSImage(cgImage: cgImage, size: NSSize(width: W/2, height: H/2))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let del = FBWindow()
app.delegate = del
app.run()

import AppKit
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
}

/// A real window-backed glass surface, sampling the desktop below the floating panel.
@MainActor func makeToolbarSurface<Content: View>(_ content: Content) -> NSView {
    let hosting = TransparentHostingView(rootView: content.environment(\.colorScheme, .light))
    hosting.appearance = NSAppearance(named: .aqua)
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    let container = NSView()
    // A bounded contrast floor keeps dark controls legible over arbitrary desktops.
    let readability = NSView()
    readability.wantsLayer = true
    readability.layer?.backgroundColor = NSColor(white: 1, alpha: 0.62).cgColor
    readability.layer?.cornerRadius = 27
    readability.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(readability)
    let surface: NSView
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.appearance = NSAppearance(named: .aqua)
        glass.cornerRadius = 27
        #if compiler(>=6.4)
        if #available(macOS 27, *) { glass.effectIsInteractive = true }
        #endif
        glass.contentView = hosting
        surface = glass
    } else {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 27
        material.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        surface = material
    }
    surface.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surface)
    NSLayoutConstraint.activate([
        readability.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
        readability.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
        readability.topAnchor.constraint(equalTo: surface.topAnchor),
        readability.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        surface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
        surface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        surface.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
    ])
    return container
}

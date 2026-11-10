import SwiftUI
import AppKit

/// The splash screen at launch and the About window, in the manner of Lightroom Classic:
/// the name on the left, Mohamed Malik's photograph on the right.
@Observable
final class Splash {
    static let shared = Splash()
    static let appName = "Loupe Photos"
    static let copyright = "© 2026 Mohamed Malik · MIT Licence"
    static let credits = [
        "A free, open-source photo library for the Mac.",
        "Built with SwiftUI, Core Image and Vision.",
        "Face recognition: AuraFace (Apache-2.0), run on this Mac — nothing is uploaded.",
    ]
    /// Settings ▸ Library ▸ Show the splash screen at launch.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "splash.show") as? Bool ?? true }

    var status = "Reading preferences…"
    var about = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var shownAt = Date()
    @ObservationIgnored private var launched = false        // the catalog is open: the launch splash isn't needed any more

    /// At launch, before the catalog opens. Safe to call more than once.
    func show() {
        guard Splash.enabled, panel == nil, !launched else { return }
        present(about: false)
    }
    /// Aperture Pro ▸ About.
    func showAbout() {
        if let panel, about { panel.makeKeyAndOrderFront(nil); return }
        close(now: true)
        present(about: true)
    }
    /// The catalog is open: the splash stays at least 1.5 seconds in all, then fades.
    func ready(_ count: Int) {
        launched = true
        guard panel != nil, !about else { return }
        status = "Opened \(count.formatted()) photo\(count == 1 ? "" : "s")"
        let wait = max(0.25, 1.5 - Date().timeIntervalSince(shownAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            if self?.about == false { self?.close() }
        }
    }
    func close(now: Bool = false) {
        guard let p = panel else { return }
        panel = nil
        if now { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.35; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private func present(about: Bool) {
        self.about = about
        if !about { status = "Opening catalog…" }
        let size = NSSize(width: SplashView.width, height: SplashView.height)
        let p = SplashPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: SplashView(splash: self))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.center()
        if about { NSApp.activate(); p.makeKeyAndOrderFront(nil) } else { p.orderFrontRegardless() }
        p.displayIfNeeded(); p.invalidateShadow()
        panel = p; shownAt = Date()
    }
}

/// Borderless, but can take Escape (and ⌘W) to close.
final class SplashPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { Splash.shared.close() }
    override func performClose(_ sender: Any?) { Splash.shared.close() }
}

struct SplashView: View {
    static let width: CGFloat = 980, height: CGFloat = 600
    let splash: Splash
    private let ink = Color(white: 0.12), soft = Color(white: 0.45), faint = Color(white: 0.62)
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private static let photo: NSImage? = Bundle.main.url(forResource: "Splash", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Splash.appName).font(.system(size: 36, weight: .light)).tracking(-0.6).foregroundStyle(ink)
                        Text("Version \(version)").font(.system(size: 12)).foregroundStyle(soft)
                    }
                }
                Spacer()
                if splash.about {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Splash.credits, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(soft) }
                    }
                    Spacer()
                }
                Text("Artwork by Mohamed Malik").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                Text(Splash.copyright).font(.system(size: 11)).foregroundStyle(soft).padding(.top, 4)
                Rectangle().fill(Color(white: 0.88)).frame(height: 1).padding(.vertical, 16)
                Text(splash.about ? "Click anywhere or press Escape to close" : splash.status)
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(faint)
                    .animation(.easeInOut(duration: 0.2), value: splash.status)
            }
            .padding(.horizontal, 44).padding(.vertical, 40)
            .frame(width: SplashView.width - 480, height: SplashView.height, alignment: .leading)
            .background(Color(white: 0.985))
            Group {
                if let img = SplashView.photo { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                else { Color(red: 0.1, green: 0.75, blue: 0.68) }
            }
            .frame(width: 480, height: SplashView.height).clipped()
        }
        .frame(width: SplashView.width, height: SplashView.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture { splash.close() }
    }
}

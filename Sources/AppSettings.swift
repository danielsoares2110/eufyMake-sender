import SwiftUI
import AppKit

// User-facing preferences, persisted in UserDefaults.
// `limitWindowSize` feeds the main window's minSize; `showActivity` controls whether
// the Activity log panel takes part in the layout at all.

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let limitWindowSize = "limitWindowSize"
        static let showActivity = "showActivityLog"
    }

    /// Minimum content sizes used when the limit is enabled / disabled.
    static let limitedMinSize = NSSize(width: 1020, height: 660)
    static let unlimitedMinSize = NSSize(width: 520, height: 360)

    private let defaults = UserDefaults.standard

    @Published var limitWindowSize: Bool {
        didSet { defaults.set(limitWindowSize, forKey: Key.limitWindowSize) }
    }

    @Published var showActivity: Bool {
        didSet { defaults.set(showActivity, forKey: Key.showActivity) }
    }

    private init() {
        defaults.register(defaults: [Key.limitWindowSize: true, Key.showActivity: false])
        limitWindowSize = defaults.object(forKey: Key.limitWindowSize) as? Bool ?? true
        showActivity = defaults.object(forKey: Key.showActivity) as? Bool ?? false
    }
}

// MARK: - Settings window

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.contentView = hosting
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Form {
                Section {
                    Toggle("Limit how small the window can get", isOn: $settings.limitWindowSize)
                    Text(settings.limitWindowSize
                         ? "The window stops at 1020 × 660 so the printer panels always stay readable."
                         : "Unlocked — the window can be shrunk down to 520 × 360.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Toggle("Show the Activity log", isOn: $settings.showActivity)
                    Text("The log shows the raw [API] / [Pppp] / [MQTT] traffic. Handy when something misbehaves, hidden by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            appIcon(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("EufyMake Sender").font(.headline)
                Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// The app's real icon (compiled from the Icon Composer `.icon` into the bundle),
/// with a graceful fallback for a bad/absent resource.
func appIcon(size: CGFloat) -> some View {
    Group {
        if let ns = NSImage(named: "EufyMake Sender") {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.75, blue: 0.32),
                                                  Color(red: 0.13, green: 0.62, blue: 0.24)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
    .frame(width: size, height: size)
}

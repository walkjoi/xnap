import AppKit
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show() {
        let controller = shared ?? SettingsWindowController()
        let wasVisible = controller.window?.isVisible ?? false
        if shared == nil { controller.window?.center() }
        shared = controller
        if !wasVisible { DockPresence.windowOpened() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Xnap Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { DockPresence.windowClosed() }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ScrollingSettings().tabItem { Label("Scrolling", systemImage: "arrow.up.and.down.square") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 580)
    }
}

// MARK: - General

/// Live system state shown in Settings (login item, permissions). A plain observable
/// object rather than `@State`, so the project builds with Command Line Tools alone.
@MainActor
final class SystemStatus: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var screenRecording = ScreenCapture.hasPermission
    @Published var accessibility = AutoScroll.hasPermission

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenRecording = ScreenCapture.hasPermission
        accessibility = AutoScroll.hasPermission
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var status = SystemStatus()

    private var folderPath: String {
        _ = prefs.saveFolderBookmark // re-render when the folder changes
        return Self.displayPath(OutputManager.shared.saveFolder)
    }

    var body: some View {
        Form {
            Section("After Capture") {
                Picker("When a capture is taken", selection: $prefs.afterCapture) {
                    ForEach(Preferences.AfterCapture.allCases) { Text($0.title).tag($0) }
                }
                if prefs.afterCapture == .showPreview {
                    LabeledContent("Preview stays for") {
                        Stepper("\(Int(prefs.previewSeconds)) seconds", value: $prefs.previewSeconds, in: 2...30, step: 1)
                    }
                }
                Toggle("Play capture sound", isOn: $prefs.playSound)
                Toggle("Include the pointer in full-screen captures", isOn: $prefs.showCursor)
            }

            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseFolder)
                        Button { OutputManager.shared.revealSaveFolder() } label: { Image(systemName: "folder") }
                            .help("Show in Finder")
                    }
                }
                if prefs.saveFolderBookmark != nil {
                    Button("Use Default Folder (Pictures › Xnap)") {
                        OutputManager.shared.setSaveFolder(nil)
                    }
                }
                Picker("Format", selection: $prefs.imageFormat) {
                    ForEach(Preferences.ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if prefs.imageFormat == .jpeg {
                    LabeledContent("JPEG quality") {
                        Slider(value: $prefs.jpegQuality, in: 0.5...1) { EmptyView() }
                            minimumValueLabel: { Text("Smaller") } maximumValueLabel: { Text("Better") }
                    }
                }
                Toggle("Also copy to the clipboard when saving to a file", isOn: $prefs.copyWhenSaving)
            } header: {
                Text("Saving to File")
            } footer: {
                Text("Captures go to the clipboard by default. Use the “to File” shortcuts (⌃⌥⇧ + number) to save instead.")
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Launch Xnap at login", isOn: Binding(
                    get: { status.launchAtLogin },
                    set: { status.setLaunchAtLogin($0) }))
                if let loginError = status.loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Xnap saves screenshots"
        panel.directoryURL = OutputManager.shared.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        OutputManager.shared.setSaveFolder(url)
    }

    static func displayPath(_ url: URL) -> String {
        let home = OutputManager.shared.defaultFolder.deletingLastPathComponent().deletingLastPathComponent().path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action, prefs: prefs)
                            .frame(width: 170, height: 24)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("Clipboard is the default destination. Adding ⌥ to a capture shortcut saves it to a file instead. While a scrolling capture runs, press its shortcut again (or ⏎) to finish.")
                    .foregroundStyle(.secondary)
            }
            if !prefs.conflictingActions.isEmpty {
                Section {
                    Label("Some shortcuts are already taken by another app. Record a different combination.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button("Restore Default Shortcuts") { prefs.resetShortcuts() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

// MARK: - Scrolling

private struct ScrollingSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var status = SystemStatus()
    private var accessibilityGranted: Bool { status.accessibility }

    var body: some View {
        Form {
            Section("Auto-Scroll") {
                Picker("Speed", selection: $prefs.autoScrollSpeed) {
                    ForEach(Preferences.AutoScrollSpeed.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accessibility access") {
                    HStack {
                        PermissionBadge(granted: accessibilityGranted)
                        if !accessibilityGranted {
                            Button("Grant…") {
                                AutoScroll.requestPermission()
                                AutoScroll.openPrivacySettings()
                            }
                        }
                    }
                }
                Text("Only needed if you want Xnap to scroll for you. Scrolling by hand works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Limits") {
                Picker("Maximum capture height", selection: $prefs.scrollMaxHeight) {
                    ForEach([10_000, 20_000, 30_000, 50_000], id: \.self) { Text("\($0.formatted()) px").tag($0) }
                }
            }
            Section("Tips") {
                VStack(alignment: .leading, spacing: 8) {
                    tip("rectangle.dashed", "Select just the part that scrolls, or click a whole window. Toolbars and sticky headers or footers are detected and kept only once.")
                    tip("tortoise", "Scroll at a steady pace. If you go too fast, Xnap asks you to scroll back a little and carries on.")
                    tip("return", "Press ⏎ or the shortcut again to finish, ⎋ to cancel.")
                    tip("arrow.down.to.line", "Auto-Scroll stops by itself at the end of the page. Move the pointer away to pause it.")
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .onAppear { status.refresh() }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
        }
    }
}

// MARK: - Privacy

/// Reads Xnap's own code-signing entitlements, so the claims below are checked
/// against what macOS actually enforces rather than just stated.
enum PrivacyStatus {
    static func entitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool) ?? false
    }

    static var isSandboxed: Bool { entitlement("com.apple.security.app-sandbox") }
    static var mayConnectOut: Bool { entitlement("com.apple.security.network.client") }
    static var mayListen: Bool { entitlement("com.apple.security.network.server") }
    static var networkBlocked: Bool { isSandboxed && !mayConnectOut && !mayListen }
}

private struct PrivacySettings: View {
    @StateObject private var status = SystemStatus()
    private var screenGranted: Bool { status.screenRecording }
    private var accessibilityGranted: Bool { status.accessibility }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: PrivacyStatus.networkBlocked ? "lock.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(PrivacyStatus.networkBlocked ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fully local").font(.headline)
                        Text("Xnap is built without network permission, so macOS itself blocks it from connecting anywhere. Screenshots, scrolling captures and text recognition never leave this Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Checked on This Copy of the App") {
                StatusRow(title: "App Sandbox", ok: PrivacyStatus.isSandboxed,
                          detail: PrivacyStatus.isSandboxed ? "Enabled" : "Off — development build")
                StatusRow(title: "Outgoing network connections", ok: PrivacyStatus.isSandboxed && !PrivacyStatus.mayConnectOut,
                          detail: PrivacyStatus.isSandboxed && !PrivacyStatus.mayConnectOut ? "Blocked by macOS" : "Not enforced")
                StatusRow(title: "Incoming network connections", ok: PrivacyStatus.isSandboxed && !PrivacyStatus.mayListen,
                          detail: PrivacyStatus.isSandboxed && !PrivacyStatus.mayListen ? "Blocked by macOS" : "Not enforced")
            }

            Section("Permissions") {
                LabeledContent {
                    HStack {
                        PermissionBadge(granted: screenGranted)
                        if !screenGranted { Button("Open Settings…") { ScreenCapture.openPrivacySettings() } }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Screen Recording")
                        Text("Required to take screenshots").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    HStack {
                        PermissionBadge(granted: accessibilityGranted)
                        if !accessibilityGranted { Button("Open Settings…") { AutoScroll.openPrivacySettings() } }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                        Text("Optional — only used for Auto-Scroll").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Captures are copied to the clipboard or saved to the folder you choose. Text recognition uses Apple’s on-device Vision framework. There is no account, analytics or telemetry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
        .onAppear { status.refresh() }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        LabeledContent(title) {
            Label(detail, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
    }
}

private struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(granted ? Color.green : Color.secondary)
    }
}

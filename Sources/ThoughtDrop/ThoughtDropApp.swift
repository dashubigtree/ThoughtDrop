import SwiftUI
import AppKit
import Carbon

@main
struct ThoughtDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var chatWindow: NSWindow?
    private var model: AppModel!
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should only activate the existing app, never run a second scheduler.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.thoughtdrop.app")
        if let other = duplicates.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "拾念：開啟錄音")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showPanel)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 490), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "拾念 ThoughtDrop"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CaptureView(model: model))
        panel.center()
        model.openChat = { [weak self] in self?.showChat() }
        registerShortcut()
        showPanel()
    }

    @objc private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func showChat() {
        if chatWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "拾念 · 知識庫對話"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ChatView(model: model))
            window.center()
            chatWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        chatWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in delegate.showPanel(); delegate.model.toggleRecording() }
            return noErr
        }, 1, &event, pointer, &handler)
        let id = EventHotKeyID(signature: 0x54484450, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        model.shortcutAvailable = result == noErr
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        if model.recording || model.starting || model.processing || model.summarizing || model.checkingConnection || model.asking {
            let alert = NSAlert()
            alert.messageText = "錄音或整理還在進行"
            alert.informativeText = "請完成後再結束。關閉視窗即可讓拾念繼續在選單列運作。"
            alert.addButton(withTitle: "繼續運作")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}

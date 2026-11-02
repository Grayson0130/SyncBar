// SyncBar v2: dual-ended menu-bar switch between Deskflow edge mode and sync broadcast.
// No hotkey. One sending mode at a time; the receiver is always on.
//  - Edge:     stock deskflow-core, mode read from ~/Library/Deskflow/Deskflow.conf:
//              coreMode=2 -> "server" (550xe), coreMode=1 -> "client" (c8dh, remoteHost from conf).
//              Deskflow GUI is quit on takeover, so its retry logic cannot relaunch a second core.
//  - Broadcast: ~/sync-helper/sync-sender <other-machine-ip>
//              other IP: client machines use conf remoteHost; server machines use
//              ~/sync-helper/syncbar-target.txt if present, else 192.168.66.11 (c8dh).
//  - Receiver: ~/sync-helper/sync-receiver, started on launch, kept across mode
//              switches, stopped only on Quit. It posts to the session tap, so a
//              sender's HID tap never sees injected events: both machines may
//              broadcast at once without an echo loop.
// The wrapper itself captures no input and needs no Accessibility grant in
// theory, but in practice macOS attributes its children's event taps to it,
// so SyncBar itself must be granted Accessibility (and Input Monitoring) once
// per machine, exactly as on 550xe v1.
import AppKit
import Foundation
import Darwin

enum Mode: String {
    case edge, broadcast, stopped
}

let home = FileManager.default.homeDirectoryForCurrentUser
let senderPath = home.appendingPathComponent("sync-helper/sync-sender").path
let receiverPath = home.appendingPathComponent("sync-helper/sync-receiver").path
let corePath = home.appendingPathComponent("Applications/Deskflow.app/Contents/MacOS/deskflow-core").path
let senderLog = home.appendingPathComponent("sync-helper/syncbar-sender.log").path
let receiverLog = home.appendingPathComponent("sync-helper/syncbar-receiver.log").path
let coreLog = home.appendingPathComponent("sync-helper/syncbar-core.log").path
let deskflowConf = home.appendingPathComponent("Library/Deskflow/Deskflow.conf").path
let targetOverride = home.appendingPathComponent("sync-helper/syncbar-target.txt").path

func log(_ s: String) { NSLog("[SyncBar] %@", s) }

func runAndWait(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    do { try p.run(); p.waitUntilExit() } catch { log("run failed \(path): \(error)") }
}

func appendHandle(_ path: String) -> FileHandle? {
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    do {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.seekToEnd()
        return h
    } catch { log("cannot open log \(path): \(error)"); return nil }
}

// Parse Deskflow.conf: returns (coreMode, remoteHost). coreMode: 1=client, 2=server.
func deskflowSettings() -> (Int, String) {
    var mode = 2
    var host = ""
    guard let text = try? String(contentsOfFile: deskflowConf, encoding: .utf8) else { return (mode, host) }
    var section = ""
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast())
            continue
        }
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        if section == "core", parts[0] == "coreMode", let v = Int(parts[1]) { mode = v }
        if section == "client", parts[0] == "remoteHost" { host = parts[1] }
    }
    return (mode, host)
}

func senderTarget() -> String {
    let (mode, host) = deskflowSettings()
    if mode == 1, !host.isEmpty { return host }
    if let t = try? String(contentsOfFile: targetOverride, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    return "192.168.66.11"
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var edgeItem: NSMenuItem!
    var broadcastItem: NSMenuItem!
    var statusTextItem: NSMenuItem!
    var receiverItem: NSMenuItem!
    var mode: Mode = .stopped
    var senderProc: Process?
    var coreProc: Process?
    var receiverProc: Process?
    var timer: Timer?
    var switching = false
    var quitting = false
    var roleText = "—"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (modeNum, _) = deskflowSettings()
        roleText = (modeNum == 1) ? "客户端 (Deskflow client)" : "服务端 (Deskflow server)"
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "○ SyncBar"
        statusItem.button?.toolTip = "SyncBar: 边缘切换 / 广播同步 二选一，接收端常驻"

        let menu = NSMenu()
        edgeItem = NSMenuItem(title: "⇄ 边缘切换 (Deskflow)", action: #selector(toEdge), keyEquivalent: "")
        broadcastItem = NSMenuItem(title: "📡 广播同步", action: #selector(toBroadcast), keyEquivalent: "")
        statusTextItem = NSMenuItem(title: "状态：启动中…", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        receiverItem = NSMenuItem(title: "接收端：启动中…", action: nil, keyEquivalent: "")
        receiverItem.isEnabled = false
        let quitItem = NSMenuItem(title: "退出 SyncBar", action: #selector(quitApp), keyEquivalent: "q")
        edgeItem.target = self; broadcastItem.target = self; quitItem.target = self
        menu.addItem(edgeItem); menu.addItem(broadcastItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(statusTextItem); menu.addItem(receiverItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.watchdog() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Take over: quit Deskflow GUI, clear stray senders/cores (receiver is ours to start).
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "org.deskflow.deskflow" {
                app.terminate()
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                Thread.sleep(forTimeInterval: 1.0)
                runAndWait("/usr/bin/pkill", ["-x", "deskflow-core"])
                runAndWait("/usr/bin/pkill", ["-x", "sync-sender"])
                self.startReceiver()
                let saved = UserDefaults.standard.string(forKey: "SyncBar.mode") ?? "edge"
                let startMode: Mode = (saved == "broadcast") ? .broadcast : .edge
                DispatchQueue.main.async { self.switchTo(startMode) }
            }
        }
    }

    @objc func toEdge() { switchTo(.edge) }
    @objc func toBroadcast() { switchTo(.broadcast) }
    @objc func quitApp() {
        quitting = true
        stopAll()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopAll()
    }

    func updateUI(status: String) {
        DispatchQueue.main.async { [self] in
            switch mode {
            case .edge: statusItem.button?.title = "⇄ 边缘"
            case .broadcast: statusItem.button?.title = "📡 同步"
            case .stopped: statusItem.button?.title = "○ 停止"
            }
            edgeItem.state = (mode == .edge) ? .on : .off
            broadcastItem.state = (mode == .broadcast) ? .on : .off
            statusTextItem.title = "状态：\(status) · 本机 \(roleText) · 对端 \(senderTarget())"
            receiverItem.title = "接收端：\(receiverProc?.isRunning == true ? "运行中" : "未运行")"
        }
    }

    func switchTo(_ newMode: Mode) {
        if switching { return }
        if newMode == mode, (newMode == .edge && coreProc?.isRunning == true) || (newMode == .broadcast && senderProc?.isRunning == true) {
            return
        }
        switching = true
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "SyncBar.mode")
        updateUI(status: "切换中…")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if newMode == .edge {
                stopProcess(senderProc); senderProc = nil
                runAndWait("/usr/bin/pkill", ["-x", "sync-sender"])
                startCore()
            } else if newMode == .broadcast {
                stopProcess(coreProc); coreProc = nil
                runAndWait("/usr/bin/pkill", ["-x", "deskflow-core"])
                startSender()
            }
            // Receiver is never touched on a mode switch.
            switching = false
            updateUI(status: newMode == .edge ? "边缘切换运行中" : "广播同步运行中")
        }
    }

    func stopProcess(_ p: Process?) {
        guard let p = p else { return }
        if p.isRunning {
            p.terminate()
            for _ in 0..<20 {
                if !p.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func stopAll() {
        stopProcess(senderProc); senderProc = nil
        stopProcess(coreProc); coreProc = nil
        stopProcess(receiverProc); receiverProc = nil
        runAndWait("/usr/bin/pkill", ["-x", "deskflow-core"])
        runAndWait("/usr/bin/pkill", ["-x", "sync-sender"])
        runAndWait("/usr/bin/pkill", ["-x", "sync-receiver"])
    }

    func startCore() {
        let (modeNum, _) = deskflowSettings()
        let arg = (modeNum == 1) ? "client" : "server"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: corePath)
        p.arguments = [arg]
        if let out = appendHandle(coreLog) { p.standardOutput = out; p.standardError = out }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.mode == .edge else { return }
                self.mode = .stopped; self.coreProc = nil
                self.updateUI(status: "边缘 core 已退出，点菜单可重起")
            }
        }
        do { try p.run(); coreProc = p; senderProc = nil; log("core \(arg) started pid \(p.processIdentifier)") }
        catch { log("core start failed: \(error)") }
    }

    func startSender() {
        let target = senderTarget()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: senderPath)
        p.arguments = [target]
        if let out = appendHandle(senderLog) { p.standardOutput = out; p.standardError = out }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.mode == .broadcast else { return }
                self.mode = .stopped; self.senderProc = nil
                self.updateUI(status: "sender 已退出，点菜单可重起")
            }
        }
        do { try p.run(); senderProc = p; coreProc = nil; log("sender -> \(target) pid \(p.processIdentifier)") }
        catch { log("sender start failed: \(error)") }
    }

    func startReceiver() {
        guard FileManager.default.fileExists(atPath: receiverPath) else {
            log("receiver missing at \(receiverPath), skipping"); return
        }
        if receiverProc?.isRunning == true { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: receiverPath)
        p.arguments = []
        if let out = appendHandle(receiverLog) { p.standardOutput = out; p.standardError = out }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.receiverProc = nil; self?.updateUI(status: "接收端已退出，将自动重起") }
        }
        do { try p.run(); receiverProc = p; log("receiver started pid \(p.processIdentifier)") }
        catch { log("receiver start failed: \(error)") }
    }

    func watchdog() {
        if mode == .edge, let p = coreProc, !p.isRunning {
            mode = .stopped; coreProc = nil; updateUI(status: "边缘 core 已退出，点菜单可重起")
        } else if mode == .broadcast, let p = senderProc, !p.isRunning {
            mode = .stopped; senderProc = nil; updateUI(status: "sender 已退出，点菜单可重起")
        }
        if !quitting, receiverProc?.isRunning != true {
            // Receiver is always-on: restart it on its own, never as a mode change.
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.startReceiver() }
        }
        updateUI(status: mode == .edge ? "边缘切换运行中" : mode == .broadcast ? "广播同步运行中" : "已停止")
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

// SyncBar v2.1: dual-ended menu-bar switch between Deskflow edge mode and sync broadcast.
// No hotkey. One sending mode at a time; the receiver is always on.
// Languages: zh / en / ja / fr / de / es, plus "follow system".
// Language is chosen from the menu (no restart needed) and persisted.
// Strings live in code on purpose: this app has no .lproj bundle, and a
// menu-driven switch is more useful here than a system-only locale.
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

enum Lang: String, CaseIterable {
    case zh, en, ja, fr, de, es
    var nativeName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }
}

// Stored language: "system" or a Lang raw value. Effective language resolves
// "system" from the OS preferred languages, falling back to English.
func effectiveLang() -> Lang {
    let stored = UserDefaults.standard.string(forKey: "SyncBar.language") ?? "system"
    if let l = Lang(rawValue: stored) { return l }
    let pref = Locale.preferredLanguages.first ?? "en"
    let code = pref.lowercased()
    if code.hasPrefix("zh") { return .zh }
    if code.hasPrefix("ja") { return .ja }
    if code.hasPrefix("fr") { return .fr }
    if code.hasPrefix("de") { return .de }
    if code.hasPrefix("es") { return .es }
    return .en
}

// key -> zh / en / ja / fr / de / es
let STR: [String: [Lang: String]] = [
    "edgeMenu": [.zh: "⇄ 边缘切换 (Deskflow)", .en: "⇄ Edge Switching (Deskflow)", .ja: "⇄ エッジ切り替え (Deskflow)", .fr: "⇄ Commutation par bord (Deskflow)", .de: "⇄ Kantenwechsel (Deskflow)", .es: "⇄ Cambio por borde (Deskflow)"],
    "broadcastMenu": [.zh: "📡 广播同步", .en: "📡 Broadcast Sync", .ja: "📡 ブロードキャスト同期", .fr: "📡 Synchronisation par diffusion", .de: "📡 Broadcast-Synchronisierung", .es: "📡 Sincronización por difusión"],
    "edgeShort": [.zh: "边缘", .en: "Edge", .ja: "エッジ", .fr: "Bord", .de: "Rand", .es: "Borde"],
    "syncShort": [.zh: "同步", .en: "Sync", .ja: "同期", .fr: "Diffusion", .de: "Broadcast", .es: "Difusión"],
    "stoppedShort": [.zh: "停止", .en: "Stopped", .ja: "停止", .fr: "Arrêté", .de: "Gestoppt", .es: "Detenido"],
    "statusPrefix": [.zh: "状态：", .en: "Status: ", .ja: "状態：", .fr: "État : ", .de: "Status: ", .es: "Estado: "],
    "localPrefix": [.zh: "本机 ", .en: "Local ", .ja: "自機 ", .fr: "Local ", .de: "Lokal ", .es: "Local "],
    "peerPrefix": [.zh: "对端 ", .en: "Peer ", .ja: "相手 ", .fr: "Pair ", .de: "Gegenstelle ", .es: "Par "],
    "edgeRunning": [.zh: "边缘切换运行中", .en: "Edge switching running", .ja: "エッジ切り替え実行中", .fr: "Commutation par bord en cours", .de: "Kantenwechsel läuft", .es: "Cambio por borde en curso"],
    "broadcastRunning": [.zh: "广播同步运行中", .en: "Broadcast sync running", .ja: "ブロードキャスト同期実行中", .fr: "Synchronisation par diffusion en cours", .de: "Broadcast-Synchronisierung läuft", .es: "Sincronización por difusión en curso"],
    "switching": [.zh: "切换中…", .en: "Switching…", .ja: "切り替え中…", .fr: "Basculement…", .de: "Wechseln…", .es: "Cambiando…"],
    "stopped": [.zh: "已停止", .en: "Stopped", .ja: "停止中", .fr: "Arrêté", .de: "Gestoppt", .es: "Detenido"],
    "coreExited": [.zh: "边缘 core 已退出，点菜单可重起", .en: "Edge core exited, click the menu to restart", .ja: "エッジコアが終了しました。メニューから再起動できます", .fr: "Le cœur Edge s'est arrêté, relancez-le depuis le menu", .de: "Edge-Core beendet, über das Menü neu starten", .es: "El núcleo Edge se cerró, reinícielo desde el menú"],
    "senderExited": [.zh: "sender 已退出，点菜单可重起", .en: "Sender exited, click the menu to restart", .ja: "sender が終了しました。メニューから再起動できます", .fr: "L'émetteur s'est arrêté, relancez-le depuis le menu", .de: "Sender beendet, über das Menü neu starten", .es: "El emisor se cerró, reinícielo desde el menú"],
    "receiverRestarting": [.zh: "接收端已退出，将自动重起", .en: "Receiver exited, restarting automatically", .ja: "受信側が終了しました。自動で再起動します", .fr: "Le récepteur s'est arrêté, redémarrage automatique", .de: "Empfänger beendet, wird automatisch neu gestartet", .es: "El receptor se cerró, se reiniciará automáticamente"],
    "receiverRunning": [.zh: "接收端：运行中", .en: "Receiver: Running", .ja: "受信側：実行中", .fr: "Récepteur : en cours", .de: "Empfänger: läuft", .es: "Receptor: en curso"],
    "receiverStopped": [.zh: "接收端：未运行", .en: "Receiver: Not running", .ja: "受信側：停止中", .fr: "Récepteur : arrêté", .de: "Empfänger: gestoppt", .es: "Receptor: detenido"],
    "roleServer": [.zh: "服务端 (Deskflow server)", .en: "Server (Deskflow server)", .ja: "サーバー (Deskflow server)", .fr: "Serveur (Deskflow server)", .de: "Server (Deskflow server)", .es: "Servidor (Deskflow server)"],
    "roleClient": [.zh: "客户端 (Deskflow client)", .en: "Client (Deskflow client)", .ja: "クライアント (Deskflow client)", .fr: "Client (Deskflow client)", .de: "Client (Deskflow client)", .es: "Cliente (Deskflow client)"],
    "quit": [.zh: "退出 SyncBar", .en: "Quit SyncBar", .ja: "SyncBar を終了", .fr: "Quitter SyncBar", .de: "SyncBar beenden", .es: "Salir de SyncBar"],
    "languageMenu": [.zh: "语言", .en: "Language", .ja: "言語", .fr: "Langue", .de: "Sprache", .es: "Idioma"],
    "followSystem": [.zh: "跟随系统", .en: "Follow System", .ja: "システムに従う", .fr: "Suivre le système", .de: "System folgen", .es: "Seguir el sistema"],
    "tooltip": [.zh: "SyncBar：边缘切换 / 广播同步 二选一", .en: "SyncBar: Edge or Broadcast, one at a time", .ja: "SyncBar：エッジ切り替え / ブロードキャスト同期のどちらか一方", .fr: "SyncBar : bord ou diffusion, l'un ou l'autre", .de: "SyncBar: Kantenwechsel oder Broadcast, jeweils nur eines", .es: "SyncBar: borde o difusión, solo uno a la vez"],
]

func tr(_ key: String) -> String {
    return STR[key]?[effectiveLang()] ?? STR[key]?[.en] ?? key
}

enum UIStatus {
    case switching, edgeRunning, broadcastRunning, stopped, coreExited, senderExited, receiverRestarting
    var key: String {
        switch self {
        case .switching: return "switching"
        case .edgeRunning: return "edgeRunning"
        case .broadcastRunning: return "broadcastRunning"
        case .stopped: return "stopped"
        case .coreExited: return "coreExited"
        case .senderExited: return "senderExited"
        case .receiverRestarting: return "receiverRestarting"
        }
    }
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
    var languageMenuItem: NSMenuItem!
    var languageItems: [String: NSMenuItem] = [:]
    var quitItem: NSMenuItem!
    var mode: Mode = .stopped
    var currentStatus: UIStatus = .stopped
    var senderProc: Process?
    var coreProc: Process?
    var receiverProc: Process?
    var timer: Timer?
    var switching = false
    var quitting = false
    var roleIsServer = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (modeNum, _) = deskflowSettings()
        roleIsServer = (modeNum != 1)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        edgeItem = NSMenuItem(title: "", action: #selector(toEdge), keyEquivalent: "")
        broadcastItem = NSMenuItem(title: "", action: #selector(toBroadcast), keyEquivalent: "")
        statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        receiverItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        receiverItem.isEnabled = false
        quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
        edgeItem.target = self; broadcastItem.target = self; quitItem.target = self

        languageMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let followItem = NSMenuItem(title: "", action: #selector(setLanguage), keyEquivalent: "")
        followItem.target = self; followItem.representedObject = "system"
        languageItems["system"] = followItem
        langMenu.addItem(followItem)
        langMenu.addItem(NSMenuItem.separator())
        for lang in Lang.allCases {
            let item = NSMenuItem(title: lang.nativeName, action: #selector(setLanguage), keyEquivalent: "")
            item.target = self; item.representedObject = lang.rawValue
            languageItems[lang.rawValue] = item
            langMenu.addItem(item)
        }
        languageMenuItem.submenu = langMenu

        menu.addItem(edgeItem); menu.addItem(broadcastItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(statusTextItem); menu.addItem(receiverItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(languageMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateUI(.stopped)

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.watchdog() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
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
    @objc func setLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String {
            UserDefaults.standard.set(code, forKey: "SyncBar.language")
            updateUI(currentStatus)
        }
    }
    @objc func quitApp() {
        quitting = true
        stopAll()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopAll()
    }

    func updateUI(_ status: UIStatus) {
        currentStatus = status
        DispatchQueue.main.async { [self] in
            switch mode {
            case .edge: statusItem.button?.title = "⇄ " + tr("edgeShort")
            case .broadcast: statusItem.button?.title = "📡 " + tr("syncShort")
            case .stopped: statusItem.button?.title = "○ " + tr("stoppedShort")
            }
            statusItem.button?.toolTip = tr("tooltip")
            edgeItem.title = tr("edgeMenu")
            broadcastItem.title = tr("broadcastMenu")
            edgeItem.state = (mode == .edge) ? .on : .off
            broadcastItem.state = (mode == .broadcast) ? .on : .off
            let role = roleIsServer ? tr("roleServer") : tr("roleClient")
            statusTextItem.title = tr("statusPrefix") + tr(status.key) + " · " + tr("localPrefix") + role + " · " + tr("peerPrefix") + senderTarget()
            receiverItem.title = (receiverProc?.isRunning == true) ? tr("receiverRunning") : tr("receiverStopped")
            languageMenuItem.title = tr("languageMenu")
            let stored = UserDefaults.standard.string(forKey: "SyncBar.language") ?? "system"
            for (code, item) in languageItems {
                item.state = (code == stored) ? .on : .off
            }
            if let follow = languageItems["system"] { follow.title = tr("followSystem") }
            quitItem.title = tr("quit")
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
        updateUI(.switching)
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
            switching = false
            updateUI(newMode == .edge ? .edgeRunning : .broadcastRunning)
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
        roleIsServer = (modeNum != 1)
        let arg = (modeNum == 1) ? "client" : "server"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: corePath)
        p.arguments = [arg]
        if let out = appendHandle(coreLog) { p.standardOutput = out; p.standardError = out }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.mode == .edge else { return }
                self.mode = .stopped; self.coreProc = nil
                self.updateUI(.coreExited)
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
                self.updateUI(.senderExited)
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
            DispatchQueue.main.async { self?.receiverProc = nil; self?.updateUI(.receiverRestarting) }
        }
        do { try p.run(); receiverProc = p; log("receiver started pid \(p.processIdentifier)") }
        catch { log("receiver start failed: \(error)") }
    }

    func watchdog() {
        if mode == .edge, let p = coreProc, !p.isRunning {
            mode = .stopped; coreProc = nil; updateUI(.coreExited)
        } else if mode == .broadcast, let p = senderProc, !p.isRunning {
            mode = .stopped; senderProc = nil; updateUI(.senderExited)
        } else {
            updateUI(mode == .edge ? .edgeRunning : mode == .broadcast ? .broadcastRunning : .stopped)
        }
        if !quitting, receiverProc?.isRunning != true {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.startReceiver() }
        }
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

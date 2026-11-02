// SyncBar v2.2.2: dual-ended menu-bar switch between Deskflow edge mode and sync broadcast.
// v2.2.2 fixes the "already running" loop found 2026-11-01 23:03-23:04:
//  - A deskflow-core (or sync-receiver / sync-sender) that outlived the
//    SyncBar instance that started it holds its lock / port, but the new
//    SyncBar instance has no Process for it, so it launches a duplicate
//    that exits immediately ("an instance of deskflow core is already
//    running", "bind: Address already in use"), the termination handler
//    sets the menu to Stopped, and the next click repeats the loop while
//    the original child is actually still running.
//  - Fix: every start now kills ALL processes of that name first and
//    WAITS until none remain (SIGTERM, then SIGKILL after a timeout)
//    before launching a fresh, tracked child. Starting a duplicate while
//    the old one is still shutting down was the other half of the same
//    bug: the old pkill-then-start-immediately sequence gave the new
//    core no time to see a clear lock. startCore/startSender now return
//    Bool so a failed start shows "core exited" instead of a false
//    "running" status, and the receiver is no longer restarted into a
//    port that is already bound.
// No hotkey. One sending mode at a time; the receiver is always on.
// Languages: zh / en / ja / fr / de / es, plus "follow system".
// Language is chosen from the menu (no restart needed) and persisted.
// Strings live in code on purpose: this app has no .lproj bundle, and a
// menu-driven switch is more useful here than a system-only locale.
//
// v2.2 adds 2-device management (no Bonjour yet, that is v2.3):
//  - Devices are stored in ~/Library/Application Support/SyncBar/devices.json:
//    one peer (name + IP/hostname) and this machine's role (server/client).
//    First launch migrates from the old setup: Deskflow.conf coreMode and
//    remoteHost, deskflow-server.conf links, syncbar-target.txt, and the
//    192.168.66.11 fallback, then backs the originals up. Behaviour does
//    not change until the user edits a device or switches role.
//  - "Set Peer Device..." opens a dialog (name + IP/hostname). Saving
//    rewrites Deskflow.conf and, if this machine is the server, the server
//    links, and auto-restarts the currently active child (core or sender).
//  - Role switching is a menu choice (Server / Client). It terminates the
//    Deskflow GUI first (the GUI would otherwise overwrite Deskflow.conf
//    on exit), rewrites the configs with backups, and auto-restarts core
//    if Edge mode is active. Broadcast needs no restart on a role change
//    alone, because its target is always the peer address.
//  - Deskflow.conf editing is line-preserving: only coreMode, computerName
//    (only when missing), [server] externalConfig/externalConfigFile and
//    [client] remoteHost are touched; every other section and line stays.
//    externalConfig lives in [server], not [core] (verified 2026-11-01).
//  - Server links are generated as this machine down = peer, peer up =
//    this machine, matching the original 550xe -> c8dh layout. The peer
//    name must match the peer's Deskflow computer name (usually its
//    hostname.local); the address is what the client/sender connects to.
//  - TLS trust for a brand-new device is NOT automated: if a fingerprint
//    confirmation is required, connect once with the Deskflow GUI, confirm
//    it, then let SyncBar take over (see the peer dialog text).
// v2.2.1 fixes the server-switch failure found 2026-11-01 on c8dh:
//  - A machine that was only ever a client has no [computer_*] sections in
//    Deskflow.conf, and deskflow-core server refuses to load its config
//    ("unknown computer name", FATAL, error code 4) without them. When
//    switching to server, SyncBar now creates [computer_<local>] and
//    [computer_<peer>] sections (GUI defaults, name substituted) if missing.
//  - The peer name must be the peer's Deskflow computer name, never a bare
//    IP: server links match clients by computer name, so an IP as a name
//    silently breaks Edge. The peer dialog now refuses to save an IPv4
//    address as the name, and an empty name only defaults to the address
//    when the address is a hostname, not an IP.
//  - Edge:     stock deskflow-core, mode read from Deskflow.conf:
//              coreMode=2 -> "server", coreMode=1 -> "client".
//              Deskflow GUI is quit on takeover, so its retry logic cannot
//              relaunch a second core.
//  - Broadcast: ~/sync-helper/sync-sender <peer-address>
//  - Receiver: ~/sync-helper/sync-receiver, started on launch, kept across
//              mode switches, stopped only on Quit. It posts to the session
//              tap, so a sender's HID tap never sees injected events: both
//              machines may broadcast at once without an echo loop.
// The wrapper itself captures no input and needs no Accessibility grant in
// theory, but in practice macOS attributes its children's event taps to it,
// so SyncBar itself must be granted Accessibility (and Input Monitoring)
// once per machine, exactly as on 550xe v1.
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
    "peerSettings": [.zh: "设置对端设备…", .en: "Set Peer Device…", .ja: "対向デバイスを設定…", .fr: "Configurer l'appareil pair…", .de: "Peer-Gerät einstellen…", .es: "Configurar dispositivo par…"],
    "roleMenu": [.zh: "本机角色", .en: "This Machine's Role", .ja: "自機の役割", .fr: "Rôle de cette machine", .de: "Rolle dieses Geräts", .es: "Rol de este equipo"],
    "roleServerItem": [.zh: "服务端", .en: "Server", .ja: "サーバー", .fr: "Serveur", .de: "Server", .es: "Servidor"],
    "roleClientItem": [.zh: "客户端", .en: "Client", .ja: "クライアント", .fr: "Client", .de: "Client", .es: "Cliente"],
    "peerDialogTitle": [.zh: "设置对端设备", .en: "Set Peer Device", .ja: "対向デバイスの設定", .fr: "Configurer l'appareil pair", .de: "Peer-Gerät einstellen", .es: "Configurar dispositivo par"],
    "peerDialogInfo": [.zh: "名称请填对端在 Deskflow 里显示的电脑名（通常是主机名）；IP / 主机名填连接地址。首次连接新设备时如需信任指纹，请先用 Deskflow GUI 连接一次并确认，之后再由 SyncBar 接管。", .en: "Enter the peer's computer name as shown in Deskflow, and its IP or hostname for connection. On first connection to a new device, if a fingerprint trust is required, connect once with the Deskflow GUI and confirm it, then let SyncBar take over.", .ja: "対向デバイスのコンピュータ名（Deskflow に表示されるもの）と、接続用の IP またはホスト名を入力してください。新しいデバイスへの初回接続で指紋の信頼確認が必要な場合は、まず Deskflow GUI で接続して確認し、その後 SyncBar に任せてください。", .fr: "Saisissez le nom d'ordinateur du pair tel qu'affiché dans Deskflow, ainsi que son IP ou nom d'hôte pour la connexion. Lors d'une première connexion à un nouvel appareil, si une confirmation d'empreinte est requise, connectez-vous une fois avec l'interface Deskflow, confirmez, puis laissez SyncBar prendre le relais.", .de: "Geben Sie den Computernamen des Peers wie in Deskflow angezeigt sowie seine IP oder seinen Hostnamen für die Verbindung ein. Bei der ersten Verbindung zu einem neuen Gerät muss ein Fingerabdruck gegebenenfalls bestätigt werden: Verbinden Sie sich einmal über die Deskflow-Oberfläche, bestätigen Sie ihn und überlassen Sie danach SyncBar die Steuerung.", .es: "Escriba el nombre de equipo del par tal como aparece en Deskflow y su IP o nombre de host para la conexión. En la primera conexión a un dispositivo nuevo, si se requiere confirmar una huella, conéctese una vez con la interfaz de Deskflow, confírmela y luego deje que SyncBar tome el control."],
    "peerNameLabel": [.zh: "名称", .en: "Name", .ja: "名前", .fr: "Nom", .de: "Name", .es: "Nombre"],
    "peerAddressLabel": [.zh: "IP / 主机名", .en: "IP / Hostname", .ja: "IP / ホスト名", .fr: "IP / Nom d'hôte", .de: "IP / Hostname", .es: "IP / Nombre de host"],
    "saveButton": [.zh: "保存", .en: "Save", .ja: "保存", .fr: "Enregistrer", .de: "Speichern", .es: "Guardar"],
    "cancelButton": [.zh: "取消", .en: "Cancel", .ja: "キャンセル", .fr: "Annuler", .de: "Abbrechen", .es: "Cancelar"],
    "okButton": [.zh: "确定", .en: "OK", .ja: "OK", .fr: "OK", .de: "OK", .es: "Aceptar"],
    "peerNameIPTitle": [.zh: "对端名称不能是 IP", .en: "Peer Name Cannot Be an IP Address", .ja: "対向デバイス名に IP アドレスは使えません", .fr: "Le nom du pair ne peut pas être une adresse IP", .de: "Der Peer-Name darf keine IP-Adresse sein", .es: "El nombre del par no puede ser una dirección IP"],
    "peerNameIPInfo": [.zh: "对端名称必须是它在 Deskflow 里显示的电脑名（例如 Mac-Pro-550xe.local），IP 只填在下面的地址栏里。请把名称改成电脑名再保存。", .en: "The peer name must be the computer name as shown in Deskflow (for example Mac-Pro-550xe.local). Put the IP address in the address field below. Please change the name to the computer name and save again.", .ja: "対向デバイス名は、Deskflow に表示されるコンピュータ名（例：Mac-Pro-550xe.local）でなければなりません。IP アドレスは下のアドレス欄に入力してください。名前をコンピュータ名に変更してから再度保存してください。", .fr: "Le nom du pair doit être le nom d'ordinateur tel qu'affiché dans Deskflow (par exemple Mac-Pro-550xe.local). Mettez l'adresse IP dans le champ d'adresse ci-dessous. Veuillez remplacer le nom par le nom d'ordinateur, puis enregistrer à nouveau.", .de: "Der Peer-Name muss der Computername sein, wie er in Deskflow angezeigt wird (zum Beispiel Mac-Pro-550xe.local). Tragen Sie die IP-Adresse unten im Adressfeld ein. Bitte ändern Sie den Namen in den Computernamen und speichern Sie erneut.", .es: "El nombre del par debe ser el nombre de equipo tal como aparece en Deskflow (por ejemplo, Mac-Pro-550xe.local). Escriba la dirección IP en el campo de dirección de abajo. Cambie el nombre por el nombre de equipo y guarde de nuevo."],
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
let serverConf = home.appendingPathComponent("Library/Deskflow/deskflow-server.conf").path
let targetOverride = home.appendingPathComponent("sync-helper/syncbar-target.txt").path
let appSupportDir = home.appendingPathComponent("Library/Application Support/SyncBar").path
let devicesFile = home.appendingPathComponent("Library/Application Support/SyncBar/devices.json").path

func log(_ s: String) { NSLog("[SyncBar] %@", s) }

func runAndWait(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    do { try p.run(); p.waitUntilExit() } catch { log("run failed \(path): \(error)") }
}

func runCapture(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// --- v2.2.2: kill-before-start helpers ---
// PIDs of currently running processes with this exact name (empty if none).
func pids(for name: String) -> [Int32] {
    let out = runCapture("/usr/bin/pgrep", ["-x", name])
    if out.isEmpty { return [] }
    return out.components(separatedBy: .newlines).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

// Kill every process of this name and wait until none remain. Returns true
// when the name is clear, false if a process stubbornly survives SIGKILL.
// This must run before launching a child of the same name: deskflow-core
// holds a lock file, sync-receiver holds port 42421, and a duplicate
// launched while the old one is still shutting down exits immediately
// with "already running" / "address already in use".
func killAllAndWait(_ name: String) -> Bool {
    if pids(for: name).isEmpty { return true }
    runAndWait("/usr/bin/pkill", ["-x", name])
    for _ in 0..<30 {
        if pids(for: name).isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    runAndWait("/usr/bin/pkill", ["-9", "-x", name])
    for _ in 0..<20 {
        if pids(for: name).isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let remaining = pids(for: name)
    log("killAllAndWait: \(name) still running: \(remaining)")
    return remaining.isEmpty
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

func backupFile(_ path: String) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    let dst = path + ".bak-syncbar-" + fmt.string(from: Date())
    do { try FileManager.default.copyItem(atPath: path, toPath: dst); log("backed up \(path) -> \(dst)") }
    catch { log("backup failed \(path): \(error)") }
}

func atomicWrite(_ path: String, _ text: String) -> Bool {
    // replaceItemAt requires an existing destination; write directly if
    // the file does not exist yet (fresh Deskflow install).
    if !FileManager.default.fileExists(atPath: path) {
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { log("atomic write failed \(path): \(error)"); return false }
    }
    let tmp = path + ".tmp-syncbar"
    do {
        try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp), backupItemName: nil, options: [])
        return true
    } catch {
        log("atomic write failed \(path): \(error)")
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
}

// This machine's Deskflow computer name: LocalHostName + ".local".
func localComputerName() -> String {
    let hn = runCapture("/usr/sbin/scutil", ["--get", "LocalHostName"])
    if !hn.isEmpty {
        return hn.hasSuffix(".local") ? hn : hn + ".local"
    }
    let fallback = Host.current().localizedName ?? "localhost"
    return fallback.hasSuffix(".local") ? fallback : fallback + ".local"
}

// --- Deskflow.conf parsing (read-only, for migration) ---
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

// Peer name from the server links file: the hostname that is not this machine.
func serverLinksPeerName(local: String) -> String? {
    guard let text = try? String(contentsOfFile: serverConf, encoding: .utf8) else { return nil }
    var names: [String] = []
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasSuffix(":") && !line.hasPrefix("section") {
            let name = String(line.dropLast())
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
    }
    return names.first { $0 != local }
}

// --- Device store (v2.2, 2 devices only) ---
struct Devices {
    var peerName: String
    var peerAddress: String
    var isServer: Bool
}

var devices = Devices(peerName: "", peerAddress: "192.168.66.11", isServer: true)

func saveDevices() {
    do {
        try FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["version": 1, "peerName": devices.peerName, "peerAddress": devices.peerAddress, "isServer": devices.isServer]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: devicesFile), options: [.atomic])
    } catch { log("save devices failed: \(error)") }
}

func loadDevices() {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: devicesFile)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let name = obj["peerName"] as? String,
       let addr = obj["peerAddress"] as? String,
       let server = obj["isServer"] as? Bool,
       !addr.isEmpty {
        devices = Devices(peerName: name.isEmpty ? addr : name, peerAddress: addr, isServer: server)
        log("devices loaded: peer \(devices.peerName) @ \(devices.peerAddress), isServer=\(server)")
        return
    }
    // First v2.2 launch: migrate from the old setup, then save.
    let (mode, host) = deskflowSettings()
    let local = localComputerName()
    let server = (mode != 1)
    var addr = ""
    var name = ""
    if server {
        if let t = try? String(contentsOfFile: targetOverride, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            addr = t
        } else {
            addr = "192.168.66.11"
        }
        name = serverLinksPeerName(local: local) ?? addr
    } else {
        addr = host.isEmpty ? "192.168.66.10" : host
        name = addr
    }
    devices = Devices(peerName: name, peerAddress: addr, isServer: server)
    saveDevices()
    log("devices migrated: peer \(name) @ \(addr), isServer=\(server)")
}

func isIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    for p in parts {
        guard !p.isEmpty, p.allSatisfy({ $0.isNumber }), let v = Int(p), v >= 0, v <= 255 else { return false }
    }
    return true
}

// GUI-default [computer_*] section, with the computer name substituted.
// Copied from what Deskflow GUI creates on a server machine (550xe, 2026).
func computerSectionLines(_ name: String) -> [String] {
    return [
        "[computer_\(name)]",
        "halfDuplexCapsLock=false",
        "halfDuplexNumLock=false",
        "halfDuplexScrollLock=false",
        "modifierAlt=alt",
        "modifierAltGr=altgr",
        "modifierCtrl=ctrl",
        "modifierMeta=meta",
        "modifierShift=shift",
        "modifierSuper=super",
        "name=\(name)",
        "switchCornerBottomLeft=false",
        "switchCornerBottomRight=false",
        "switchCornerSize=0",
        "switchCornerTopLeft=false",
        "switchCornerTopRight=false",
        "xtestIsXineramaUnaware=false",
    ]
}

// --- Deskflow.conf writer (line-preserving) ---
func writeDeskflowConf(isServer: Bool, peerAddress: String) -> Bool {
    let local = localComputerName()
    var lines: [String] = []
    if let text = try? String(contentsOfFile: deskflowConf, encoding: .utf8) {
        lines = text.components(separatedBy: .newlines)
    }
    var section = ""
    var coreModeSeen = false
    var computerNameSeen = false
    var externalConfigSeen = false
    var externalConfigFileSeen = false
    var remoteHostSeen = false
    var out: [String] = []
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
            out.append(line)
            continue
        }
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { out.append(line); continue }
        let key = parts[0]
        if section == "core" && key == "coreMode" {
            coreModeSeen = true
            out.append("coreMode=\(isServer ? 2 : 1)")
            continue
        }
        if section == "core" && key == "computerName" {
            computerNameSeen = true
            out.append(line)
            continue
        }
        if section == "server" && key == "externalConfig" {
            externalConfigSeen = true
            out.append("externalConfig=\(isServer ? "true" : "false")")
            continue
        }
        if section == "server" && key == "externalConfigFile" {
            externalConfigFileSeen = true
            if isServer { out.append("externalConfigFile=\(serverConf)") }
            continue
        }
        if section == "client" && key == "remoteHost" {
            remoteHostSeen = true
            if !isServer { out.append("remoteHost=\(peerAddress)") }
            continue
        }
        out.append(line)
    }
    // Insert missing keys at the end of their section, or create the section.
    func insertIntoSection(_ sectionName: String, _ newLines: [String]) {
        var headerIdx: Int? = nil
        var endIdx = out.count
        for (i, line) in out.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[\(sectionName)]" { headerIdx = i; continue }
            if headerIdx != nil && t.hasPrefix("[") && t.hasSuffix("]") { endIdx = i; break }
        }
        if let h = headerIdx {
            out.insert(contentsOf: newLines, at: endIdx)
            _ = h
        } else {
            if !out.isEmpty && !(out.last?.isEmpty ?? true) { out.append("") }
            out.append("[\(sectionName)]")
            out.append(contentsOf: newLines)
        }
    }
    if !coreModeSeen {
        insertIntoSection("core", ["coreMode=\(isServer ? 2 : 1)"])
    }
    if !computerNameSeen {
        insertIntoSection("core", ["computerName=\(local)"])
    }
    if isServer {
        if !externalConfigSeen {
            insertIntoSection("server", ["externalConfig=true"])
        }
        if !externalConfigFileSeen {
            insertIntoSection("server", ["externalConfigFile=\(serverConf)"])
        }
        // v2.2.1: deskflow-core server requires a [computer_*] section for
        // every computer in the links. A machine that was only ever a client
        // has none, and the server then dies with "unknown computer name".
        for computerName in [local, devices.peerName] {
            let header = "[computer_\(computerName)]"
            if !out.contains(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
                if !out.isEmpty && !(out.last?.isEmpty ?? true) { out.append("") }
                out.append(contentsOf: computerSectionLines(computerName))
            }
        }
    } else {
        if !remoteHostSeen {
            insertIntoSection("client", ["remoteHost=\(peerAddress)"])
        }
    }
    backupFile(deskflowConf)
    let text = out.joined(separator: "\n")
    return atomicWrite(deskflowConf, text)
}

// --- Server links writer (preserves [options] if present) ---
func writeServerConf(local: String, peer: String) -> Bool {
    var optionsLines: [String] = []
    if let text = try? String(contentsOfFile: serverConf, encoding: .utf8) {
        var inOptions = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "section: options" { inOptions = true; continue }
            if inOptions {
                if line == "end" { break }
                optionsLines.append(raw)
            }
        }
    }
    var out = "section: links\n"
    out += "\t\(local):\n"
    out += "\t\tdown = \(peer)\n"
    out += "\t\(peer):\n"
    out += "\t\tup = \(local)\n"
    out += "end\n\n"
    out += "section: options\n"
    for l in optionsLines { out += l + "\n" }
    out += "end\n"
    backupFile(serverConf)
    return atomicWrite(serverConf, out)
}

// Apply the current devices to Deskflow's config files. GUI must already be
// terminated by the caller, or it will overwrite Deskflow.conf on exit.
func applyDevicesToDeskflow() -> Bool {
    let okConf = writeDeskflowConf(isServer: devices.isServer, peerAddress: devices.peerAddress)
    var okServer = true
    if devices.isServer {
        okServer = writeServerConf(local: localComputerName(), peer: devices.peerName)
    }
    log("apply devices: conf=\(okConf) server=\(okServer) peer=\(devices.peerName)@\(devices.peerAddress) isServer=\(devices.isServer)")
    return okConf && okServer
}

func senderTarget() -> String {
    return devices.peerAddress
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var edgeItem: NSMenuItem!
    var broadcastItem: NSMenuItem!
    var statusTextItem: NSMenuItem!
    var receiverItem: NSMenuItem!
    var peerSettingsItem: NSMenuItem!
    var roleMenuItem: NSMenuItem!
    var roleServerItem: NSMenuItem!
    var roleClientItem: NSMenuItem!
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
        loadDevices()
        roleIsServer = devices.isServer
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        edgeItem = NSMenuItem(title: "", action: #selector(toEdge), keyEquivalent: "")
        broadcastItem = NSMenuItem(title: "", action: #selector(toBroadcast), keyEquivalent: "")
        statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        receiverItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        receiverItem.isEnabled = false
        peerSettingsItem = NSMenuItem(title: "", action: #selector(openPeerDialog), keyEquivalent: "")
        peerSettingsItem.target = self
        roleServerItem = NSMenuItem(title: "", action: #selector(toRoleServer), keyEquivalent: "")
        roleClientItem = NSMenuItem(title: "", action: #selector(toRoleClient), keyEquivalent: "")
        roleServerItem.target = self; roleClientItem.target = self
        roleMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let roleMenu = NSMenu()
        roleMenu.addItem(roleServerItem); roleMenu.addItem(roleClientItem)
        roleMenuItem.submenu = roleMenu
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
        menu.addItem(peerSettingsItem); menu.addItem(roleMenuItem)
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
    @objc func toRoleServer() { switchRole(toServer: true) }
    @objc func toRoleClient() { switchRole(toServer: false) }
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
            let peerText = (devices.peerName == devices.peerAddress) ? devices.peerAddress : "\(devices.peerName) \(devices.peerAddress)"
            statusTextItem.title = tr("statusPrefix") + tr(status.key) + " · " + tr("localPrefix") + role + " · " + tr("peerPrefix") + peerText
            receiverItem.title = (receiverProc?.isRunning == true) ? tr("receiverRunning") : tr("receiverStopped")
            peerSettingsItem.title = tr("peerSettings")
            roleMenuItem.title = tr("roleMenu")
            roleServerItem.title = tr("roleServerItem")
            roleClientItem.title = tr("roleClientItem")
            roleServerItem.state = roleIsServer ? .on : .off
            roleClientItem.state = roleIsServer ? .off : .on
            languageMenuItem.title = tr("languageMenu")
            let stored = UserDefaults.standard.string(forKey: "SyncBar.language") ?? "system"
            for (code, item) in languageItems {
                item.state = (code == stored) ? .on : .off
            }
            if let follow = languageItems["system"] { follow.title = tr("followSystem") }
            quitItem.title = tr("quit")
        }
    }

    @objc func openPeerDialog() {
        let alert = NSAlert()
        alert.messageText = tr("peerDialogTitle")
        alert.informativeText = tr("peerDialogInfo")
        alert.addButton(withTitle: tr("saveButton"))
        alert.addButton(withTitle: tr("cancelButton"))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        let nameLabel = NSTextField(labelWithString: tr("peerNameLabel"))
        nameLabel.frame = NSRect(x: 0, y: 38, width: 90, height: 20)
        let nameField = NSTextField(frame: NSRect(x: 95, y: 36, width: 225, height: 24))
        nameField.stringValue = devices.peerName
        let addrLabel = NSTextField(labelWithString: tr("peerAddressLabel"))
        addrLabel.frame = NSRect(x: 0, y: 6, width: 90, height: 20)
        let addrField = NSTextField(frame: NSRect(x: 95, y: 4, width: 225, height: 24))
        addrField.stringValue = devices.peerAddress
        view.addSubview(nameLabel); view.addSubview(nameField)
        view.addSubview(addrLabel); view.addSubview(addrField)
        alert.accessoryView = view
        // Focus the address field, the one users change most often.
        alert.window.initialFirstResponder = addrField
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let addr = addrField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // v2.2.1: the peer name must be a Deskflow computer name, never a
        // bare IP (server links match by computer name). Refuse to save an
        // IP as a name, and only default an empty name to the address when
        // the address is a hostname.
        if name.isEmpty {
            if isIPv4(addr) {
                let warn = NSAlert()
                warn.messageText = tr("peerNameIPTitle")
                warn.informativeText = tr("peerNameIPInfo")
                warn.addButton(withTitle: tr("okButton"))
                warn.runModal()
                return
            }
            name = addr
        }
        if isIPv4(name) {
            let warn = NSAlert()
            warn.messageText = tr("peerNameIPTitle")
            warn.informativeText = tr("peerNameIPInfo")
            warn.addButton(withTitle: tr("okButton"))
            warn.runModal()
            return
        }
        devices.peerAddress = addr
        devices.peerName = name
        saveDevices()
        applyPeerChange()
    }

    // After a peer edit: rewrite configs (GUI already terminated on launch,
    // but terminate again here in case the user opened it since) and
    // auto-restart the active child with the new peer.
    func applyPeerChange() {
        if switching { return }
        switching = true
        updateUI(.switching)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "org.deskflow.deskflow" {
                app.terminate()
            }
            Thread.sleep(forTimeInterval: 1.0)
            _ = applyDevicesToDeskflow()
            roleIsServer = devices.isServer
            if mode == .edge {
                stopProcess(coreProc); coreProc = nil
                if startCore() {
                    switching = false
                    updateUI(.edgeRunning)
                } else {
                    mode = .stopped; switching = false
                    updateUI(.coreExited)
                }
            } else if mode == .broadcast {
                stopProcess(senderProc); senderProc = nil
                if startSender() {
                    switching = false
                    updateUI(.broadcastRunning)
                } else {
                    mode = .stopped; switching = false
                    updateUI(.senderExited)
                }
            } else {
                switching = false
                updateUI(.stopped)
            }
        }
    }

    func switchRole(toServer: Bool) {
        if toServer == roleIsServer && toServer == devices.isServer { return }
        if switching { return }
        switching = true
        devices.isServer = toServer
        roleIsServer = toServer
        saveDevices()
        updateUI(.switching)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "org.deskflow.deskflow" {
                app.terminate()
            }
            Thread.sleep(forTimeInterval: 1.0)
            _ = applyDevicesToDeskflow()
            if mode == .edge {
                stopProcess(coreProc); coreProc = nil
                if startCore() {
                    switching = false
                    updateUI(.edgeRunning)
                } else {
                    mode = .stopped; switching = false
                    updateUI(.coreExited)
                }
            } else {
                // Broadcast target is the peer address in both roles, so a
                // role change alone needs no sender restart.
                switching = false
                updateUI(mode == .broadcast ? .broadcastRunning : .stopped)
            }
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
            var ok = true
            if newMode == .edge {
                stopProcess(senderProc); senderProc = nil
                runAndWait("/usr/bin/pkill", ["-x", "sync-sender"])
                ok = startCore()
            } else if newMode == .broadcast {
                stopProcess(coreProc); coreProc = nil
                runAndWait("/usr/bin/pkill", ["-x", "deskflow-core"])
                ok = startSender()
            }
            switching = false
            if ok {
                updateUI(newMode == .edge ? .edgeRunning : .broadcastRunning)
            } else {
                mode = .stopped
                updateUI(newMode == .edge ? .coreExited : .senderExited)
            }
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

    // v2.2.2: kill-before-start. A tracked child that is already running
    // is fine; an untracked one must be killed and waited out first, or
    // the new child exits immediately on the old one's lock / port.
    @discardableResult func startCore() -> Bool {
        if coreProc?.isRunning == true { return true }
        coreProc = nil
        guard killAllAndWait("deskflow-core") else {
            log("core start aborted: old deskflow-core still running")
            return false
        }
        roleIsServer = devices.isServer
        let arg = devices.isServer ? "server" : "client"
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
        do { try p.run(); coreProc = p; senderProc = nil; log("core \(arg) started pid \(p.processIdentifier)"); return true }
        catch { log("core start failed: \(error)"); return false }
    }

    @discardableResult func startSender() -> Bool {
        if senderProc?.isRunning == true { return true }
        senderProc = nil
        guard killAllAndWait("sync-sender") else {
            log("sender start aborted: old sync-sender still running")
            return false
        }
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
        do { try p.run(); senderProc = p; coreProc = nil; log("sender -> \(target) pid \(p.processIdentifier)"); return true }
        catch { log("sender start failed: \(error)"); return false }
    }

    @discardableResult func startReceiver() -> Bool {
        guard FileManager.default.fileExists(atPath: receiverPath) else {
            log("receiver missing at \(receiverPath), skipping"); return false
        }
        if receiverProc?.isRunning == true { return true }
        receiverProc = nil
        guard killAllAndWait("sync-receiver") else {
            log("receiver start aborted: old sync-receiver still running")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: receiverPath)
        p.arguments = []
        if let out = appendHandle(receiverLog) { p.standardOutput = out; p.standardError = out }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.receiverProc = nil; self?.updateUI(.receiverRestarting) }
        }
        do { try p.run(); receiverProc = p; log("receiver started pid \(p.processIdentifier)"); return true }
        catch { log("receiver start failed: \(error)"); return false }
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

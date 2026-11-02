# SyncBar

A small macOS menu-bar tool that sits next to [Deskflow](https://github.com/deskflow/deskflow)
and gives you two input-sharing modes, switched with a click — no hotkey,
no Deskflow source patch, no bundle re-signing.

- **Edge switching** (Deskflow): move the server machine's mouse off one
  screen edge and it appears on the other machine. This is stock Deskflow.
- **Broadcast**: every key, click, wheel event and mouse move on the
  sending machine is also delivered to the other machine, while still
  working locally. This is what stock Deskflow cannot do (see below).

SyncBar owns the mode switch. It never runs both sending paths at once on
the same machine.

## Why this exists

Stock Deskflow 1.27.0 was evaluated first and kept for edge switching, but:

- It has **keyboard broadcast only, no mouse broadcast**. The keyboard
  broadcast itself was broken in stock: with broadcasting on and no
  computer list, `Server::onKeyDown`/`onKeyUp` fell back to an empty
  computer string, and `IKeyState::KeyInfo::contains("", name)` is false,
  so the key was sent to nobody. No config or hotkey workaround fixes it.
- Patching Deskflow's core and swapping it inside the Developer-ID-signed
  bundle broke its identity for macOS Accessibility (TCC): the system
  kept prompting for "Deskflow" even though access was already granted,
  because the grant did not match the swapped binary. Fixed-certificate
  re-signing of the core alone did not fix the loop.
- Deskflow's GUI hotkey dialog cannot set the `keyboardBroadcast` action;
  it only works through an external server config file.

So instead of fighting the bundle, SyncBar keeps stock Deskflow untouched
for edge mode and adds a separate, independently signed sender/receiver
pair for broadcast mode. The two paths are mutually exclusive per machine.

## Architecture

```
550xe (Deskflow server)                 c8dh (Deskflow client)
┌─────────────────────────┐             ┌─────────────────────────┐
│ SyncBar (menu bar)      │             │ SyncBar (menu bar)      │
│  ├─ Edge: deskflow-core │◄──TLS─────►│  ├─ Edge: deskflow-core │
│  │   server             │  :24800     │  │   client              │
│  ├─ Broadcast:          │             │  ├─ Broadcast:          │
│  │   sync-sender ───────┼──TCP───────►│  │   sync-sender ────────┼──► (to 550xe)
│  └─ Receiver: always on │◄──TCP───────┤  └─ Receiver: always on │
│      sync-receiver      │  :42421     │      sync-receiver      │
└─────────────────────────┘             └─────────────────────────┘
```

Components (all in this repo):

| File | What it is |
| --- | --- |
| `SyncBar/main.swift`, `SyncBar/Info.plist` | Menu-bar app (Swift/AppKit, `LSUIElement`, no Dock icon). |
| `sync-helper/sender.c` | Broadcast sender. `CGEventTap` captures global key/mouse, forwards over TCP, passes every event through locally. |
| `sync-helper/receiver.c` | Broadcast receiver. Listens on TCP 42421, injects events with `CGEventPost`. |

SyncBar itself captures no input and, in theory, needs no Accessibility
grant. In practice macOS attributes its children's event taps to it, so
**SyncBar itself must be granted Accessibility (and Input Monitoring)
once per machine**, exactly like any app that launches an input tool.
Without that grant, children launched by SyncBar fail their tap check
silently — macOS does not prompt for background-launched children.

### The loop guard

The receiver posts to `kCGSessionEventTap`, not `kCGHIDEventTap`, on
purpose. A sender's HID tap never sees session-posted events, so even
if both machines broadcast at once, an injected event is never forwarded
back. Both-broadcast is therefore safe: only the machine whose physical
input you are actually using sends anything.

### Mode rules (learned the hard way, please read before use)

1. **Edge works only when both machines are in Edge mode.** The server
   (550xe) needs a client (c8dh) to switch to. If either side leaves Edge
   for Broadcast, its Deskflow core stops and Edge breaks for both sides
   until both return to Edge. This is mutual exclusion by design, not a bug.
2. **Broadcast captures only the sending machine's local devices.**
   A sender sees only the keyboard/mouse physically connected to its own
   machine. It does not see the other machine's devices, and it does not
   see Deskflow-forwarded input.
3. **Edge roles are fixed: 550xe is server, c8dh is client.**
   Only the server machine's mouse can cross screens. A mouse plugged
   into the client does nothing for Edge switching. Swapping roles means
   swapping the Deskflow server/client configuration on both machines;
   SyncBar does not do that.
4. **Do not open the Deskflow GUI while SyncBar runs.** The GUI's
   close-to-tray behaviour means quitting it may only hide it, and
   clicking Start in it would launch a second core next to SyncBar's.
   SyncBar quits the GUI on takeover; leave it closed.
5. **Do not test broadcast with a synced Notes document.** A note open
   under the same Apple ID on both machines can be locked by iCloud on
   one side, which looks exactly like "keyboard broadcast failed" when
   the broadcast itself is fine. Test with a local text field, TextEdit,
   or a terminal instead.

## Repository layout

```
SyncBar/
├── SyncBar/
│   ├── main.swift      # menu-bar app, v2
│   └── Info.plist      # LSUIElement, bundle id com.grayson.SyncBar
├── sync-helper/
│   ├── sender.c        # broadcast sender
│   └── receiver.c      # broadcast receiver (session-tap posting)
├── README.md
├── LICENSE
└── .gitignore
```

Binaries, `.app` bundles, logs, signing certificates and private keys
are never committed (see `.gitignore`).

## Build

Requires Xcode command-line tools on an Intel Mac (`swiftc`, `clang`).
No Homebrew, no Qt, no third-party dependencies.

```sh
# Broadcast pair (pure C, system frameworks only)
clang -O2 -framework CoreGraphics -framework CoreFoundation \
  -framework ApplicationServices -o sync-sender sender.c
clang -O2 -framework CoreGraphics -framework CoreFoundation \
  -framework ApplicationServices -o sync-receiver receiver.c

# Menu-bar app (Swift/AppKit)
mkdir -p SyncBar.app/Contents/MacOS
cp SyncBar/Info.plist SyncBar.app/Contents/
swiftc -O -o SyncBar.app/Contents/MacOS/SyncBar SyncBar/main.swift
```

Copy the built `SyncBar.app` to `~/Applications/` and the two helper
binaries to `~/sync-helper/` on each machine.

## Sign

Binaries must be signed with a stable identity, otherwise every rebuild
changes the identity macOS uses for its Accessibility grant and the
grant stops matching. Sign once per rebuild, in a GUI Terminal on the
machine that built them (SSH sessions cannot reach the login keychain,
so signing over SSH fails with "item could not be found in the keychain"):

```sh
codesign --force --sign "Deskflow Patch Signing" \
  --identifier sync-sender --timestamp=none ~/sync-helper/sync-sender
codesign --force --sign "Deskflow Patch Signing" \
  --identifier sync-receiver --timestamp=none ~/sync-helper/sync-receiver
codesign --force --sign "Deskflow Patch Signing" \
  --identifier com.grayson.SyncBar ~/Applications/SyncBar.app
```

Identifiers must not change between rebuilds: `sync-sender`,
`sync-receiver`, `com.grayson.SyncBar`. Signed binaries can then be
copied to the other machine; their signatures travel with them, but
**Accessibility grants are per machine** and must be given once on each
machine (see Deploy).

## Deploy

On each machine, in order:

1. Install stock Deskflow 1.27.0 and confirm edge switching works with
   its GUI first (server on 550xe, client on c8dh, default Barrier
   protocol, TLS fingerprint trusted). Then stop Deskflow before
   switching to SyncBar.
2. Copy `SyncBar.app` to `~/Applications/` and `sync-sender` /
   `sync-receiver` to `~/sync-helper/`. Sign as above if freshly built.
3. System Settings → Privacy & Security → Accessibility: add
   `~/Applications/SyncBar.app` and turn it on. Do the same under Input
   Monitoring. If a child still fails its tap check, add
   `~/sync-helper/sync-sender` (and `sync-receiver`) the same way.
   Note: the file picker defaults to system `/Applications`; SyncBar
   lives in your home `~/Applications`, so navigate there explicitly.
4. Launch SyncBar from Finder (double-click `~/Applications/SyncBar.app`;
   launching a menu-bar app over SSH is unreliable). It starts in Edge
   mode by default, starts the receiver, and quits the Deskflow GUI.
5. The menu bar shows `⇄ 边缘` (Edge), `📡 同步` (Broadcast) or
   `○ 停止` (Stopped). The menu shows the checked mode, a status line
   (`本机 服务端/客户端 · 对端 <IP>`), a receiver line (`接收端：运行中`),
   and Quit. Clicking the already-active mode does nothing; clicking
   the other mode stops the current sender/core first, then starts the
   new one. If a child dies, the menu falls back to `○ 停止` with the
   reason in the status line; clicking the mode restarts it.
6. Receiver logs: `~/sync-helper/syncbar-receiver.log`;
   sender log: `~/sync-helper/syncbar-sender.log`;
   Deskflow core log: `~/sync-helper/syncbar-core.log`.

Edge identity comes from Deskflow's own config, not from SyncBar:
SyncBar reads `~/Library/Deskflow/Deskflow.conf` — `coreMode=2` starts
`deskflow-core server`, `coreMode=1` starts `deskflow-core client`.
Broadcast target: a client machine uses the conf's `remoteHost`; a
server machine uses `~/sync-helper/syncbar-target.txt` if present, else
the default `192.168.66.11`. Change that file (or the default in
`main.swift`) if your machines use different LAN addresses.

## Usage

- Both machines on Edge: move the server mouse off the bottom edge of
  550xe to reach c8dh, off the top edge of c8dh to return. (Current
  links: 550xe down = c8dh, c8dh up = 550xe.)
- One machine on Broadcast: use that machine's own keyboard/mouse;
  its input appears on the other machine as well as locally. The other
  machine's mode does not matter for broadcast, because its receiver is
  always on — but Edge will be off until both return to Edge.
- Both machines on Broadcast: safe (see loop guard), only the machine
  with the physical input in use actually sends.
- To stop broadcasting: switch that machine back to Edge, or quit
  SyncBar (Quit stops sender, core and receiver on that machine).

## Testing matrix (all verified 2026-11-01, macOS 15.8.2)

| Test | Result |
| --- | --- |
| Stock `deskflow-core server` launched directly (no GUI) | Binds :24800, reads `deskflow-server.conf`, c8dh client connects in <1 s, no Accessibility error. This is what SyncBar's Edge mode relies on. |
| Edge, both machines on Edge, server mouse | Cross-screen switching works both directions (550xe down → c8dh, c8dh up → 550xe). Client physical mouse does not switch (expected, see mode rules). |
| Broadcast 550xe → c8dh (mouse, click, wheel, typing) | Works. |
| Broadcast c8dh → 550xe (mouse, click, wheel, typing) | Works, once the keyboard/mouse are physically on c8dh. Tested with a local text field, not a synced Notes document (see mode rules). |
| Both machines on Broadcast at once | No echo loop (session-tap guard). |
| SyncBar-launched children without a SyncBar Accessibility grant | Both sender and Deskflow core fail their tap check (`CGEventTapCreate` failed / `process is not trusted anymore`) and exit; SyncBar falls back to Stopped. Fixed by manually granting SyncBar (no prompt appears for its children). |

## Languages

SyncBar v2.1 and later support six languages: Chinese, English,
Japanese, French, German and Spanish. Strings live in code
(`SyncBar/main.swift`, `STR` table), not in `.lproj` bundles, so the
menu can switch language without restarting.

- Default is **Follow System**: the OS preferred language is used if it
  is one of the six, otherwise English.
- Or pick a language explicitly from the menu: `语言 / Language` →
  `中文 / English / 日本語 / Français / Deutsch / Español`.
  The choice is saved and restored on launch.
- Language names in the menu are always shown in their own language,
  so the menu is usable even before you understand the current one.

## Version history

- **v1 (2026-11-01)**: Menu-bar app on 550xe only. Two modes, sender
  only on 550xe, no receiver management, no toggle hotkey (the earlier
  Ctrl+Shift+F12 Deskflow hotkey idea was abandoned in favour of the
  menu). Stopping broadcast meant Ctrl+C in a terminal or killing the
  sender.
- **v2 (2026-11-01)**: Dual-ended. SyncBar, sender and receiver
  on both machines; receiver always on; Edge mode read from
  `Deskflow.conf` (server/client per machine); broadcast target per
  machine; receiver posts to the session tap (loop guard); menu shows
  role, peer IP and receiver status.
- **v2.1 (2026-11-01, current)**: Multilingual UI. Chinese, English,
  Japanese, French, German and Spanish, with a Follow System option and
  a Language submenu in the menu bar. No functional change to Edge or
  Broadcast behaviour.

## Troubleshooting

- **Menu shows `○ 停止` after switching**: read the status line, then
  the corresponding `syncbar-*.log`. The usual cause is a missing
  Accessibility grant for SyncBar (see Deploy step 3) — grant it, then
  click the mode again to restart the child.
- **Broadcast "does nothing"**: check (a) both machines' SyncBar modes,
  (b) that the keyboard/mouse you are using are physically connected to
  the sending machine, (c) that the receiving machine's receiver is
  running (`接收端：运行中`), and (d) that you are not testing in a
  synced Notes document.
- **Edge "does nothing"**: check that both machines are on Edge. If
  either side is on Broadcast, Edge is off by design.
- **Two SyncBar icons / two cores**: an old SyncBar is still running,
  or the Deskflow GUI was reopened and its Start clicked. Quit the old
  SyncBar and leave the Deskflow GUI closed.
- **Signing fails over SSH**: sign in a GUI Terminal on the build
  machine (see Sign). SSH sessions cannot use the login keychain.

## License

MIT. See `LICENSE`.

/* sync-receiver: c8dh side of the broadcast helper, v2 (SyncBar v2.4.1).
 * v2 change: drags are posted as real Dragged events, not MouseMoved.
 * v1 posted every move as kCGEventMouseMoved, so drag-and-drop and
 * Launchpad drag-to-switch-page never worked: macOS requires a
 * Dragged event type, not just a held button plus a Moved event.
 * Listens on TCP, injects received key/mouse events via CGEventPost.
 * Posts to kCGSessionEventTap (not HID) on purpose: a HID tap (which
 * sync-sender uses) does not see session-posted events, so if both
 * machines ever broadcast at once, injected events are not forwarded
 * back and cannot loop forever.
 * No Deskflow involvement. STOP Deskflow on both machines first.
 * Usage: sync-receiver [port, default 42421]
 * Signing: codesign --sign "Deskflow Patch Signing"
 *          --identifier sync-receiver  (stable, do not change)
 */
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <arpa/inet.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define PORT_DEFAULT 42421
#define MSG_KEY_DOWN 1
#define MSG_KEY_UP 2
#define MSG_MOUSE_MOVE 3
#define MSG_MOUSE_DOWN 4
#define MSG_MOUSE_UP 5
#define MSG_SCROLL 6
#define MSG_FLAGS 7
#define MSG_HANDSHAKE 8
#define MSG_MOUSE_DRAG 9
/* Protocol v2: 1-8 are v1-compatible, 9 is new. A v2 receiver still
 * accepts v1 MOVE messages (see button-state fallback in
 * post_mouse_move), so a v1 sender keeps working with a v2 receiver
 * except drags still arrive as moves. A v1 receiver drops a v2
 * sender on the unknown type 9, so deploy v2 receivers first. */

static CGEventSourceRef g_src = NULL;
static double g_cur_x = 0, g_cur_y = 0;
static int g_screen_w = 0, g_screen_h = 0;
/* Button currently held down on the receiver side, or -1 if none.
 * Used only as a fallback: a plain MOVE that arrives while a button
 * is down is re-posted as a Dragged event. */
static int g_btn_down = -1;

static bool recv_all(int fd, void *buf, size_t len) {
  uint8_t *p = buf;
  while (len > 0) {
    ssize_t n = recv(fd, p, len, 0);
    if (n <= 0) return false;
    p += n; len -= (size_t)n;
  }
  return true;
}
static bool send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = buf;
  while (len > 0) {
    ssize_t n = send(fd, p, len, 0);
    if (n <= 0) return false;
    p += n; len -= (size_t)n;
  }
  return true;
}
static uint16_t get_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint64_t get_u64(const uint8_t *p) { uint64_t v = 0; for (int i = 0; i < 8; i++) v |= ((uint64_t)p[i] << (8*i)); return v; }
static int32_t get_i32(const uint8_t *p) { uint32_t u = 0; for (int i = 0; i < 4; i++) u |= ((uint32_t)p[i] << (8*i)); return (int32_t)u; }
static void put_i32(uint8_t *p, int32_t v) { uint32_t u = (uint32_t)v; for (int i = 0; i < 4; i++) p[i] = (u >> (8*i)) & 0xff; }

static void post_key(uint16_t code, bool down, uint64_t flags) {
  CGEventRef e = CGEventCreateKeyboardEvent(g_src, (CGKeyCode)code, down);
  if (!e) return;
  CGEventSetFlags(e, (CGEventFlags)flags);
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
static void post_flags(uint16_t code, uint64_t flags) {
  CGEventRef e = CGEventCreateKeyboardEvent(g_src, (CGKeyCode)code, false);
  if (!e) return;
  /* flagsChanged events carry the new modifier state */
  CGEventSetType(e, kCGEventFlagsChanged);
  CGEventSetFlags(e, (CGEventFlags)flags);
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
static void clamp_xy(int32_t *x, int32_t *y) {
  if (*x < 0) *x = 0; if (*y < 0) *y = 0;
  if (g_screen_w > 0 && *x >= g_screen_w) *x = g_screen_w - 1;
  if (g_screen_h > 0 && *y >= g_screen_h) *y = g_screen_h - 1;
}
static CGMouseButton btn_to_cg(uint8_t btn) {
  return (btn == 1) ? kCGMouseButtonRight : (btn == 2) ? kCGMouseButtonCenter : kCGMouseButtonLeft;
}
static void post_mouse_move(int32_t x, int32_t y) {
  clamp_xy(&x, &y);
  g_cur_x = x; g_cur_y = y;
  CGPoint pt = CGPointMake(x, y);
  /* Fallback for v1 senders: a move while a button is down is a drag,
   * even though v1 labelled it a plain move. */
  CGEventType t;
  CGMouseButton b;
  if (g_btn_down >= 0) {
    b = btn_to_cg((uint8_t)g_btn_down);
    t = (g_btn_down == 1) ? kCGEventRightMouseDragged : (g_btn_down == 2) ? kCGEventOtherMouseDragged : kCGEventLeftMouseDragged;
  } else {
    b = kCGMouseButtonLeft; t = kCGEventMouseMoved;
  }
  CGEventRef e = CGEventCreateMouseEvent(g_src, t, pt, b);
  if (!e) return;
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
static void post_mouse_drag(uint8_t btn, int32_t x, int32_t y) {
  clamp_xy(&x, &y);
  g_cur_x = x; g_cur_y = y;
  CGPoint pt = CGPointMake(x, y);
  CGEventType t = (btn == 1) ? kCGEventRightMouseDragged : (btn == 2) ? kCGEventOtherMouseDragged : kCGEventLeftMouseDragged;
  CGEventRef e = CGEventCreateMouseEvent(g_src, t, pt, btn_to_cg(btn));
  if (!e) return;
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
static void post_mouse_btn(uint8_t btn, bool down) {
  CGEventType dt, ut; CGMouseButton b;
  if (btn == 0) { dt = kCGEventLeftMouseDown; ut = kCGEventLeftMouseUp; b = kCGMouseButtonLeft; }
  else if (btn == 1) { dt = kCGEventRightMouseDown; ut = kCGEventRightMouseUp; b = kCGMouseButtonRight; }
  else { dt = kCGEventOtherMouseDown; ut = kCGEventOtherMouseUp; b = kCGMouseButtonCenter; }
  if (down) g_btn_down = btn; else if (g_btn_down == (int)btn) g_btn_down = -1;
  CGPoint pt = CGPointMake(g_cur_x, g_cur_y);
  CGEventRef e = CGEventCreateMouseEvent(g_src, down ? dt : ut, pt, b);
  if (!e) return;
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
static void post_scroll(int32_t dx, int32_t dy) {
  CGEventRef e;
  if (dx != 0) {
    e = CGEventCreateScrollWheelEvent(g_src, kCGScrollEventUnitPixel, 2, dy, dx);
  } else {
    e = CGEventCreateScrollWheelEvent(g_src, kCGScrollEventUnitPixel, 1, dy);
  }
  if (!e) return;
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}

static void handle_client(int fd) {
  fprintf(stderr, "[receiver] client connected\n");
  for (;;) {
    uint8_t type;
    if (!recv_all(fd, &type, 1)) break;
    switch (type) {
      case MSG_KEY_DOWN: case MSG_KEY_UP: case MSG_FLAGS: {
        uint8_t buf[10];
        if (!recv_all(fd, buf, sizeof buf)) goto done;
        uint16_t code = get_u16(buf); uint64_t flags = get_u64(buf+2);
        if (type == MSG_KEY_DOWN) post_key(code, true, flags);
        else if (type == MSG_KEY_UP) post_key(code, false, flags);
        else post_flags(code, flags);
        break;
      }
      case MSG_MOUSE_MOVE: {
        uint8_t buf[8];
        if (!recv_all(fd, buf, sizeof buf)) goto done;
        post_mouse_move(get_i32(buf), get_i32(buf+4));
        break;
      }
      case MSG_MOUSE_DRAG: {
        uint8_t buf[9];
        if (!recv_all(fd, buf, sizeof buf)) goto done;
        post_mouse_drag(buf[0], get_i32(buf+1), get_i32(buf+5));
        break;
      }
      case MSG_MOUSE_DOWN: case MSG_MOUSE_UP: {
        uint8_t btn;
        if (!recv_all(fd, &btn, 1)) goto done;
        post_mouse_btn(btn, type == MSG_MOUSE_DOWN);
        break;
      }
      case MSG_SCROLL: {
        uint8_t buf[8];
        if (!recv_all(fd, buf, sizeof buf)) goto done;
        post_scroll(get_i32(buf), get_i32(buf+4));
        break;
      }
      default:
        fprintf(stderr, "[receiver] unknown message type %d, dropping connection\n", type);
        goto done;
    }
  }
done:
  g_btn_down = -1;
  close(fd);
  fprintf(stderr, "[receiver] client disconnected\n");
}

int main(int argc, char **argv) {
  int port = PORT_DEFAULT;
  if (argc >= 2) port = atoi(argv[1]);
  CGRect bounds = CGDisplayBounds(CGMainDisplayID());
  g_screen_w = (int)bounds.size.width; g_screen_h = (int)bounds.size.height;
  g_cur_x = g_screen_w / 2; g_cur_y = g_screen_h / 2;
  g_src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  fprintf(stderr, "[receiver] sync-helper v2, protocol v2, listening on %d, screen %dx%d\n", port, g_screen_w, g_screen_h);
  fprintf(stderr, "[receiver] STOP Deskflow on both machines before using this, or input may double.\n");
  int ls = socket(AF_INET, SOCK_STREAM, 0);
  if (ls < 0) { perror("socket"); return 1; }
  int one = 1; setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr; memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons(port);
  if (bind(ls, (struct sockaddr *)&addr, sizeof addr) < 0) { perror("bind"); return 1; }
  if (listen(ls, 4) < 0) { perror("listen"); return 1; }
  for (;;) {
    int fd = accept(ls, NULL, NULL);
    if (fd < 0) continue;
    /* handshake: sender sends its screen size, we reply with ours */
    uint8_t hs[9];
    if (!recv_all(fd, hs, sizeof hs) || hs[0] != MSG_HANDSHAKE) { close(fd); continue; }
    int sw = get_i32(hs+1), sh = get_i32(hs+5);
    fprintf(stderr, "[receiver] handshake, sender screen %dx%d\n", sw, sh);
    uint8_t rh[9]; rh[0] = MSG_HANDSHAKE; put_i32(rh+1, g_screen_w); put_i32(rh+5, g_screen_h);
    if (!send_all(fd, rh, sizeof rh)) { close(fd); continue; }
    handle_client(fd);
  }
  return 0;
}

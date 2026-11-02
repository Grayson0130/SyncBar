/* sync-sender: 550xe -> c8dh broadcast helper, v2 (SyncBar v2.4.1).
 * v2 change: mouse drags are no longer collapsed into plain moves.
 * Dragged events are sent as MSG_MOUSE_DRAG so the receiver can post
 * a real Dragged event; v1 sent every move/drag as MSG_MOUSE_MOVE and
 * drag-and-drop / Launchpad drag-to-switch-page never worked.
 * Captures global key/mouse via CGEventTap, forwards over TCP to
 * sync-receiver on c8dh, and passes every event through locally
 * (returning the event), so the local machine keeps working.
 * No Deskflow involvement. Stop this program to stop broadcasting.
 * Usage: sync-sender <receiver-host> [port, default 42421]
 * The sender must run in a GUI Terminal session so macOS can show
 * the Accessibility / Input Monitoring prompt for THIS binary.
 * Signing: codesign --sign "Deskflow Patch Signing"
 *          --identifier sync-sender  (stable, do not change)
 */
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

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
/* Protocol v2: 1-8 are v1-compatible. 9 is new in v2; an old v1 receiver
 * drops the connection on an unknown type, so deploy the v2 receiver
 * on both machines BEFORE deploying the v2 sender. */

static int g_sock = -1;
static pthread_mutex_t g_sock_mu = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_connected = 0;
static char g_host[256] = "192.168.66.11";
static int g_port = PORT_DEFAULT;
static double g_scale_x = 1.0, g_scale_y = 1.0;
static volatile int g_handshake_done = 0;
static double g_last_x = 0, g_last_y = 0;
static int g_screen_w = 0, g_screen_h = 0;

static bool send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = buf;
  while (len > 0) {
    ssize_t n = send(fd, p, len, 0);
    if (n <= 0) return false;
    p += n; len -= (size_t)n;
  }
  return true;
}
static bool recv_all(int fd, void *buf, size_t len) {
  uint8_t *p = buf;
  while (len > 0) {
    ssize_t n = recv(fd, p, len, 0);
    if (n <= 0) return false;
    p += n; len -= (size_t)n;
  }
  return true;
}
static void put_u16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (v >> (8*i)) & 0xff; }
static void put_i32(uint8_t *p, int32_t v) { uint32_t u = (uint32_t)v; for (int i = 0; i < 4; i++) p[i] = (u >> (8*i)) & 0xff; }
static uint16_t get_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static int32_t get_i32(const uint8_t *p) { uint32_t u = 0; for (int i = 0; i < 4; i++) u |= ((uint32_t)p[i] << (8*i)); return (int32_t)u; }

/* Send one message; on failure mark disconnected. Thread-safe. */
static void send_msg(const uint8_t *msg, size_t len) {
  pthread_mutex_lock(&g_sock_mu);
  int fd = g_sock;
  if (fd >= 0 && g_handshake_done) {
    if (!send_all(fd, msg, len)) {
      close(fd); g_sock = -1; g_connected = 0; g_handshake_done = 0;
      fprintf(stderr, "[sender] connection lost, will reconnect\n");
    }
  }
  pthread_mutex_unlock(&g_sock_mu);
}

static void *connect_thread(void *arg) {
  (void)arg;
  for (;;) {
    pthread_mutex_lock(&g_sock_mu);
    int already = (g_sock >= 0);
    pthread_mutex_unlock(&g_sock_mu);
    if (!already) {
      struct addrinfo hints; memset(&hints, 0, sizeof hints);
      hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
      char portstr[16]; snprintf(portstr, sizeof portstr, "%d", g_port);
      struct addrinfo *res = NULL;
      if (getaddrinfo(g_host, portstr, &hints, &res) == 0 && res) {
        int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd >= 0 && connect(fd, res->ai_addr, res->ai_addrlen) == 0) {
          uint8_t hs[9]; hs[0] = MSG_HANDSHAKE;
          put_i32(hs+1, g_screen_w); put_i32(hs+5, g_screen_h);
          if (send_all(fd, hs, sizeof hs)) {
            uint8_t rh[9];
            if (recv_all(fd, rh, sizeof rh) && rh[0] == MSG_HANDSHAKE) {
              int rw = get_i32(rh+1), rhgt = get_i32(rh+5);
              if (g_screen_w > 0 && g_screen_h > 0 && rw > 0 && rhgt > 0) {
                g_scale_x = (double)rw / (double)g_screen_w;
                g_scale_y = (double)rhgt / (double)g_screen_h;
              }
              pthread_mutex_lock(&g_sock_mu);
              g_sock = fd; g_connected = 1; g_handshake_done = 1;
              pthread_mutex_unlock(&g_sock_mu);
              fprintf(stderr, "[sender] connected to %s:%d, receiver %dx%d, scale %.3f x %.3f\n",
                      g_host, g_port, rw, rhgt, g_scale_x, g_scale_y);
              /* warp receiver to current (scaled) mouse position */
              uint8_t mv[9]; mv[0] = MSG_MOUSE_MOVE;
              put_i32(mv+1, (int32_t)(g_last_x * g_scale_x));
              put_i32(mv+5, (int32_t)(g_last_y * g_scale_y));
              send_msg(mv, sizeof mv);
            } else { close(fd); }
          } else { close(fd); }
        } else if (fd >= 0) close(fd);
        if (res) freeaddrinfo(res);
      }
    }
    sleep(2);
  }
  return NULL;
}

static CFMachPortRef g_tap = NULL;
static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
  (void)proxy; (void)refcon;
  if (type == kCGEventTapDisabledByTimeout) {
    if (g_tap) CGEventTapEnable(g_tap, true);
    return event;
  }
  switch (type) {
    case kCGEventKeyDown: {
      uint8_t m[11]; m[0] = MSG_KEY_DOWN;
      put_u16(m+1, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
      put_u64(m+3, (uint64_t)CGEventGetFlags(event));
      send_msg(m, sizeof m); break;
    }
    case kCGEventKeyUp: {
      uint8_t m[11]; m[0] = MSG_KEY_UP;
      put_u16(m+1, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
      put_u64(m+3, (uint64_t)CGEventGetFlags(event));
      send_msg(m, sizeof m); break;
    }
    case kCGEventFlagsChanged: {
      uint8_t m[11]; m[0] = MSG_FLAGS;
      put_u16(m+1, (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
      put_u64(m+3, (uint64_t)CGEventGetFlags(event));
      send_msg(m, sizeof m); break;
    }
    case kCGEventMouseMoved: {
      CGPoint pt = CGEventGetLocation(event);
      g_last_x = pt.x; g_last_y = pt.y;
      uint8_t m[9]; m[0] = MSG_MOUSE_MOVE;
      put_i32(m+1, (int32_t)(pt.x * g_scale_x));
      put_i32(m+5, (int32_t)(pt.y * g_scale_y));
      send_msg(m, sizeof m); break;
    }
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
      CGPoint pt = CGEventGetLocation(event);
      g_last_x = pt.x; g_last_y = pt.y;
      uint8_t btn = (type == kCGEventLeftMouseDragged) ? 0 : (type == kCGEventRightMouseDragged) ? 1 : 2;
      uint8_t m[10]; m[0] = MSG_MOUSE_DRAG; m[1] = btn;
      put_i32(m+2, (int32_t)(pt.x * g_scale_x));
      put_i32(m+6, (int32_t)(pt.y * g_scale_y));
      send_msg(m, sizeof m); break;
    }
    case kCGEventLeftMouseDown:
    case kCGEventRightMouseDown:
    case kCGEventOtherMouseDown: {
      uint8_t btn = (type == kCGEventLeftMouseDown) ? 0 : (type == kCGEventRightMouseDown) ? 1 : 2;
      /* Sync the receiver cursor to the exact Down position first:
       * v1 Down carried no coordinates and relied on the last Move,
       * which is wrong for a press with no preceding move. */
      CGPoint pt = CGEventGetLocation(event);
      g_last_x = pt.x; g_last_y = pt.y;
      uint8_t mv[9]; mv[0] = MSG_MOUSE_MOVE;
      put_i32(mv+1, (int32_t)(pt.x * g_scale_x));
      put_i32(mv+5, (int32_t)(pt.y * g_scale_y));
      send_msg(mv, sizeof mv);
      uint8_t m[2]; m[0] = MSG_MOUSE_DOWN; m[1] = btn;
      send_msg(m, sizeof m); break;
    }
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseUp:
    case kCGEventOtherMouseUp: {
      uint8_t btn = (type == kCGEventLeftMouseUp) ? 0 : (type == kCGEventRightMouseUp) ? 1 : 2;
      CGPoint pt = CGEventGetLocation(event);
      g_last_x = pt.x; g_last_y = pt.y;
      uint8_t mv[9]; mv[0] = MSG_MOUSE_MOVE;
      put_i32(mv+1, (int32_t)(pt.x * g_scale_x));
      put_i32(mv+5, (int32_t)(pt.y * g_scale_y));
      send_msg(mv, sizeof mv);
      uint8_t m[2]; m[0] = MSG_MOUSE_UP; m[1] = btn;
      send_msg(m, sizeof m); break;
    }
    case kCGEventScrollWheel: {
      int64_t dx = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
      int64_t dy = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
      uint8_t m[9]; m[0] = MSG_SCROLL;
      put_i32(m+1, (int32_t)dx); put_i32(m+5, (int32_t)dy);
      send_msg(m, sizeof m); break;
    }
    default: break;
  }
  return event; /* pass through locally */
}

int main(int argc, char **argv) {
  if (argc >= 2) { strncpy(g_host, argv[1], sizeof g_host - 1); }
  if (argc >= 3) { g_port = atoi(argv[2]); }
  CGRect bounds = CGDisplayBounds(CGMainDisplayID());
  g_screen_w = (int)bounds.size.width; g_screen_h = (int)bounds.size.height;
  fprintf(stderr, "[sender] sync-helper v2, protocol v2, local screen %dx%d, receiver %s:%d\n", g_screen_w, g_screen_h, g_host, g_port);
  fprintf(stderr, "[sender] STOP Deskflow on both machines before using this, or input may double.\n");
  if (!AXIsProcessTrusted()) {
    fprintf(stderr, "[sender] NOTE: not yet trusted for Accessibility. macOS should prompt; if not, add this binary in System Settings > Privacy & Security > Accessibility, then restart it.\n");
  }
  pthread_t th; pthread_create(&th, NULL, connect_thread, NULL);
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
    CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventMouseMoved) |
    CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged) |
    CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventLeftMouseDown) |
    CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventOtherMouseDown) |
    CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseUp) |
    CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventScrollWheel);
  CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, tap_callback, NULL);
  g_tap = tap;
  if (!tap) {
    fprintf(stderr, "[sender] FATAL: CGEventTapCreate failed (Accessibility / Input Monitoring not granted?). Grant it, then restart.\n");
    return 1;
  }
  CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
  CGEventTapEnable(tap, true);
  fprintf(stderr, "[sender] event tap running. Ctrl+C to stop broadcasting.\n");
  CFRunLoopRun();
  return 0;
}

// Physical keyboard input using a stable XKB map. wtype's per-string keymap
// cannot represent compositor bindings such as Hyprland's code:21.
// Wire interface: wlroots virtual-keyboard-unstable-v1, version 1.
#define _GNU_SOURCE
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <sys/mman.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const struct wl_interface keyboard_interface;
static const struct wl_interface *create_types[] = { &wl_seat_interface, &keyboard_interface };
static const struct wl_message manager_requests[] = { { "create_virtual_keyboard", "on", create_types } };
static const struct wl_interface manager_interface = { "zwp_virtual_keyboard_manager_v1", 1, 1, manager_requests, 0, NULL };
static const struct wl_message keyboard_requests[] = {
    { "keymap", "uhu", NULL }, { "key", "uuu", NULL },
    { "modifiers", "uuuu", NULL }, { "destroy", "", NULL }
};
static const struct wl_interface keyboard_interface = { "zwp_virtual_keyboard_v1", 1, 4, keyboard_requests, 0, NULL };
static struct wl_proxy *manager, *keyboard;
static struct wl_seat *seat;
static struct xkb_state *state;
static int held[256];

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, manager_interface.name)) manager = wl_registry_bind(registry, name, &manager_interface, 1);
    if (!seat && !strcmp(interface, "wl_seat")) seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener listener = { global, removed };

static void key(unsigned code, int down) {
    if (code >= 256 || held[code] == down) return;
    held[code] = down;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wl_proxy_marshal(keyboard, 1, (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000), code, (uint32_t)down);
    xkb_state_update_key(state, code + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
    wl_proxy_marshal(keyboard, 2,
        xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
}
static void release(void) {
    for (unsigned i = 0; i < 256; i++) if (held[i]) key(i, 0);
}

int main(void) {
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fputs("Cannot connect to Wayland\n", stderr); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) {
        fputs("Wayland virtual keyboard is unavailable\n", stderr); return 1;
    }
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = { .layout = "us" };
    struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!map) return 1;
    state = xkb_state_new(map);
    char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t length = strlen(text) + 1;
    int fd = memfd_create("lattices-keyboard", MFD_CLOEXEC);
    if (fd < 0 || write(fd, text, length) != (ssize_t)length) return 1;
    keyboard = wl_proxy_marshal_constructor(manager, 0, &keyboard_interface, seat, NULL);
    wl_proxy_marshal(keyboard, 0, 1u, fd, (uint32_t)length);
    if (wl_display_roundtrip(display) < 0) return 1;
    close(fd); free(text);
    puts("ready");
    char line[80];
    // EOF or a dead parent must never leave modifiers pressed. The host sends
    // keepalives only while a foreground viewer owns this device.
    struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN };
    while (poll(&input, 1, 5000) > 0 && fgets(line, sizeof(line), stdin)) {
        unsigned code; int down;
        if (sscanf(line, "key %u %d", &code, &down) == 2 && code > 0 && code < 256 && (down == 0 || down == 1)) key(code, down);
        else if (!strcmp(line, "reset\n")) release();
        else if (strcmp(line, "ping\n")) break;
        if (wl_display_roundtrip(display) < 0) break;
        puts("ok");
    }
    release();
    wl_proxy_marshal(keyboard, 3);
    wl_display_flush(display);
    wl_proxy_destroy(keyboard);
    wl_display_disconnect(display);
    xkb_state_unref(state); xkb_keymap_unref(map); xkb_context_unref(context);
    return 0;
}

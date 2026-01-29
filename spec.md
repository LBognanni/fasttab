# FastTab Developer Specification

**Version:** 1.0  
**License:** GPL-3.0  
**Last Updated:** January 2026

## Overview

FastTab is a high-performance window switcher for X11 desktops. It is a standalone daemon written in Zig that:

1. **Pre-caches window thumbnails** in the background using XComposite, so the switcher displays instantly
2. **Grabs Alt+Tab globally** via XCB passive key grabs, handling the full switching lifecycle
3. **Renders a thumbnail grid** using raylib, with MRU window ordering
4. **Activates windows** directly via `_NET_ACTIVE_WINDOW` client messages

### Why Standalone?

KDE's built-in task switchers render thumbnails on demand when Alt+Tab is pressed, which introduces latency. FastTab pre-caches thumbnails in the background so the switcher can display instantly by blitting existing images rather than capturing windows at display time.

Rather than integrating as a KWin plugin (which adds complexity and limits portability), FastTab grabs Alt+Tab directly at the X11 level. This makes it work with any X11 window manager, not just KWin.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                        FastTab Daemon                          │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌──────────────────┐     ┌─────────────────────────────────┐  │
│  │  Window Tracker  │     │       Thumbnail Cache           │  │
│  │                  │     │                                 │  │
│  │  - X11 events    │────▶│  - XComposite capture          │  │
│  │  - _NET_CLIENT   │     │  - Periodic refresh            │  │
│  │    _LIST         │     │  - In-memory RGBA buffers      │  │
│  └──────────────────┘     └─────────────────────────────────┘  │
│                                       │                        │
│                                       ▼                        │
│  ┌──────────────────┐     ┌─────────────────────────────────┐  │
│  │   Key Grabber    │     │       Switcher Renderer         │  │
│  │                  │     │                                 │  │
│  │  - Alt+Tab grab  │────▶│  - raylib window               │  │
│  │  - XCB key evts  │     │  - Grid layout                 │  │
│  │  - State machine │     │  - Selection highlight         │  │
│  └──────────────────┘     └─────────────────────────────────┘  │
│                                       │                        │
│                                       ▼                        │
│                           ┌───────────────────────┐            │
│                           │  Window Activation    │            │
│                           │  _NET_ACTIVE_WINDOW   │            │
│                           └───────────────────────┘            │
└────────────────────────────────────────────────────────────────┘

Key Flow:
  Alt+Tab pressed → passive grab triggers → active keyboard grab
  → show switcher (MRU order) → Tab/Shift+Tab cycles selection
  → Alt released → activate window → ungrab → hide switcher
```

---

## Component Specifications

### FastTab Daemon

#### Technology Stack

- **Language:** Zig
- **X11 Binding:** XCB via Zig's @cImport (xcb, xcb-composite, xcb-image, xcb-keysyms)
- **Rendering:** raylib (provides window creation, OpenGL context, texture rendering, text drawing)
- **Input:** XCB passive key grab (Alt+Tab) + active keyboard grab during switching

#### Responsibilities

1. **Window Tracking**
   - Monitor `_NET_CLIENT_LIST` property on root window for window additions/removals
   - Listen for `DestroyNotify` and `UnmapNotify` events
   - Maintain an internal list of window IDs with metadata (title, class)

2. **Thumbnail Caching**
   - Capture window contents using XComposite extension
   - Store thumbnails as in-memory RGBA buffers
   - Refresh thumbnails periodically (initial implementation: polling)
   - Scale thumbnails to target height of 256 pixels, preserving aspect ratio

3. **Global Key Grabbing**
   - Grab Alt+Tab and Alt+Shift+Tab on root window (passive grab via `xcb_grab_key`)
   - Handle NumLock/CapsLock modifier variants (4 grabs per key combo)
   - On Alt+Tab: acquire active keyboard grab (`xcb_grab_keyboard`) for all subsequent keys
   - Process Tab, Shift+Tab, arrow keys, Enter, ESC during active grab
   - On Alt release: activate selected window and release grab
   - On ESC: cancel without activating

4. **Window Ordering (MRU)**
   - Query `_NET_CLIENT_LIST_STACKING` for stacking order
   - Reverse stacking order to get MRU (most recently used) ordering
   - On initial Alt+Tab, select index 1 (the previously focused window)

5. **Window Activation**
   - Send `_NET_ACTIVE_WINDOW` client message to root window (source=2 pager)
   - Works with any EWMH-compliant window manager

6. **Switcher Rendering**
   - Create a borderless, always-on-top window using raylib
   - Position window centered on the monitor containing the mouse cursor
   - Render cached thumbnails in a grid layout
   - Draw selection highlight around current window
   - Display window titles below thumbnails

#### Future Enhancement: XDamage

The initial implementation uses periodic polling to refresh thumbnails. A future enhancement should use XDamage to receive notifications when window contents change, updating only the affected thumbnails. This would reduce CPU usage while keeping thumbnails current.

---

## Command-Line Interface

### Usage

```
fasttab                     # Start the daemon
fasttab daemon              # Same as above
```

The daemon:
- Connects to X11 and initializes XComposite
- Grabs Alt+Tab globally via XCB passive key grab
- Begins tracking windows and caching thumbnails
- Initializes raylib (hidden until Alt+Tab is pressed)
- Handles all input via XCB key events
- Runs until terminated (SIGTERM/SIGINT)

Should be started once at login (e.g., via autostart, systemd user unit, or KDE autostart).

### Prerequisites

- Disable the window manager's Alt+Tab shortcut before starting FastTab. For KWin: System Settings → Shortcuts → KWin → "Walk Through Windows" → remove shortcut.
- The XCB key grab acts as a singleton mechanism — a second FastTab instance's grab will fail.

---

## Visual Design

### Switcher Window

- **Background:** Rounded rectangle, dark gray (#222222), 85% opacity
- **Corner radius:** 12 pixels
- **Padding:** 16 pixels on all sides
- **Position:** Centered on the monitor containing the mouse cursor
- **Layer:** Always on top, no window decorations

### Thumbnail Grid

- **Thumbnail height:** 100 pixels (fixed)
- **Thumbnail width:** Proportional to window's aspect ratio
- **Spacing:** 12 pixels between items (horizontal and vertical)
- **Layout:** Grid, filling rows left-to-right before adding new rows

### Grid Sizing Algorithm

1. Calculate thumbnail widths based on each window's aspect ratio (height fixed at 128px)
2. Determine optimal column count:
   - Start with 1 column
   - Add columns while total grid width (including spacing and padding) fits within 1820px
   - Add rows while total grid height fits within 980px
3. If all windows don't fit at 128px height:
   - Reduce thumbnail height proportionally until they fit
   - Minimum thumbnail height: 60px
4. If still doesn't fit at 60px height:
   - Show first N windows that fit, ignore the rest (edge case)

### Window Item

- **Container:** Rounded rectangle, 4 pixel corner radius
- **Background:** Transparent when unselected, highlight color (#3daee9) when selected
- **Thumbnail:** Centered within container, 4 pixel margin
- **Title:** Below thumbnail, centered, white text, single line, ellipsized if too long
- **Title font:** System default, 12px
- **Item spacing:** 8 pixels between thumbnail bottom and title

### Selection Highlight

- 3 pixel border in KDE accent blue (#3daee9)
- Applied to the container rectangle
- No animation (instant change)

---

## Milestones

### Milestone 1: Window List ✅

**Goal:** Verify we can enumerate open windows using XCB.

**Deliverable:** A Zig program that connects to X11, reads `_NET_CLIENT_LIST` from the root window, and prints each window's ID and title to stdout.

**Output format:**
```
Window ID: 12345678
  Title: Firefox
  Class: firefox
Window ID: 23456789
  Title: Dolphin
  Class: dolphin
```

**Technical notes:**
- Use `_NET_CLIENT_LIST` property on root window (type: array of Window)
- Get window title from `_NET_WM_NAME` (UTF-8) or fall back to `WM_NAME`
- Get window class from `WM_CLASS`

---

### Milestone 2: Thumbnail Capture ✅

**Goal:** Verify we can capture window contents using XComposite.

**Deliverable:** Extend the program to capture a thumbnail of each window and save it to disk as a PNG file.

**Output:** One PNG file per window in current directory, named `window_<id>.png`.

**Technical notes:**
- Initialize XComposite extension
- Call `xcb_composite_redirect_subwindows` on root (or redirect individual windows)
- Use `xcb_composite_name_window_pixmap` to get a pixmap for each window
- Use `xcb_get_image` to read pixel data
- Scale to 100px height, maintaining aspect ratio
- Use a simple image library or write raw PNG (stb_image_write works via @cImport)

---

### Milestone 3: Display Window with Thumbnails ✅

**Goal:** Render cached thumbnails in a raylib window.

**Deliverable:** A program that captures thumbnails for all windows and displays them in a grid layout using raylib. Window stays open until closed manually.

**Technical notes:**
- Initialize raylib with a borderless, transparent window
- Convert captured RGBA buffers to raylib Textures
- Implement grid layout algorithm from Visual Design section
- Draw rounded rectangles for background and containers
- Draw window titles using raylib's text rendering

---

### Milestone 4: Live Updates ✅

**Goal:** Keep the window list and thumbnails updated while running.

**Deliverable:** The program now runs continuously:
- Detects when windows are created or destroyed
- Updates thumbnails periodically (every 1000ms)
- Grid re-layouts when window count changes

**Technical notes:**
- Use XCB event loop to receive `PropertyNotify` on root window for `_NET_CLIENT_LIST` changes
- Set up a timer for periodic thumbnail refresh
- Handle the raylib event loop and XCB event loop together (poll both)
- Ensure old textures are unloaded _after_ new ones are created to avoid crashes

---

### Milestone 4.5: Daemon Mode ✅
**Goal:** Refactor program to run as a background daemon.

**Deliverable:** The program will now run as a long-lived background process:
- without showing the raylib window until commanded
- existing functionality (window tracking, thumbnail caching) works as before
- closing the window does not terminate the program

**Technical notes:**
- For now, just add a command line argument `--daemon` that starts the program without showing the window.
- The window should be created after 2 seconds of running in daemon mode, to simulate delayed initialization.
- Ensure that all existing functionality (window tracking, thumbnail caching) works in daemon mode.

---

### Milestone 5: Global Key Grabbing

**Goal:** Grab Alt+Tab globally and handle the full switching lifecycle.

**Deliverable:** The daemon now:
- Grabs Alt+Tab and Alt+Shift+Tab on the root window via `xcb_grab_key`
- On Alt+Tab: acquires active keyboard grab, shows switcher with MRU-ordered windows
- On Tab (while holding Alt): cycles selection forward
- On Shift+Tab: cycles selection backward
- On Alt release: activates the selected window via `_NET_ACTIVE_WINDOW` and hides
- On ESC: cancels without activating
- Arrow keys navigate the grid during switching

**Technical notes:**
- Link `xcb-keysyms` library for keysym-to-keycode conversion
- Passive grab with `xcb_grab_key` on root window catches initial Alt+Tab
- Active grab with `xcb_grab_keyboard` captures all subsequent key events
- Must grab with 4 modifier variants per combo (bare, +CapsLock, +NumLock, +both)
- Poll XCB file descriptor in event loop for key press/release events
- MRU ordering via `_NET_CLIENT_LIST_STACKING` (reversed = most recently used first)
- Window activation via `_NET_ACTIVE_WINDOW` client message (source=2 pager)
- User must disable window manager's Alt+Tab shortcut first

---

### Milestone 6: Cleanup

**Goal:** Remove legacy socket/CLI/QML code.

**Deliverable:**
- Delete `src/socket.zig`, `src/client.zig`, `qml/` directory
- Simplify `main.zig` to only accept `fasttab` or `fasttab daemon`
- Remove all socket-related code from the event loop
- Update documentation

---

### Milestone 9: Polish and Edge Cases

**Goal:** Handle real-world usage reliably.

**Deliverables:**
- Handle monitors being added/removed
- Handle rapid Alt+Tab presses (debounce or queue)
- Handle windows with no title gracefully
- Handle windows that refuse to provide thumbnails (use placeholder)
- Test with 50+ windows open
- Verify no memory leaks over extended usage

---

## Appendix A: XCB Quick Reference

### Required Libraries

```
xcb
xcb-composite
xcb-image
xcb-keysyms     (for keysym-to-keycode conversion)
```

### Key Functions

**Connection:**
```
xcb_connect(display_name, screen_num) -> xcb_connection_t*
xcb_disconnect(connection)
```

**Getting Window List:**
```
xcb_intern_atom(conn, "_NET_CLIENT_LIST") -> atom
xcb_get_property(conn, root, atom, XCB_ATOM_WINDOW, ...) -> window IDs
```

**Getting Window Title:**
```
xcb_intern_atom(conn, "_NET_WM_NAME") -> atom
xcb_get_property(conn, window, atom, UTF8_STRING, ...) -> title bytes
```

**Composite Extension:**
```
xcb_composite_query_version(conn, major, minor)
xcb_composite_redirect_window(conn, window, XCB_COMPOSITE_REDIRECT_AUTOMATIC)
xcb_composite_name_window_pixmap(conn, window) -> pixmap_id
```

**Getting Pixels:**
```
xcb_get_geometry(conn, window) -> width, height
xcb_get_image(conn, XCB_IMAGE_FORMAT_Z_PIXMAP, pixmap, x, y, w, h, mask) -> pixel data
```

**Events:**
```
xcb_poll_for_event(conn) -> xcb_generic_event_t*
// Check event->response_type for:
//   XCB_KEY_PRESS - key pressed (passive/active grab)
//   XCB_KEY_RELEASE - key released (detect Alt release)
//   XCB_PROPERTY_NOTIFY - window property changed
//   XCB_DESTROY_NOTIFY - window destroyed
//   XCB_CREATE_NOTIFY - window created
```

**Key Grabbing:**
```
xcb_grab_key(conn, owner_events, root, modifiers, keycode, ptr_mode, kbd_mode)
xcb_ungrab_key(conn, keycode, root, modifiers)
xcb_grab_keyboard(conn, owner_events, root, time, ptr_mode, kbd_mode) -> status
xcb_ungrab_keyboard(conn, time)
```

**Key Symbols (xcb-keysyms):**
```
xcb_key_symbols_alloc(conn) -> xcb_key_symbols_t*
xcb_key_symbols_get_keycode(syms, keysym) -> xcb_keycode_t*
xcb_key_symbols_get_keysym(syms, keycode, col) -> xcb_keysym_t
xcb_key_symbols_free(syms)
```

**Window Activation:**
```
// Send _NET_ACTIVE_WINDOW client message to root window
xcb_send_event(conn, propagate, root, event_mask, event)
```

---

## Appendix B: raylib Quick Reference

### Initialization

```
SetConfigFlags(FLAG_WINDOW_UNDECORATED | FLAG_WINDOW_TRANSPARENT | FLAG_WINDOW_TOPMOST);
InitWindow(width, height, "FastTab");
SetTargetFPS(60);
```

### Main Loop

```
while (!WindowShouldClose()) {
    BeginDrawing();
    ClearBackground(BLANK);
    // Draw stuff
    EndDrawing();
}
CloseWindow();
```

### Drawing

```
DrawRectangleRounded(rect, roundness, segments, color);
DrawTexture(texture, x, y, WHITE);
DrawText(text, x, y, fontSize, color);
```

### Textures from Raw Data

```
Image image = {
    .data = rgba_pixels,
    .width = width,
    .height = height,
    .format = PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    .mipmaps = 1
};
Texture2D texture = LoadTextureFromImage(image);
```


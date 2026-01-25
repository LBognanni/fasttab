# FastTab Developer Specification

**Version:** 1.0  
**License:** GPL-3.0  
**Last Updated:** January 2026

## Overview

FastTab is a high-performance window switcher for KDE Plasma on X11. It consists of two components:

1. **FastTab Daemon** — A background service written in Zig that tracks open windows, maintains a cache of window thumbnails, and renders a fast thumbnail-based switcher UI on demand.

2. **QML Stub** — A minimal KDE task switcher plugin that integrates with KWin's Alt+Tab system. It displays nothing visually but forwards keyboard events to the daemon and triggers window activation through KWin.

### Why This Architecture?

KDE's built-in task switchers render thumbnails on demand when Alt+Tab is pressed, which introduces latency. FastTab pre-caches thumbnails in the background so the switcher can display instantly by blitting existing images rather than capturing windows at display time.

The QML stub exists solely to integrate with KWin's keyboard handling. KWin grabs the keyboard when a task switcher activates, so rather than fighting for the grab, the stub acts as a relay — receiving key events from KWin and forwarding them to the daemon.

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
│  │   Socket Server  │     │       Switcher Renderer         │  │
│  │                  │     │                                 │  │
│  │  - Unix socket   │────▶│  - raylib window               │  │
│  │  - Receives cmds │     │  - Grid layout                 │  │
│  │  - No response   │     │  - Selection highlight         │  │
│  └──────────────────┘     └─────────────────────────────────┘  │
│           ▲                                                    │
└───────────│────────────────────────────────────────────────────┘
            │
            │ Unix Socket (send command, disconnect)
            │
┌───────────▼────────────────────────────────────────────────────┐
│                      FastTab CLI                               │
├────────────────────────────────────────────────────────────────┤
│  fasttab show <ids>   - Send SHOW command to daemon            │
│  fasttab index <n>    - Send INDEX command to daemon           │
│  fasttab hide         - Send HIDE command to daemon            │
│                                                                │
│  Lightweight: no X11 or raylib initialization                  │
│  Connects to socket, sends one line, exits                     │
└────────────────────────────────────────────────────────────────┘
            ▲
            │
            │ Process invocation (Qt.createProcess or similar)
            │
┌───────────┴────────────────────────────────────────────────────┐
│                         QML Stub                               │
├────────────────────────────────────────────────────────────────┤
│  - Registered as KDE task switcher                             │
│  - Renders nothing (1x1 transparent)                           │
│  - Invokes `fasttab show` on activation                        │
│  - Invokes `fasttab index` on selection change                 │
│  - Invokes `fasttab hide` on dismissal                         │
│  - Tells KWin to activate selected window                      │
└────────────────────────────────────────────────────────────────┘
```

---

## Component Specifications

### FastTab Daemon

#### Technology Stack

- **Language:** Zig
- **X11 Binding:** XCB via Zig's @cImport (xcb, xcb-composite, xcb-image)
- **Rendering:** raylib (provides window creation, OpenGL context, texture rendering, text drawing)
- **IPC:** Unix domain socket with text-based protocol

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

3. **Socket Server**
   - Listen on a Unix domain socket
   - Accept commands from CLI invocations
   - No responses needed (unidirectional)

4. **Switcher Rendering**
   - Create a borderless, always-on-top window using raylib
   - Position window centered on the monitor containing the mouse cursor
   - Render cached thumbnails in a grid layout
   - Draw selection highlight around current window
   - Display window titles below thumbnails

#### Future Enhancement: XDamage

The initial implementation uses periodic polling to refresh thumbnails. A future enhancement should use XDamage to receive notifications when window contents change, updating only the affected thumbnails. This would reduce CPU usage while keeping thumbnails current.

---

### QML Stub

#### Technology Stack

- **Language:** QML with minimal JavaScript
- **Integration:** KWin TabBox plugin system

#### Responsibilities

1. **KWin Integration**
   - Register as a valid task switcher in KDE System Settings
   - Receive activation when user presses Alt+Tab

2. **Command Invocation**
   - On activation: invoke `fasttab show <window_ids>` with window list from KWin
   - On currentIndex change: invoke `fasttab index <n>`
   - On dismissal: invoke `fasttab hide`

3. **Window Activation**
   - Use KWin's model to activate the selected window (KWin handles this, not the daemon)

---

## Command-Line Interface

The FastTab binary operates in two modes:

1. **Daemon mode** — Long-running background process that tracks windows, caches thumbnails, and renders the switcher
2. **Command mode** — Short-lived invocations that send commands to the daemon

### Usage

```
fasttab daemon              # Start the background daemon
fasttab show <id1,id2,...>  # Show switcher with specified windows
fasttab index <n>           # Update selection to index n
fasttab hide                # Hide the switcher
```

### Commands

#### fasttab daemon

Starts the background daemon. This process:
- Connects to X11 and initializes XComposite
- Begins tracking windows and caching thumbnails
- Initializes raylib (but doesn't show a window yet)
- Listens on a Unix socket for commands
- Runs until terminated

Should be started once at login (e.g., via autostart, systemd user unit, or KDE autostart).

#### fasttab show \<window_ids\>

Shows the switcher with the specified windows.

- `window_ids`: Comma-separated list of X11 window IDs (decimal)
- Order determines display order (first = top-left)
- Only these windows are shown, even if daemon knows about others
- First window in list is initially selected (index 0)

**Example:**
```bash
fasttab show 12345678,23456789,34567890
```

#### fasttab index \<n\>

Updates the selection highlight.

- `n`: Zero-based index into the window list from the last `show` command

**Example:**
```bash
fasttab index 2
```

#### fasttab hide

Hides the switcher window. Sent when:
- User dismisses switcher (Escape, focus lost)
- User confirms selection (the QML stub handles activation, then hides)

### Internal Protocol

Commands communicate with the daemon over a Unix domain socket.

**Socket path:** `/tmp/fasttab.sock` (or `$XDG_RUNTIME_DIR/fasttab.sock` if available)

**Protocol:** Each command connects, sends a single line, and disconnects. No response is expected.

```
SHOW <id1>,<id2>,<id3>\n
INDEX <n>\n
HIDE\n
```

The protocol is unidirectional (client to daemon only). KWin handles window activation, so the daemon never needs to respond.

### Startup Time Requirements

The `show`, `index`, and `hide` commands are in the critical path of Alt+Tab interaction. They must be extremely fast.

**These commands must NOT:**
- Initialize raylib or any graphics
- Connect to X11
- Load configuration files
- Perform any unnecessary work

**These commands ONLY:**
1. Parse arguments
2. Connect to Unix socket
3. Send message (single write)
4. Exit

The binary should have two completely separate code paths: the full daemon initialization path, and the minimal CLI client path.

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

### Milestone 1: Window List

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

### Milestone 2: Thumbnail Capture

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

### Milestone 3: Display Window with Thumbnails

**Goal:** Render cached thumbnails in a raylib window.

**Deliverable:** A program that captures thumbnails for all windows and displays them in a grid layout using raylib. Window stays open until closed manually.

**Technical notes:**
- Initialize raylib with a borderless, transparent window
- Convert captured RGBA buffers to raylib Textures
- Implement grid layout algorithm from Visual Design section
- Draw rounded rectangles for background and containers
- Draw window titles using raylib's text rendering

---

### Milestone 4: Live Updates

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

### Milestone 5: Socket Server

**Goal:** Accept commands over Unix socket.

**Deliverable:** The daemon now:
- Listens on `/tmp/fasttab.sock`
- Accepts SHOW, INDEX, HIDE commands
- Shows/hides the switcher window accordingly
- Prints received commands to stdout for debugging

**Technical notes:**
- Create Unix domain socket, bind, listen
- Add socket file descriptor to event loop
- Parse incoming messages according to protocol spec
- When SHOW received: display the switcher with the specified windows in the specified order
- When INDEX received: update selection highlight
- When HIDE received: hide the switcher window

---

### Milestone 6: CLI Commands

**Goal:** Implement the command-line interface for sending commands.

**Deliverable:** The same binary now supports:
- `fasttab daemon` — starts the daemon (existing behavior)
- `fasttab show <ids>` — connects to socket, sends SHOW, exits
- `fasttab index <n>` — connects to socket, sends INDEX, exits
- `fasttab hide` — connects to socket, sends HIDE, exits

**Technical notes:**
- CLI commands must not initialize raylib or X11
- CLI commands have a completely separate code path from daemon mode
- Parse argv to determine mode before any heavy initialization
- CLI commands should complete in under 5ms
- After this milestone, the daemon is feature-complete for standalone testing

---

### Milestone 7: Daemon Mode

**Goal:** Run as a background service.

**Deliverable:** The program can:
- Run in foreground (for debugging) or daemonize
- Handle SIGTERM gracefully (clean up socket, exit)
- Log to stderr or a log file
- Reconnect to X11 if connection lost (optional)

**Command line:**
```
fasttab daemon              # Run in foreground
fasttab daemon --fork       # Daemonize
fasttab --help              # Show usage
```

---

### Milestone 8: QML Stub

**Goal:** Integrate with KDE's task switcher system.

**Deliverable:** A KDE task switcher plugin that:
- Appears in System Settings → Window Management → Task Switcher
- When selected and activated via Alt+Tab:
  - Invokes `fasttab show <window_ids>` with window list from KWin
  - Invokes `fasttab index <n>` as user navigates
  - Invokes `fasttab hide` when dismissed
  - Activates the selected window via KWin's model

**File structure:**
```
~/.local/share/kwin/tabbox/fasttab/
├── metadata.json
└── contents/
    └── ui/
        └── main.qml
```

**Technical notes:**
- Use KWin.TabBoxSwitcher as root element for integration
- Render nothing visually (1x1 transparent item or empty)
- Use Qt.createProcess() or Process QML type to invoke fasttab commands
- Build comma-separated window ID list from tabBox.model
- Watch currentIndex changes to send index updates

---

### Milestone 9: Polish and Edge Cases

**Goal:** Handle real-world usage reliably.

**Deliverables:**
- Handle monitors being added/removed
- Handle daemon not running (QML stub shows error or falls back)
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
xcb-util        (optional, for convenience functions)
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
//   XCB_PROPERTY_NOTIFY - window property changed
//   XCB_DESTROY_NOTIFY - window destroyed
//   XCB_CREATE_NOTIFY - window created
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

---

## Appendix C: Process Invocation in QML

QML can invoke external processes using the `Process` type or `Qt.createQmlObject`. Example approach:

```qml
import QtQuick 2.15
import org.kde.kwin 3.0 as KWin

KWin.TabBoxSwitcher {
    id: tabBox
    
    // Invisible - render nothing
    Item { width: 1; height: 1 }
    
    Component.onCompleted: {
        var ids = [];
        for (var i = 0; i < tabBox.model.count; i++) {
            ids.push(tabBox.model.data(tabBox.model.index(i, 0), /* wId role */));
        }
        // Invoke: fasttab show id1,id2,id3
        executable.exec("fasttab", ["show", ids.join(",")]);
    }
    
    Component.onDestruction: {
        executable.exec("fasttab", ["hide"]);
    }
    
    onCurrentIndexChanged: {
        executable.exec("fasttab", ["index", currentIndex.toString()]);
    }
}
```

**Note:** The exact mechanism for process invocation depends on what's available in the KWin/Qt environment. Options include:

- `Qt.labs.platform` Process type
- Custom C++ helper registered as a QML type (minimal, just wraps QProcess)
- KDE-specific APIs if available

The developer should investigate what's available in the target KDE Plasma version.
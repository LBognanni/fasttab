# FastTab Developer Specification

**Version:** 1.0  
**License:** GPL-3.0  
**Last Updated:** January 2026

## Overview

FastTab is a high-performance window switcher for X11 desktops. It is a standalone daemon written in Zig that:

1. **Binds window textures directly on the GPU** using GLX_EXT_texture_from_pixmap for zero-copy rendering
2. **Grabs Alt+Tab globally** via XCB passive key grabs, handling the full switching lifecycle
3. **Renders a thumbnail grid** using raylib, with MRU window ordering
4. **Activates windows** directly via `_NET_ACTIVE_WINDOW` client messages

### Why Standalone?

KDE's built-in task switchers render thumbnails on demand when Alt+Tab is pressed, which introduces latency. FastTab maintains live GPU-bound textures that reflect window content in real-time without any CPU-side capture or processing.

Rather than integrating as a KWin plugin (which adds complexity and limits portability), FastTab grabs Alt+Tab directly at the X11 level. This makes it work with any X11 window manager, not just KWin.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                        FastTab Daemon                          │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌──────────────────┐     ┌─────────────────────────────────┐  │
│  │  Window Tracker  │     │     GLX Texture Manager         │  │
│  │                  │     │                                 │  │
│  │  - X11 events    │────▶│  - GLX pixmap binding           │  │
│  │  - _NET_CLIENT   │     │  - XDamage monitoring           │  │
│  │    _LIST         │     │  - Zero-copy GPU textures       │  │
│  └──────────────────┘     └─────────────────────────────────┘  │
│                                       │                        │
│                                       ▼                        │
│  ┌──────────────────┐     ┌─────────────────────────────────┐  │
│  │   Key Grabber    │     │       Switcher Renderer         │  │
│  │                  │     │                                 │  │
│  │  - Alt+Tab grab  │────▶│  - raylib window                │  │
│  │  - XCB key evts  │     │  - Grid layout                  │  │
│  │  - State machine │     │  - Selection highlight          │  │
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
- **X11 Binding:** XCB + GLX via Zig's @cImport (xcb, xcb-composite, xcb-damage, xcb-keysyms, glx)
- **Rendering:** raylib (provides window creation, OpenGL context, texture rendering, text drawing)
- **Shaders:** GLSL (embedded at compile time for adaptive box-filter downsampling)
- **Input:** XCB passive key grab (Alt+Tab) + active keyboard grab during switching

#### Responsibilities

1. **Window Tracking**
   - Monitor `_NET_CLIENT_LIST` property on root window for window additions/removals
   - Listen for `DestroyNotify` and `UnmapNotify` events
   - Maintain an internal list of window IDs with metadata (title, class)

2. **GPU Texture Management**
   - Bind window pixmaps directly as OpenGL textures using GLX_EXT_texture_from_pixmap
   - Zero-copy architecture - pixel data never leaves GPU memory
   - Monitor window content changes via XDamage extension
   - Rebind textures when damage events indicate content changed
   - Apply custom GLSL downsampling shader for high-quality thumbnail rendering (adaptive 2x2 to 8x8 box filtering)

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
# Standalone Alt+Tab Daemon — Replace QML/Socket with XCB Key Grabbing

## Goal
Replace the QML KWin plugin + socket IPC architecture with direct XCB global key grabbing. The daemon becomes fully self-contained: it grabs Alt+Tab, shows thumbnails, handles navigation, activates windows, and hides — all without KWin cooperation.

## Architecture Change

**Before:** QML stub (KWin plugin) → CLI → socket → daemon
**After:** XCB passive key grab → daemon handles everything directly

## Files to Delete
- `src/socket.zig` — socket server
- `src/client.zig` — CLI client
- `qml/` — entire directory (KWin plugin no longer needed)

## Files to Modify (in implementation order)

### 1. `build.zig` — Add xcb-keysyms dependency

Add `exe.linkSystemLibrary("xcb-keysyms")` to both the main target and test target. This library converts keysyms (XK_Tab, XK_Alt_L, etc.) to hardware keycodes.

### 2. `src/x11.zig` — Key grab infrastructure

**Add to `@cImport`:**
- `@cInclude("xcb/xcb_keysyms.h")`

**Add constants:**
```
XK_Tab = 0xff09, XK_ISO_Left_Tab = 0xfe20, XK_Alt_L = 0xffe9,
XK_Alt_R = 0xffea, XK_Escape = 0xff1b, XK_Return = 0xff0d,
XK_Left/Up/Right/Down
MOD_ALT = XCB_MOD_MASK_1, MOD_SHIFT, MOD_LOCK, MOD_MOD2 (NumLock)
```

**Add atoms to `Atoms` struct:**
- `net_client_list_stacking` — for MRU window ordering
- `net_active_window` — for window activation

**New functions:**
| Function | Purpose |
|----------|---------|
| `grabAltTab(conn, root)` | Passive grab Alt+Tab & Alt+Shift+Tab with 4 NumLock/CapsLock variants each |
| `ungrabAltTab(conn, root)` | Release passive grabs |
| `grabKeyboard(conn, root)` | Active grab — ALL key events go to us during switching |
| `ungrabKeyboard(conn)` | Release active grab |
| `activateWindow(conn, root, window, atoms)` | Send `_NET_ACTIVE_WINDOW` client message (source=2 pager) |
| `getStackingWindowList(allocator, conn, root, atoms)` | Get `_NET_CLIENT_LIST_STACKING` as owned slice (caller frees) |
| `keycodeToKeysym(conn, keycode, state)` | Convert key event to keysym using xcb-keysyms |
| `getXcbFd(conn)` | Get file descriptor for polling |

**NumLock/CapsLock handling:** Each key combo needs 4 grabs:
- bare, +CapsLock, +NumLock, +CapsLock+NumLock

**Stacking list memory safety:** `getStackingWindowList` must allocate and copy the data (not return a pointer into the XCB reply buffer that gets freed).

### 3. `src/app.zig` — Alt+Tab state machine

**Add `SwitcherState` enum:** `idle` | `switching`

**Add fields to `App` struct:**
- `state: SwitcherState` (init to `.idle`)
- `xcb_atoms: x11.Atoms` (passed through init)

**New methods:**
| Method | Behavior |
|--------|----------|
| `handleAltTab(shift)` | Grab keyboard, reorder windows by stacking (MRU), show switcher, select index 1 (previous window). If shift, select last. |
| `handleKeyEvent(keysym, is_press, state_mask)` | State machine: Tab→next, Shift+Tab/ISO_Left_Tab→prev, arrows→grid nav, Enter→confirm, ESC→cancel, Alt release→confirm |
| `confirmSwitching()` | Activate selected window via `_NET_ACTIVE_WINDOW`, ungrab keyboard, hide |
| `cancelSwitching()` | Ungrab keyboard, hide (no activation) |
| `reorderByStacking()` | Query `_NET_CLIENT_LIST_STACKING`, reverse it (topmost=MRU), reorder internal items to match |

**Modify `update()`:**
- Remove `handleKeyboardInput()` call (all keyboard input now via XCB)
- Remove raylib ESC handling (ESC handled via XCB events)
- Keep `rl.WindowShouldClose()` as fallback for window manager close

**Remove/internalize:** `showWithWindows`, `showAll`, `setSelectedIndex` (socket-facing API no longer needed)

**Update `init` signature:** Add `xcb_atoms: x11.Atoms` parameter.

### 4. `src/main.zig` — Replace event loop

**Remove:**
- Imports for `client` and `socket`
- Entire CLI fast-path (show/index/hide/next/prev commands)
- `handleSocketCommand` function
- Socket server init/poll

**Simplify `main()`:** Only accept `fasttab` or `fasttab daemon` — both start the daemon.

**Rewrite `runDaemon()`:**
- Init X11 connection
- Call `x11.grabAltTab(conn, root)` with defer ungrab
- Start background worker (unchanged)
- Init app (hidden, with atoms)
- Poll on **XCB file descriptor** (not socket)
- Call `processXcbEvents()` to handle key press/release

**New `processXcbEvents(app, conn)`:**
- Loop `xcb_poll_for_event`
- `XCB_KEY_PRESS`: if idle + Tab keysym → `app.handleAltTab(shift)`. If switching → `app.handleKeyEvent(...)`.
- `XCB_KEY_RELEASE`: forward to `app.handleKeyEvent(...)` (catches Alt release).

## Key Design Decisions

1. **Alt release = confirm selection.** This matches standard Alt+Tab UX. The keysym (`XK_Alt_L`/`XK_Alt_R`) is checked, not the modifier mask (which still has Mod1 set in the release event).

2. **MRU via stacking order.** `_NET_CLIENT_LIST_STACKING` reversed gives approximately MRU order. Good enough; exact focus-history tracking can be added later if needed.

3. **Index 1 on initial show.** The first item (index 0) is the currently focused window. Index 1 is the previous window — matching Alt+Tab convention where one press switches to previous.

4. **No socket/CLI.** Daemon starts with `fasttab` and stops with SIGTERM/SIGINT. The XCB key grab itself acts as a singleton mechanism (second instance's grab will fail).

## Prerequisites
- Install `libxcb-keysyms1-dev` (Debian/Ubuntu) or `xcb-util-keysyms` (Arch)
- Disable KWin's Alt+Tab shortcut: System Settings → Shortcuts → KWin → "Walk Through Windows" → remove shortcut. Otherwise KWin holds the grab and FastTab's grab won't work.

## Verification
1. `zig build` — confirm it compiles with xcb-keysyms
2. Disable KWin's Alt+Tab shortcut
3. Run `./zig-out/bin/fasttab` — should print "Alt+Tab grabbed"
4. Alt+Tab → switcher appears with MRU-ordered windows, index 1 selected
5. Tab (holding Alt) → selection cycles forward
6. Shift+Tab (holding Alt) → selection cycles backward
7. Release Alt → selected window activates, switcher hides
8. Alt+Tab then ESC → switcher hides without activating
9. Arrow keys during switching → grid navigation works

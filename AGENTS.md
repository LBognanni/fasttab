# FastTab Agent Guidelines

**Project:** FastTab - High-performance window switcher for KDE Plasma on X11  
**Language:** Zig (daemon/CLI) + QML (KDE plugin)  
**Architecture:** Two-component system (daemon + QML stub)

## Quick Reference

### Build Commands

```bash
# Build the daemon
zig build

# Build in release mode
zig build -Doptimize=ReleaseFast

# Run the daemon
zig build run

# Build specific target
zig build-exe src/main.zig -lc -lxcb -lxcb-composite -lxcb-image -lraylib

# Clean build artifacts
rm -rf zig-cache zig-out
```

### Testing Commands

```bash
# Run all tests
zig build test

# Run specific test file
zig test src/window_tracker.zig

# Run with test coverage
zig build test --summary all
```

### Linting/Formatting

```bash
# Format all Zig files (in-place)
zig fmt .

# Check formatting without changes
zig fmt --check .
```

## Project Structure

```
fasttab/
├── src/
│   ├── main.zig              # Main implementation (currently monolithic)
│   └── stb_impl.c            # STB image library implementation
├── include/
│   └── stb_image_write.h     # STB header for PNG writing
├── lib/                      # Downloaded dependencies (gitignored)
│   └── raylib-5.5_linux_amd64/
├── qml/                      # (Future) KDE plugin
│   └── fasttab/
│       ├── metadata.json
│       └── contents/ui/
│           └── main.qml
├── build.zig                 # Zig build script
├── setup.sh                  # Developer setup script (downloads raylib)
└── spec.md                   # Full project specification
```

## Setup

Run `./setup.sh` to download raylib before building. The `lib/` directory is gitignored.

## Code Style

### Zig Conventions

**Naming:**
- Types: `PascalCase` (e.g., `WindowTracker`, `ThumbnailCache`)
- Functions: `camelCase` (e.g., `captureWindow`, `renderGrid`)
- Variables: `snake_case` (e.g., `window_id`, `thumbnail_height`)
- Constants: `SCREAMING_SNAKE_CASE` (e.g., `MAX_WINDOWS`, `SOCKET_PATH`)
- Private members: prefix with underscore if needed, but prefer scope-based privacy

**Imports:**
```zig
const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
});
const raylib = @cImport(@cInclude("raylib.h"));
```

**Error handling:**
- Use Zig's error unions (`!Type`)
- Propagate errors with `try` or handle explicitly
- Define custom error sets for domain-specific errors
- Never ignore errors silently

```zig
const WindowError = error{
    ConnectionFailed,
    InvalidWindowId,
    CaptureTimedOut,
};

pub fn captureWindow(id: u32) WindowError!Thumbnail {
    const pixmap = try getPixmap(id);
    return scaleThumbnail(pixmap);
}
```

**Memory management:**
- Explicit allocators passed as parameters
- No hidden allocations
- Use `defer` for cleanup
- Arena allocators for request-scoped memory

```zig
pub fn init(allocator: std.mem.Allocator) !WindowTracker {
    const list = try allocator.alloc(Window, 128);
    errdefer allocator.free(list);
    return WindowTracker{ .windows = list, .allocator = allocator };
}

pub fn deinit(self: *WindowTracker) void {
    self.allocator.free(self.windows);
}
```

**Formatting:**
- 4 spaces indentation (enforced by `zig fmt`)
- 100 character line limit (soft guideline)
- No trailing whitespace
- Always run `zig fmt` before committing

### QML Conventions

**Structure:**
```qml
import QtQuick 2.15
import org.kde.kwin 3.0 as KWin

KWin.TabBoxSwitcher {
    id: root
    
    // Properties first
    property var windowIds: []
    
    // Signals
    signal selectionChanged(int index)
    
    // Functions
    function invokeCommand(cmd, args) {
        // Implementation
    }
    
    // Child items
    Item {
        // Invisible placeholder
    }
    
    // Signal handlers last
    Component.onCompleted: {
        // Initialization
    }
}
```

**Naming:**
- Components: `PascalCase`
- Properties/functions: `camelCase`
- IDs: `camelCase` (e.g., `id: tabBox`)

## Architecture Constraints

### Performance Requirements

**CLI Command Latency (Critical Path):**
- `fasttab show/index/hide` must complete in <5ms
- These commands MUST NOT:
  - Initialize raylib or graphics
  - Connect to X11
  - Load configuration files
  - Perform any unnecessary work
- Separate code path from daemon initialization

**Daemon Responsiveness:**
- Thumbnail updates: Target 30 FPS minimum
- Socket command response: <1ms from receipt to action
- Alt+Tab display: Visible within 50ms of command

### Security Considerations

- Unix socket permissions: 0600 (user-only)
- Validate all window IDs from external sources
- Sanitize window titles before rendering
- No arbitrary command execution from socket

### X11 Integration

**Required Extensions:**
- XComposite (for window capture)
- EWMH/NetWM (for `_NET_CLIENT_LIST`, `_NET_WM_NAME`)
- XDamage (future enhancement for change notifications)

**Window Filtering:**
- Filter windows by `_NET_WM_WINDOW_TYPE` property to exclude non-application windows
- Skip `_NET_WM_WINDOW_TYPE_DESKTOP` (desktop background windows)
- Skip `_NET_WM_WINDOW_TYPE_DOCK` (panels, docks like plasmashell)
- Include `_NET_WM_WINDOW_TYPE_NORMAL`, `_NET_WM_WINDOW_TYPE_DIALOG`, `_NET_WM_WINDOW_TYPE_UTILITY`
- Windows with no type set should be treated as normal windows

**Mouse Position for Multi-Monitor:**
- Use `xcb_query_pointer` to get global mouse coordinates BEFORE initializing raylib
- Query mouse position against root window to get absolute screen coordinates
- Iterate through raylib monitors to find which one contains the cursor
- Center the switcher window on that monitor

**Event Handling:**
- Poll both XCB and socket file descriptors in event loop
- Handle `PropertyNotify` on root for window list changes
- Handle `DestroyNotify` and `UnmapNotify` for window removal
- Gracefully handle X11 connection loss

### raylib Integration

**Window Configuration:**
```zig
raylib.SetConfigFlags(raylib.FLAG_WINDOW_UNDECORATED |
                      raylib.FLAG_WINDOW_TRANSPARENT |
                      raylib.FLAG_WINDOW_TOPMOST);
raylib.InitWindow(width, height, "FastTab");
raylib.SetTargetFPS(60);
```


**Rendering Strategy:**
- Pre-create textures from cached thumbnails
- Render grid in single pass
- Use `DrawRectangleRounded` for containers/background
- Use `DrawTexturePro` for scaled thumbnail rendering
- Center window on monitor containing mouse cursor

## Development Workflow

### Milestone-Driven Development

Follow the milestones in spec.md sequentially:
1. Window List (XCB enumeration)
2. Thumbnail Capture (XComposite)
3. Display Window (raylib grid)
4. Live Updates (event loop)
5. Socket Server (IPC)
6. CLI Commands (fast client path)
7. Daemon Mode (background service)
8. QML Stub (KDE integration)
9. Polish (edge cases)

Each milestone has concrete deliverables. Complete and verify before moving to next.

### Testing Strategy

**Unit Tests:**
- Test each module independently
- Mock X11/raylib for unit tests where possible
- Use `std.testing` framework

**Integration Tests:**
- Test socket protocol with real daemon
- Test window capture with real X11 server
- Verify grid layout algorithm with various window counts

**Manual Testing:**
- Test with varying window counts (1, 5, 20, 50+)
- Test with different aspect ratios
- Test on multiple monitors
- Test rapid Alt+Tab presses
- Monitor memory usage over extended periods

### Debugging

**Daemon Logging:**
```zig
const log = std.log.scoped(.fasttab);

log.debug("Captured window {d}: {s}", .{window_id, title});
log.err("Failed to connect to X11: {}", .{err});
```

**Socket Debugging:**
```bash
# Monitor socket communication
socat -v UNIX-CONNECT:/tmp/fasttab.sock -

# Send manual commands
echo "SHOW 12345,67890" | socat - UNIX-CONNECT:/tmp/fasttab.sock
```

**X11 Debugging:**
```bash
# List all windows
xprop -root _NET_CLIENT_LIST

# Inspect window properties
xprop -id <window_id>

# Monitor X11 events
xev
```

## Common Patterns

### Error Handling Pattern

```zig
pub fn processCommand(cmd: []const u8) !void {
    const parsed = parseCommand(cmd) catch |err| {
        log.err("Invalid command: {s}, error: {}", .{cmd, err});
        return err;
    };
    
    switch (parsed.type) {
        .show => try handleShow(parsed.data),
        .hide => handleHide(),
        .index => try handleIndex(parsed.data),
    }
}
```

### Resource Cleanup Pattern

```zig
pub fn captureThumbnail(allocator: Allocator, window_id: u32) !Thumbnail {
    const pixmap = try getWindowPixmap(window_id);
    defer releasePixmap(pixmap);
    
    const image_data = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(image_data);
    
    try copyPixmapData(pixmap, image_data);
    return Thumbnail{ .data = image_data, .width = width, .height = height };
}
```

### Event Loop Pattern

```zig
pub fn run(self: *Daemon) !void {
    var pollfds = [_]std.os.pollfd{
        .{ .fd = self.xcb_fd, .events = std.os.POLL.IN, .revents = 0 },
        .{ .fd = self.socket_fd, .events = std.os.POLL.IN, .revents = 0 },
    };
    
    while (self.running) {
        _ = try std.os.poll(&pollfds, 16);
        
        if (pollfds[0].revents & std.os.POLL.IN != 0) {
            try self.handleX11Events();
        }
        
        if (pollfds[1].revents & std.os.POLL.IN != 0) {
            try self.handleSocketCommand();
        }
        
        self.renderer.update();
    }
}
```

## Git Workflow

- Commit after each completed milestone
- Commit messages: Imperative mood, describe what and why
  - Good: "Add window list enumeration via _NET_CLIENT_LIST"
  - Bad: "Fixed stuff", "Updated files"
- No generated files in git (zig-cache, zig-out)
- Keep commits atomic and focused

## Notes for AI Agents

- **Read spec.md first** before implementing any feature
- Follow milestone order - don't skip ahead
- Performance is critical: Profile before optimizing, but keep CLI path minimal
- X11 and raylib are C libraries - use `@cImport` and respect C semantics
- You are running in a container, this means that the user will have to test GUI features on their own machine
- When in doubt about Zig syntax, use `zig build` early and often - compiler errors are helpful
- QML integration is last - daemon should work standalone first
- Run `./setup.sh` before first build to download raylib
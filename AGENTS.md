# FastTab Agent Guidelines

**Project:** FastTab - High-performance window switcher for X11
**Language:** Zig (daemon)
**Spec:** See `spec.md` for architecture, design, and feature requirements.

## Quick Reference

### Build Commands

```bash
# Build the daemon
zig build

# Build in release mode
zig build -Doptimize=ReleaseFast

# Run the daemon
zig build run

# Clean build artifacts
rm -rf .zig-cache zig-out
```

### Testing Commands

```bash
# Run all tests (main module + pure logic tests)
zig build test

# Run with test summary
zig build test --summary all
```

### Linting/Formatting

```bash
# Format all Zig files (in-place)
zig fmt .

# Check formatting without changes
zig fmt --check .
```

## Setup

Run `./setup.sh` to download raylib before building. The `lib/` directory is gitignored.

## Project Structure

```
fasttab/
├── src/
│   ├── main.zig              # Entry point, CLI parsing, daemon loop
│   ├── app.zig               # Alt+Tab switcher state machine (SwitcherState)
│   ├── x11.zig               # XCB bindings, key grabbing, window properties
│   ├── ui.zig                # raylib rendering, window items, UI constants
│   ├── window_scanner.zig    # Window scanning and parallel thumbnail capture
│   ├── thumbnail.zig         # Thumbnail processing, STB resize
│   ├── desktop_icon.zig      # Desktop icon lookup and loading (STB image)
│   ├── layout.zig            # Pure grid layout calculations (no C deps)
│   ├── navigation.zig        # Pure grid navigation functions (no deps)
│   ├── worker.zig            # Background thread for thumbnail refresh
│   ├── queue.zig             # Generic thread-safe queue (no C deps)
│   ├── color.zig             # SIMD BGRA→RGBA conversion (no C deps)
│   ├── stb_impl.c            # STB image library C implementation
│   └── tests/
│       ├── navigation_test.zig   # Navigation index calculations
│       ├── thumbnail_test.zig    # BGRA→RGBA color conversion
│       ├── ui_test.zig           # Grid layout calculations
│       └── worker_test.zig       # Thread-safe queue behavior
├── include/
│   ├── stb_image.h           # STB header for image loading
│   └── stb_image_resize2.h   # STB header for image resizing
├── lib/                      # Downloaded dependencies (gitignored)
│   └── raylib-5.5_linux_amd64/
├── .github/
│   ├── workflows/ci.yml      # CI pipeline (test + release)
│   └── scripts/collate_commits.py  # Changelog generation for releases
├── build.zig                 # Zig build script
├── setup.sh                  # Developer setup script (downloads raylib)
├── spec.md                   # Full project specification
├── README.md                 # Project overview and build instructions
└── LICENSE.md                # GPL-3.0 license
```

### Module Dependencies

| Module | Role | Imports |
|--------|------|---------|
| `main.zig` | Entry point, daemon setup | x11, worker, app |
| `app.zig` | Switcher state machine | x11, ui, worker, thumbnail, navigation |
| `x11.zig` | XCB bindings, key grab | desktop_icon (+ C: xcb) |
| `ui.zig` | raylib rendering | thumbnail, x11, layout (+ C: raylib) |
| `window_scanner.zig` | Window scan + capture | x11, thumbnail |
| `thumbnail.zig` | Image processing | x11, color (+ C: stb) |
| `desktop_icon.zig` | Icon lookup + loading | std (+ C: stb) |
| `worker.zig` | Background refresh thread | x11, thumbnail, window_scanner |
| `layout.zig` | Grid layout math | std only |
| `navigation.zig` | Selection movement | none |
| `queue.zig` | Thread-safe queue | std only |
| `color.zig` | SIMD pixel conversion | std only |

## Testing Strategy

Tests are organized into two tiers:

1. **Main module tests** (`zig build test` via `src/main.zig`): Tests embedded in source files using `test` blocks. These link against XCB, raylib, and all C dependencies. They require a display server and the full library set.

2. **Pure logic tests** (`src/tests/*.zig`): Standalone test files that import individual modules without C dependencies. These test `navigation`, `layout`, `queue`, and `color` in isolation and can run anywhere without X11 or raylib. Each test file gets its module injected via `addImport` in `build.zig`.

Both tiers run together under `zig build test`.

## Code Style

### Zig Conventions

**Naming:**
- Types: `PascalCase` (e.g., `SwitcherState`, `GridLayout`, `ProcessedWindow`)
- Functions: `camelCase` (e.g., `handleAltTab`, `processRawCapture`, `calculateItemWidth`)
- Variables: `snake_case` (e.g., `window_id`, `thumbnail_height`)
- Constants: `SCREAMING_SNAKE_CASE` (e.g., `MAX_GRID_WIDTH`, `THUMBNAIL_HEIGHT`)

**Imports:**
```zig
const std = @import("std");
const x11 = @import("x11.zig");    // internal modules by filename
const ui = @import("ui.zig");
const rl = ui.rl;                   // raylib accessed through ui module
```

**Error handling:**
- Use Zig's error unions (`!Type`)
- Propagate errors with `try` or handle explicitly
- Define custom error sets for domain-specific errors
- Never ignore errors silently

**Memory management:**
- Explicit allocators passed as parameters
- No hidden allocations
- Use `defer` for cleanup
- `errdefer` for cleanup on error paths

**Formatting:**
- 4 spaces indentation (enforced by `zig fmt`)
- 100 character line limit (soft guideline)
- Always run `zig fmt` before committing

## Debugging

**Daemon Logging:**
```zig
const log = std.log.scoped(.fasttab);

log.debug("Captured window {d}: {s}", .{window_id, title});
log.err("Failed to connect to X11: {}", .{err});
```

**X11 Debugging:**
```bash
xprop -root _NET_CLIENT_LIST      # List all windows
xprop -id <window_id>             # Inspect window properties
xev                                # Monitor X11 events
```

## Notes for AI Agents

- **Read spec.md first** before implementing any feature
- Follow milestone order - don't skip ahead
- Performance is critical: Profile before optimizing, but keep CLI path minimal
- X11 and raylib are C libraries - use `@cImport` and respect C semantics
- You are running in a container, this means that the user will have to test GUI features on their own machine
- When in doubt about Zig syntax, use `zig build` early and often - compiler errors are helpful
- Run `./setup.sh` before first build to download raylib
- Modules without C deps (`layout`, `navigation`, `queue`, `color`) are the easiest to test and modify

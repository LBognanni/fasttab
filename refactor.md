# Queue System Refactoring Plan

## Problem Statement

The current architecture has several issues:

1. **Full-snapshot updates**: Every scan cycle, the worker sends a complete `RefreshResult` containing ALL windows with ALL thumbnail data, even when nothing changed. The main thread must diff this against its own state to figure out what's new, removed, or updated.

2. **Excessive data copying**: Thumbnail pixel data is allocated by the scanner, duplicated by the worker for the queue, then taken by the main thread. Icon data is similarly duplicated from the worker's icon cache into every `ThumbnailUpdate`. This happens every cycle (~1s) for every window.

3. **Monolithic update payload**: `ThumbnailUpdate` bundles together thumbnail data, icon data, title, and WM_CLASS. This means icon data is re-sent for every window even though icons rarely change and are shared across windows of the same class.

4. **Duplicated state management**: Both the worker and main thread independently track window lists, and the main thread must reconstruct what happened (additions, removals, updates) from a flat snapshot. The `removeClosedWindows` + `applyWindowUpdates` logic in `app.zig` is doing work the worker already knows the answer to.

5. **Unused generic Queue**: `queue.zig` defines a generic `Queue(T)` but production code uses a hand-written `UpdateQueue` in `worker.zig` instead.

6. **Fragile ownership conventions**: Using `"(unknown)"` string literals as sentinels to indicate "not owned" is error-prone. Every free site must check `std.mem.eql(u8, str, "(unknown)")`.

---

## Proposed Architecture

### Overview

```
Worker Thread                          TaskQueue (FIFO)              Main Thread

Maintains TrackedWindows               Bounded list of               Maintains DisplayWindows
(persistent across scans)              UpdateTask events             (window_id -> GPU texture)

Each scan cycle:                                                    Each frame:
  1. Scan window list                                                 1. Drain all pending tasks
  2. Compare against tracked state                                    2. Apply each task:
  3. Detect changes                                                      - window_added -> upload texture
  4. Queue only what changed  -------> push(task) --------->            - window_removed -> unload
  5. Update tracked state                                                - thumbnail_updated -> re-upload
                                                                         - title_updated -> update string
                                                                         - icon_added -> upload icon
```

The key shift: **the worker detects changes and tells the main thread what happened**, instead of the main thread figuring it out from snapshots.

---

## Data Structures

### Worker Side (`worker.zig`)

```zig
/// A window tracked by the background worker across scan cycles.
const TrackedWindow = struct {
    window_id: xcb_window_t,
    thumbnail: ?Thumbnail,          // Owned RGBA buffer (kept for change detection)
    title: []u8,                    // Owned title string
    icon_id: []u8,                  // WM_CLASS (links to icon cache)
    title_version: u32,             // Incremented when title changes
    thumbnail_version: u32,         // Incremented when thumbnail changes
    allocator: Allocator,

    fn deinit(self: *TrackedWindow) void { ... }
};

// Worker state:
//   tracked_windows: AutoHashMap(xcb_window_t, TrackedWindow)
//   icon_cache: StringHashMap(IconEntry)
```

The worker keeps `tracked_windows` alive across scan cycles. This replaces the current pattern of rebuilding `known_windows` (a simple set) and converting scan results to `RefreshResult` every time.

### Icon Cache (`worker.zig`)

```zig
/// A cached application icon, shared across all windows of the same WM_CLASS.
const IconEntry = struct {
    data: Thumbnail,                // Owned 64x64 RGBA buffer
    app_name: []u8,                 // Owned, same as the icon_id key
};

// icon_cache: StringHashMap(IconEntry) keyed by WM_CLASS
```

No change in concept from today, but the icon data is **never duplicated for the queue**. Instead, a single `icon_added` task is queued when a new icon is first fetched, carrying a copy of the pixel data. Subsequent windows with the same WM_CLASS reference the cached icon by ID only.

### Queue Messages (`worker.zig`)

```zig
/// An individual update event from the worker to the main thread.
const UpdateTask = union(enum) {
    /// A new window appeared. Carries initial thumbnail + metadata.
    window_added: struct {
        window_id: xcb_window_t,
        title: []u8,                    // Owned
        thumbnail_data: []u8,           // Owned RGBA pixels
        thumbnail_width: u32,
        thumbnail_height: u32,
        icon_id: []u8,                  // Owned WM_CLASS string
        thumbnail_version: u32,
    },

    /// A window was closed.
    window_removed: struct {
        window_id: xcb_window_t,
    },

    /// Thumbnail content changed for an existing window.
    thumbnail_updated: struct {
        window_id: xcb_window_t,
        thumbnail_data: []u8,           // Owned RGBA pixels
        thumbnail_width: u32,
        thumbnail_height: u32,
        thumbnail_version: u32,
    },

    /// Title changed for an existing window.
    title_updated: struct {
        window_id: xcb_window_t,
        title: []u8,                    // Owned
        title_version: u32,
    },

    /// A new application icon is available (keyed by WM_CLASS).
    /// All windows sharing this icon_id should use this texture.
    icon_added: struct {
        icon_id: []u8,                  // Owned WM_CLASS string
        icon_data: []u8,                // Owned RGBA pixels
        icon_width: u32,
        icon_height: u32,
    },

    fn deinit(self: *UpdateTask, allocator: Allocator) void {
        // Free all owned slices based on active tag
    }
};
```

### Queue (`queue.zig`)

Replace the single-slot `Queue(T)` and hand-written `UpdateQueue` with a FIFO task queue:

```zig
/// Thread-safe FIFO queue for passing update tasks from worker to main thread.
const TaskQueue = struct {
    mutex: Mutex = .{},
    tasks: ArrayList(UpdateTask),
    should_stop: bool = false,
    window_visible: bool = false,
    allocator: Allocator,

    fn init(allocator: Allocator) TaskQueue { ... }

    /// Worker calls this to enqueue an update task.
    fn push(self: *TaskQueue, task: UpdateTask) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tasks.append(task) catch {
            // On OOM, discard the task (free its data)
            var t = task;
            t.deinit(self.allocator);
        };
    }

    /// Main thread calls this to take all pending tasks.
    /// Returns owned slice; caller processes and frees each task.
    fn drainAll(self: *TaskQueue, out: *ArrayList(UpdateTask)) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.appendSlice(self.tasks.items) catch {};
        self.tasks.clearRetainingCapacity();
    }

    fn requestStop(self: *TaskQueue) void { ... }
    fn shouldStop(self: *TaskQueue) bool { ... }
    fn setWindowVisible(self: *TaskQueue, visible: bool) void { ... }
    fn isWindowVisible(self: *TaskQueue) bool { ... }

    fn deinit(self: *TaskQueue) void {
        // Free any unconsumed tasks
        for (self.tasks.items) |*task| task.deinit(self.allocator);
        self.tasks.deinit();
    }
};
```

The `drainAll` approach is efficient: one mutex acquisition per frame, and the main thread processes tasks without holding the lock.

### Main Thread Side (`app.zig` / `ui.zig`)

```zig
/// A window as seen by the UI/rendering layer.
const DisplayWindow = struct {
    window_id: xcb_window_t,
    thumbnail_texture: rl.Texture2D,    // GPU handle
    icon_id: []const u8,                // WM_CLASS (indexes into icon_texture_cache)
    title: []const u8,                  // Owned
    title_version: u32,
    thumbnail_version: u32,
    display_width: u32,                 // Computed by layout
    display_height: u32,                // Computed by layout
};
```

Changes from the current `WindowItem`:
- **Removed `thumbnail: Thumbnail`**: The main thread no longer keeps raw pixel data. Once uploaded to GPU, the CPU-side buffer is freed immediately. (Currently the raw data is kept alongside the texture.)
- **Removed `icon_texture: ?rl.Texture2D`**: Icon textures are looked up from `icon_texture_cache` by `icon_id` at render time (or cached in the struct if lookup per-frame is too costly). This eliminates the need to update icon_texture on every item when a new icon arrives.
- **Removed `wm_class`**: Renamed to `icon_id` for clarity.
- **Added version counters**: Enable skipping redundant texture uploads.

The `icon_texture_cache: StringHashMap(rl.Texture2D)` stays in `App`, keyed by `icon_id` (WM_CLASS).

---

## Worker Logic Changes (`worker.zig`)

### Current Flow (per scan cycle)

1. Build `known_list` from `known_windows` hashmap
2. Call `scanAndProcess()` which captures ALL windows (or only new ones when hidden)
3. Iterate all `ProcessedWindow` results, duplicate everything into `ThumbnailUpdate`
4. Push single `RefreshResult` to queue
5. Rebuild `known_windows` from scan result

### New Flow (per scan cycle)

```
fn scanCycle(tracked: *HashMap, icon_cache: *IconCache, queue: *TaskQueue, conn: *Connection) void {
    // 1. Get current window list from X11
    const current_ids = x11.getWindowList(...);

    // 2. Detect removed windows
    for (tracked.keys()) |wid| {
        if (wid not in current_ids) {
            queue.push(.{ .window_removed = .{ .window_id = wid } });
            tracked.remove(wid);  // free TrackedWindow data
        }
    }

    // 3. For each current window, detect additions and changes
    for (current_ids) |wid| {
        if (tracked.get(wid)) |existing| {
            // --- Existing window: check for changes ---

            // Re-capture thumbnail (only when switcher is visible, same optimization as today)
            if (queue.isWindowVisible()) {
                const new_thumb = captureAndProcess(wid);
                if (new_thumb differs from existing.thumbnail) {
                    existing.thumbnail_version += 1;
                    queue.push(.{ .thumbnail_updated = .{
                        .window_id = wid,
                        .thumbnail_data = dupe(new_thumb.data),
                        .thumbnail_version = existing.thumbnail_version,
                        ...
                    }});
                    existing.thumbnail = new_thumb;  // replace stored copy
                }
            }

            // Check title
            const new_title = x11.getWindowTitle(wid);
            if (!eql(new_title, existing.title)) {
                existing.title_version += 1;
                queue.push(.{ .title_updated = .{
                    .window_id = wid,
                    .title = dupe(new_title),
                    .title_version = existing.title_version,
                }});
                existing.title = new_title;
            }
        } else {
            // --- New window ---
            const thumb = captureAndProcess(wid);
            const title = x11.getWindowTitle(wid);
            const wm_class = x11.getWindowClass(wid);

            // Ensure icon is cached; if new, queue icon_added
            if (!icon_cache.contains(wm_class)) {
                if (fetchIcon(wid, wm_class)) |icon| {
                    icon_cache.put(wm_class, icon);
                    queue.push(.{ .icon_added = .{
                        .icon_id = dupe(wm_class),
                        .icon_data = dupe(icon.data),
                        ...
                    }});
                }
            }

            // Queue window_added
            tracked.put(wid, TrackedWindow{ ... });
            queue.push(.{ .window_added = .{
                .window_id = wid,
                .title = dupe(title),
                .thumbnail_data = dupe(thumb.data),
                .icon_id = dupe(wm_class),
                .thumbnail_version = 1,
            }});
        }
    }
}
```

Key differences from today:
- **No more `RefreshResult` / `ThumbnailUpdate`**: replaced by individual `UpdateTask` events.
- **No more `scanAndProcess()` result conversion**: The worker integrates scanning and change detection into one pass.
- **Persistent tracked state**: `TrackedWindow` lives across cycles instead of being rebuilt.
- **Icons queued once**: `icon_added` is only sent when a new WM_CLASS is first encountered.
- **Thumbnails only duplicated on change**: If the thumbnail didn't change, no data is copied.

### Thumbnail Change Detection

For the initial implementation, use a simple approach: always consider a recaptured thumbnail as "changed." This matches the current behavior (every visible-mode scan sends all thumbnails). The `thumbnail_version` counter still provides value: the main thread can skip re-upload if it already has the latest version (e.g., if two scans complete before the main thread processes them).

As a future optimization, a fast hash (e.g., `std.hash.Wyhash`) of the pixel data could be stored alongside each `TrackedWindow` to detect actual content changes and skip duplicate uploads.

---

## Main Thread Logic Changes (`app.zig`)

### Current Flow

```
processWorkerUpdate(result):
    build set of current window IDs from result
    removeClosedWindows(set)       // scan items, compare against set
    applyWindowUpdates(result)     // for each ThumbnailUpdate, find/update/add
    adjust selected_index
    recalculate layout
```

### New Flow

```
drainUpdateQueue():
    queue.drainAll(&pending_tasks)
    for (pending_tasks) |*task| {
        switch (task) {
            .window_added => |data| {
                texture = uploadToGPU(data.thumbnail_data);
                free(data.thumbnail_data);  // no longer needed after upload
                icon_tex = icon_texture_cache.get(data.icon_id);
                append DisplayWindow { .thumbnail_texture = texture, .icon_id = data.icon_id, ... };
            },
            .window_removed => |data| {
                find item by data.window_id;
                unloadTexture(item.thumbnail_texture);
                remove from list;
            },
            .thumbnail_updated => |data| {
                find item by data.window_id;
                if (data.thumbnail_version > item.thumbnail_version) {
                    unloadTexture(item.thumbnail_texture);
                    item.thumbnail_texture = uploadToGPU(data.thumbnail_data);
                    item.thumbnail_version = data.thumbnail_version;
                }
                free(data.thumbnail_data);
            },
            .title_updated => |data| {
                find item by data.window_id;
                if (data.title_version > item.title_version) {
                    free(item.title);
                    item.title = data.title;  // take ownership
                    item.title_version = data.title_version;
                } else {
                    free(data.title);
                }
            },
            .icon_added => |data| {
                texture = uploadToGPU(data.icon_data);
                free(data.icon_data);
                icon_texture_cache.put(data.icon_id, texture);
                // No need to update individual items - they look up by icon_id
            },
        }
    }
    pending_tasks.clearRetainingCapacity();
    if (any_changes) { recalculate layout; }
```

Key simplifications:
- **No more diffing**: The main thread doesn't compare against a snapshot. It just applies events.
- **No raw pixel data retained**: `thumbnail_data` is freed immediately after GPU upload. The `DisplayWindow` only holds the `Texture2D` handle.
- **Icon assignment is implicit**: `DisplayWindow` stores `icon_id`, and the renderer looks up `icon_texture_cache.get(icon_id)` when drawing. No need to iterate all items and assign `icon_texture` when a new icon arrives.

---

## Rendering Changes (`ui.zig`)

The `WindowItem` struct is replaced by `DisplayWindow`. The `renderSwitcher` function changes minimally:

- Instead of `item.icon_texture`, the renderer receives a reference to `icon_texture_cache` and does `icon_texture_cache.get(item.icon_id)` for each item.
- The `thumbnail: Thumbnail` field is gone, so layout calculation uses the texture dimensions directly (`item.thumbnail_texture.width/height`) instead of `item.thumbnail.width/height`.
- `display_width` and `display_height` remain for layout purposes.

Alternatively, for rendering performance, the icon texture lookup can be cached in `DisplayWindow.icon_texture` as a non-owning copy of the texture handle (same as today). This gets set when `icon_added` is processed or when the display window is created. This avoids a hash lookup per item per frame.

---

## File-by-File Changes

### `queue.zig`
- Remove the generic `Queue(T)` type
- Add `TaskQueue` struct (FIFO queue of `UpdateTask` with mutex)
- Add `UpdateTask` tagged union definition with `deinit` method
- Keep the queue generic enough for tests (or move `UpdateTask` to `worker.zig` and keep `TaskQueue` generic over any type with `deinit`)

### `worker.zig`
- Remove `ThumbnailUpdate`, `RefreshResult`, `UpdateQueue`
- Add `TrackedWindow` struct
- Rewrite `backgroundWorker()` to maintain persistent `tracked_windows` state
- Change detection: compare scan results against `tracked_windows`, push individual `UpdateTask` events
- Keep `icon_cache` but only queue `icon_added` on first encounter
- The worker still calls `window_scanner.scanAndProcess()` for the actual X11 capture, but the result is compared against tracked state rather than blindly forwarded

### `app.zig`
- Replace `processWorkerUpdate(result: *RefreshResult)` with `drainUpdateQueue()`
- Replace `items: ArrayList(WindowItem)` with `items: ArrayList(DisplayWindow)`
- Remove `removeClosedWindows()` and `applyWindowUpdates()` (replaced by per-task switch handling)
- Update `init()` to wait for initial tasks from queue (instead of a single `RefreshResult`)
- Keep `icon_texture_cache` but it's now populated by `icon_added` tasks
- Update all methods that reference `WindowItem` fields

### `ui.zig`
- Replace `WindowItem` with `DisplayWindow` (or import from `app.zig`)
- Remove `thumbnail: Thumbnail` from the struct
- Update `calculateGridLayout()` to use texture dimensions
- Update `renderSwitcher()` to take icon cache or resolve icons from `DisplayWindow.icon_id`
- Remove `loadTextureFromThumbnail()` from the public API (texture upload moves to `app.zig` directly, or keep it as a helper)

### `main.zig`
- Update queue type from `UpdateQueue` to `TaskQueue`
- Update initial-result handling: drain initial tasks instead of popping a single `RefreshResult`
- Update the main loop: call `application.drainUpdateQueue()` instead of `processWorkerUpdate()`

### `window_scanner.zig`
- No major changes. It continues to produce `ScanResult` with `ProcessedWindow` items. The worker consumes these and detects changes.

### `thumbnail.zig`
- No changes. Still provides `processRawCapture()` and `processIconArgb()`.

---

## Ownership Model

Clear ownership rules to eliminate the `"(unknown)"` sentinel pattern:

| Data | Owner | Lifetime |
|------|-------|----------|
| `TrackedWindow.thumbnail.data` | Worker | Until window removed or thumbnail replaced |
| `TrackedWindow.title` | Worker | Until window removed or title replaced |
| `IconEntry.data` | Worker's `icon_cache` | Until worker shutdown |
| `UpdateTask` payload data (thumbnail_data, title, icon_data, icon_id) | Queue consumer (main thread) | Freed after processing (upload to GPU or assign to DisplayWindow) |
| `DisplayWindow.title` | Main thread | Until window removed or title replaced |
| `DisplayWindow.thumbnail_texture` | Main thread (GPU) | Until window removed or thumbnail replaced |
| Icon textures in `icon_texture_cache` | Main thread (GPU) | Until app shutdown |

**No more sentinel strings.** Use `?[]u8` (optional) where a value might be absent. All owned strings are allocated and freed explicitly.

---

## Migration Notes

### Initialization Sequence

Currently, `main.zig` waits for a single `RefreshResult` via `popBlocking()`. With the new system, the initial scan produces multiple `UpdateTask` events (one `window_added` per window, one `icon_added` per unique WM_CLASS).

The initialization can either:
- **Option A**: Keep `popBlocking()` but wait for a special `scan_complete` sentinel task that the worker pushes after its first full scan. The main thread then drains all pending tasks.
- **Option B (simpler)**: The worker pushes a `scan_complete` task after the first cycle. `main.zig` busy-waits until it sees this task, then drains everything. The `scan_complete` task is only used during init.

Recommendation: **Option B**. Add a `scan_complete` variant to `UpdateTask` that signals the first scan finished. This is consumed once during init and ignored afterwards.

### Backward Compatibility

This is a complete rewrite of the queue/worker interface. No backward compatibility is needed since there are no external consumers. The `window_scanner.zig`, `thumbnail.zig`, `x11.zig`, `layout.zig`, and `navigation.zig` modules are unaffected.

---

## Summary of Benefits

| Aspect | Before | After |
|--------|--------|-------|
| Data per cycle | Full snapshot of all windows | Only what changed |
| Thumbnail copies | Every window, every cycle | Only on change |
| Icon data transfer | Duplicated per window per cycle | Once per WM_CLASS, ever |
| Main thread diffing | Builds hash set, scans for removals/additions | Direct event handling |
| Queue type | Single-slot, last-writer-wins | FIFO, all events preserved |
| Raw pixel data on main thread | Kept alongside GPU texture | Freed after GPU upload |
| Ownership convention | `"(unknown)"` sentinel strings | Explicit optional types |
| Worker state | Rebuilt each cycle (`known_windows` is just a set) | Persistent `TrackedWindow` map |


---

# Detailed file by file changes

 Queue System Refactoring Plan

 Replace the "full snapshot every cycle" worker-to-main-thread communication with event-based updates. The worker detects changes and sends individual UpdateTask events through a FIFO
 queue.

 Files to Change (in order)

 1. src/worker.zig - Major rewrite
 2. src/ui.zig - Moderate changes
 3. src/app.zig - Major rewrite
 4. src/main.zig - Minor wiring changes

 Files that do NOT change: queue.zig, window_scanner.zig, thumbnail.zig, layout.zig, navigation.zig, x11.zig, build.zig, all test files.

 ---
 Step 1: src/worker.zig

 Remove

 - ThumbnailUpdate struct
 - RefreshResult struct
 - UpdateQueue struct

 Add UpdateTask (tagged union)

```
 pub const UpdateTask = union(enum) {
     window_added: WindowAdded,
     window_removed: WindowRemoved,
     thumbnail_updated: ThumbnailUpdated,
     title_updated: TitleUpdated,
     icon_added: IconAdded,

     pub const WindowAdded = struct {
         window_id: x11.xcb.xcb_window_t,
         title: []const u8,           // owned
         icon_id: []const u8,          // owned (WM_CLASS)
         thumbnail_data: []u8,         // owned RGBA
         thumbnail_width: u32,
         thumbnail_height: u32,
         thumbnail_version: u32,
         title_version: u32,
         allocator: std.mem.Allocator,
     };
     pub const WindowRemoved = struct { window_id: x11.xcb.xcb_window_t };
     pub const ThumbnailUpdated = struct {
         window_id: x11.xcb.xcb_window_t,
         thumbnail_data: []u8,         // owned RGBA
         thumbnail_width: u32,
         thumbnail_height: u32,
         thumbnail_version: u32,
         allocator: std.mem.Allocator,
     };
     pub const TitleUpdated = struct {
         window_id: x11.xcb.xcb_window_t,
         title: []const u8,            // owned
         title_version: u32,
         allocator: std.mem.Allocator,
     };
     pub const IconAdded = struct {
         icon_id: []const u8,           // owned (WM_CLASS)
         icon_data: []u8,               // owned RGBA
         icon_width: u32,
         icon_height: u32,
         allocator: std.mem.Allocator,
     };

     pub fn deinit(self: *UpdateTask) void {
         // Free all owned slices based on active tag
     }
 };
```

 Add TaskQueue (FIFO, ArrayList-based)

```
 pub const TaskQueue = struct {
     mutex: std.Thread.Mutex = .{},
     tasks: std.ArrayList(UpdateTask),
     should_stop: bool = false,
     window_visible: bool = true,
     first_scan_done: bool = false,

     pub fn init(allocator) TaskQueue
     pub fn push(self, task: UpdateTask) void     // append to list; on OOM, deinit the task
     pub fn drainAll(self, out: *ArrayList(UpdateTask)) usize  // move all to caller, return count
     pub fn requestStop / shouldStop / setWindowVisible / isWindowVisible
     pub fn setFirstScanDone / waitForFirstScan(timeout_ms) bool  // busy-wait with 10ms sleep
     pub fn deinit(self) void                     // free any unconsumed tasks
 };
 ```

 Add TrackedWindow (private, for change detection)

```
 const TrackedWindow = struct {
     title: []const u8,        // owned copy for comparison
     icon_id: []const u8,      // owned copy (WM_CLASS)
     title_version: u32,
     thumbnail_version: u32,
     allocator: std.mem.Allocator,
     fn deinit(self: *TrackedWindow) void  // free title and icon_id
 };
 ```

 Rewrite backgroundWorker

 Worker maintains across cycles:
 - known_windows: AutoHashMap(window_id, void) - for scanner's known_windows optimization (same as today)
 - tracked_windows: AutoHashMap(window_id, TrackedWindow) - for change detection (NEW)
 - icon_cache: StringHashMap(Thumbnail) - for icon caching (same as today)
 - pushed_icons: StringHashMap(void) - tracks which icon_ids have been sent as icon_added

 Each scan cycle:
 1. Build known_list from known_windows, call scanAndProcess()
 2. Detect removals: iterate tracked_windows keys, if not in scan_result.window_ids -> push window_removed, remove from tracked
 3. Process captures: for each ProcessedWindow with a thumbnail:
   - If in tracked_windows (existing): compare item.title with tracked.title, push title_updated if different; always push thumbnail_updated with duped pixel data
   - If NOT in tracked_windows (new): fetch wm_class, check/push icon_added if not yet pushed, push window_added, add to tracked_windows
 4. Update known_windows from scan_result.window_ids
 5. After first cycle: queue.setFirstScanDone()

 Title source: Use item.title from ProcessedWindow (already fetched by scanner), NOT re-fetch from X11.

 Ownership pattern: Eliminate sentinel strings. When getWindowTitle/getWindowClass returns literal "(unknown)", dupe it to get an owned copy. When it returns an already-allocated string,
  take ownership directly:
```
 const title_owned = if (std.mem.eql(u8, item.title, "(unknown)"))
     allocator.dupe(u8, "(unknown)") catch continue
 else
     allocator.dupe(u8, item.title) catch continue;
 // title_owned is always an owned allocation
```

 Icon ordering: Push icon_added BEFORE window_added for the same WM_CLASS so the main thread has the icon cached when it processes the window.

 ---
 Step 2: src/ui.zig

 Replace WindowItem with DisplayWindow

```
 pub const DisplayWindow = struct {
     id: x11.xcb.xcb_window_t,
     title: []const u8,               // owned
     thumbnail_texture: rl.Texture2D,  // GPU handle
     icon_texture: ?rl.Texture2D,      // non-owning copy from icon_texture_cache
     icon_id: []const u8,              // owned (WM_CLASS)
     title_version: u32,
     thumbnail_version: u32,
     source_width: u32,                // original thumbnail width (for layout)
     source_height: u32,               // original thumbnail height (for layout)
     display_width: u32,
     display_height: u32,
 };
```

 Key differences from WindowItem:
 - No thumbnail: Thumbnail (raw pixel data not kept after GPU upload)
 - source_width/source_height replace thumbnail.width/height for layout
 - thumbnail_texture instead of texture
 - icon_id instead of wm_class
 - Version counters added

 Update functions

 - calculateGridLayout(items: []DisplayWindow, ...) - use item.source_width/source_height
 - calculateRowWidth(items: []DisplayWindow, ...) - only accesses display_width, minimal change
 - renderSwitcher(items: []DisplayWindow, ...) - use item.thumbnail_texture instead of item.texture; icon rendering unchanged
 - loadTextureFromThumbnail - keep as-is, still used by app.zig

 ---
 Step 3: src/app.zig

 Update App struct fields

```
 items: std.ArrayList(ui.DisplayWindow),          // was ArrayList(ui.WindowItem)
 update_queue: ?*worker.TaskQueue,                 // was ?*worker.UpdateQueue
 temp_tasks: std.ArrayList(worker.UpdateTask),     // NEW: reusable buffer for drainAll
 ```

 Rewrite App.init

 New signature (removes initial_result and mouse_pos params):

```
 pub fn init(allocator, task_queue: *TaskQueue, daemon_mode, xcb_conn, xcb_root, xcb_atoms) !Self
```

 Flow:
 1. Create empty items list, icon_texture_cache, temp_tasks buffer
 2. Create raylib window with default size (800x600, starts hidden anyway)
 3. Load font
 4. Build App struct
 5. Call self.drainUpdateQueue() to process initial events (uploads textures)
 6. Return self

 Add drainUpdateQueue (replaces processWorkerUpdate)

 `pub fn drainUpdateQueue(self: *Self) void`

 Calls queue.drainAll(&self.temp_tasks), then iterates tasks:
 - window_added: upload thumbnail_data to GPU via loadTextureFromThumbnail, free pixel data, create DisplayWindow, look up icon from cache. Transfer ownership of title and icon_id.
 - window_removed: find item by id, unload texture, free title/icon_id, orderedRemove.
 - thumbnail_updated: find item, if version newer: upload new texture, unload old, update version. Free pixel data.
 - title_updated: find item, if version newer: free old title, take ownership of new. Else free new title.
 - icon_added: upload icon to GPU, put in icon_texture_cache, update all items with matching icon_id. Free task's icon_id and icon_data.

 After processing: adjust selected_index, recalculate layout if anything changed.

 After transferring ownership from a task, set the task's pointer to &[_]u8{} to prevent double-free when clearing temp buffer.

 Delete old methods

 - processWorkerUpdate
 - removeClosedWindows
 - applyWindowUpdates
 - updateExistingWindow
 - addNewWindow
 - processIconForItem

 Update deinit

 Free DisplayWindow fields: always free title and icon_id (no sentinel check), unload thumbnail_texture, don't unload icon_texture (shared via cache). Clean up temp_tasks.

 Update other methods

 - reorderByStacking: change `ArrayList(ui.WindowItem)` to `ArrayList(ui.DisplayWindow)`
 - hideWindow/showWindow: queue method names unchanged
 - render, confirmSwitching, navigation methods: field access changes (.id stays same)

 ---
 Step 4: src/main.zig

 - Create var task_queue = worker.TaskQueue.init(allocator) instead of UpdateQueue{}
 - Spawn worker with &task_queue
 - Replace popBlocking(10000) with task_queue.waitForFirstScan(10000)
 - Remove mouse_pos query before init (moved to showWindow)
 - Call App.init(allocator, &task_queue, true, conn.conn, conn.root, conn.atoms)
 - Main loop: replace queue pop + processWorkerUpdate with application.drainUpdateQueue()
 - Shutdown: task_queue.requestStop(), join, task_queue.deinit()

 ---
 Verification

 1. zig build - should compile without errors
 2. zig build test - all existing tests should pass (queue.zig, layout.zig, navigation.zig, color.zig tests unchanged)
 3. zig fmt --check . - formatting check
 4. Manual test on user's machine: run daemon, verify Alt+Tab shows windows with correct thumbnails, icons, and titles
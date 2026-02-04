
Instructions: Implement GLX Texture Binding for Efficient X11 Window Thumbnails

Overview

Replace the xcb_get_image capture pipeline with GLX texture binding. Currently, every thumbnail refresh involves: xcb_get_image (wire copy) -> allocator
copy -> stb resize -> BGRA-to-RGBA SIMD conversion -> raylib texture upload. With GLX, the composite pixmap is bound directly as an OpenGL texture on the
  GPU -- zero copies, zero CPU processing.

Current Data Flow (to be replaced)

Background Thread (worker.zig):              Main Thread (app.zig):
  x11.captureRawImage (x11.zig:432)            drainUpdateQueue (app.zig:221)
    -> RawCapture (BGRA bytes on CPU)             -> UpdateTask (RGBA bytes)
  thumbnail.processRawCapture                       -> ui.loadTextureFromThumbnail
    -> Thumbnail (256px high, RGBA)                   -> rl.LoadTextureFromImage (GPU upload)
  worker pushes UpdateTask to queue               -> DisplayWindow
    (transfers owned pixel data)                  render -> rl.DrawTexturePro

Target data flow:

Main Thread only:
  createWindowTexture
    -> WindowTexture (GL texture ID bound to composite pixmap, no pixel data)
    -> .toRaylibTexture() -> rl.Texture2D (same GPU handle)
  Damage event -> rebind texture
  render -> rl.DrawTexturePro (GPU scales full-res texture on the fly)

Critical Constraint: Threading

glXBindTexImageEXT is an OpenGL call. It MUST execute on the thread that owns the GL context -- the main thread where raylib runs. The current background
  worker (worker.zig:217) has its own XCB connection and calls captureRawImage + processRawCapture there. With GLX, the worker can still discover windows
and fetch titles/icons, but all GL texture operations must move to the main thread.

---
Implementation Steps

Step 1: Extend Connection to Mixed Xlib/XCB

File: src/x11.zig

The current Connection struct (line 135) uses xcb_connect directly. GLX requires an Xlib Display*. Replace with a mixed connection where Xlib opens the
display and XCB is obtained from it.

Changes to @cImport block (line 7):

Add Xlib, X11-xcb, and GLX headers alongside existing XCB headers:

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_image.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("xcb/damage.h");
});

pub const xlib = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glxext.h");
});

Note: Xlib and XCB headers conflict if included in the same @cImport block. Use separate blocks.

Changes to Connection struct (line 135):

Add fields for the Xlib display, GLX function pointers, FBConfig, and damage event base:

pub const Connection = struct {
    display: *xlib.Display,           // NEW: Xlib display (owns the connection)
    conn: *xcb.xcb_connection_t,      // obtained via XGetXCBConnection
    screen: *xcb.xcb_screen_t,
    root: xcb.xcb_window_t,
    atoms: Atoms,

    // GLX extension function pointers
    glx_bind: *const fn (*xlib.Display, xlib.GLXPixmap, c_int, ?[*]const c_int) callconv(.C) void,
    glx_release: *const fn (*xlib.Display, xlib.GLXPixmap, c_int) callconv(.C) void,
    fb_config: xlib.GLXFBConfig,

    // Damage extension
    damage_event_base: u8,
};

Changes to Connection.init() (line 141):

Replace xcb_connect with XOpenDisplay + XGetXCBConnection:

pub fn init() X11Error!Connection {
    const display = xlib.XOpenDisplay(null) orelse return error.ConnectionFailed;

    const conn = xlib.XGetXCBConnection(display);
    if (conn == null) {
        _ = xlib.XCloseDisplay(display);
        return error.ConnectionFailed;
    }

    // Let XCB own the event queue (we poll with xcb_poll_for_event)
    _ = xlib.XSetEventQueueOwner(display, xlib.XCBOwnsEventQueue);

    if (xcb.xcb_connection_has_error(@ptrCast(conn)) != 0) {
        _ = xlib.XCloseDisplay(display);
        return error.ConnectionError;
    }

    const screen_num = xlib.DefaultScreen(display);
    const setup = xcb.xcb_get_setup(@ptrCast(conn));
    var iter = xcb.xcb_setup_roots_iterator(setup);
    var i: c_int = 0;
    while (i < screen_num) : (i += 1) {
        xcb.xcb_screen_next(&iter);
    }
    const screen = iter.data orelse {
        _ = xlib.XCloseDisplay(display);
        return error.NoScreen;
    };

    const xcb_conn: *xcb.xcb_connection_t = @ptrCast(conn);
    const atoms = try initAtoms(xcb_conn);
    try initComposite(xcb_conn);

    const damage_base = try initDamage(xcb_conn);

    const bind_fn = xlib.glXGetProcAddress("glXBindTexImageEXT") orelse return error.GLXExtensionMissing;
    const release_fn = xlib.glXGetProcAddress("glXReleaseTexImageEXT") orelse return error.GLXExtensionMissing;

    const fb_config = try selectFBConfig(display, screen_num);

    return Connection{
        .display = display,
        .conn = xcb_conn,
        .screen = screen,
        .root = screen.root,
        .atoms = atoms,
        .glx_bind = @ptrCast(bind_fn),
        .glx_release = @ptrCast(release_fn),
        .fb_config = fb_config,
        .damage_event_base = damage_base,
    };
}

Update Connection.deinit() (line 178):

Replace xcb_disconnect with XCloseDisplay (closes both Xlib and the underlying XCB connection):

pub fn deinit(self: *Connection) void {
    _ = xlib.XCloseDisplay(self.display);
}

Worker connection: The background worker (worker.zig:219) also calls Connection.init(). The worker does NOT need GLX or damage -- it only needs XCB for
window discovery and title/icon fetching. Add a separate Connection.initXcbOnly() that uses the old xcb_connect code for the worker.

Step 2: FBConfig Selection and Damage Init

File: src/x11.zig -- add these new functions:

fn selectFBConfig(display: *xlib.Display, screen: c_int) X11Error!xlib.GLXFBConfig {
    const attribs = [_]c_int{
        xlib.GLX_DRAWABLE_TYPE,    xlib.GLX_PIXMAP_BIT,
        xlib.GLX_BIND_TO_TEXTURE_RGBA_EXT, xlib.True,
        xlib.GLX_BIND_TO_TEXTURE_TARGETS_EXT, xlib.GLX_TEXTURE_2D_BIT_EXT,
        xlib.GLX_DOUBLEBUFFER,     xlib.False,
        xlib.GLX_RED_SIZE,         8,
        xlib.GLX_GREEN_SIZE,       8,
        xlib.GLX_BLUE_SIZE,        8,
        xlib.GLX_ALPHA_SIZE,       8,
        xlib.GLX_DEPTH_SIZE,       0,
        0, // None terminator
    };

    var num_configs: c_int = 0;
    const configs = xlib.glXChooseFBConfig(display, screen, &attribs, &num_configs);
    if (configs == null or num_configs == 0) {
        return error.NoSuitableFBConfig;
    }

    const result = configs[0];
    _ = xlib.XFree(configs);
    return result;
}

fn initDamage(conn: *xcb.xcb_connection_t) X11Error!u8 {
    const ext_cookie = xcb.xcb_damage_query_version(conn, 1, 1);
    const ext_reply = xcb.xcb_damage_query_version_reply(conn, ext_cookie, null)
        orelse return error.CompositeNotAvailable;
    defer std.c.free(ext_reply);

    const ext = xcb.xcb_get_extension_data(conn, &xcb.xcb_damage_id);
    if (ext == null) return error.CompositeNotAvailable;

    return ext.*.first_event;
}

If selectFBConfig fails at init time, fall back to the existing xcb_get_image path. Store a use_glx: bool flag on Connection.

Step 3: WindowTexture Struct

File: src/x11.zig -- add alongside RawCapture (line 118). Do NOT remove RawCapture -- it's the fallback path.

pub const WindowTexture = struct {
    window_id: xcb.xcb_window_t,
    width: u16,
    height: u16,

    pixmap: xcb.xcb_pixmap_t,
    glx_pixmap: xlib.GLXPixmap,
    gl_texture: c_uint,
    damage: xcb.xcb_damage_damage_t,

    pub fn deinit(self: *WindowTexture, conn: *Connection) void {
        conn.glx_release(conn.display, self.glx_pixmap, xlib.GLX_FRONT_LEFT_EXT);
        // Use GL directly -- do NOT call rl.UnloadTexture
        glDeleteTextures(1, &self.gl_texture);
        xlib.glXDestroyPixmap(conn.display, self.glx_pixmap);
        _ = xcb.xcb_free_pixmap(conn.conn, self.pixmap);
        _ = xcb.xcb_damage_destroy(conn.conn, self.damage);
    }

    /// Wrap as raylib Texture2D. Caller must NOT call rl.UnloadTexture on this.
    pub fn toRaylibTexture(self: *const WindowTexture) rl.Texture2D {
        return rl.Texture2D{
            .id = @intCast(self.gl_texture),
            .width = @intCast(self.width),
            .height = @intCast(self.height),
            .mipmaps = 1,
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        };
    }

    /// Rebind after damage (window content changed).
    pub fn rebind(self: *WindowTexture, conn: *Connection) void {
        conn.glx_release(conn.display, self.glx_pixmap, xlib.GLX_FRONT_LEFT_EXT);
        conn.glx_bind(conn.display, self.glx_pixmap, xlib.GLX_FRONT_LEFT_EXT, null);
    }
};

Pass conn explicitly rather than storing a *Connection reference (matches existing codebase style).

Step 4: createWindowTexture Function

File: src/x11.zig -- MUST be called from the main thread (GL context owner).

pub fn createWindowTexture(conn: *Connection, window: xcb.xcb_window_t) !WindowTexture {
    // Redirect for compositing (same as captureRawImage line 439)
    const redirect_cookie = xcb.xcb_composite_redirect_window_checked(
        conn.conn, window, xcb.XCB_COMPOSITE_REDIRECT_AUTOMATIC
    );
    if (xcb.xcb_request_check(conn.conn, redirect_cookie)) |err| {
        std.c.free(err);
    }

    const geom_cookie = xcb.xcb_get_geometry(conn.conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(conn.conn, geom_cookie, null)
        orelse return error.GeometryFetchFailed;
    defer std.c.free(geom_reply);

    const width = geom_reply.*.width;
    const height = geom_reply.*.height;
    if (width == 0 or height == 0) return error.InvalidGeometry;

    // Create composite pixmap (same as captureRawImage line 467)
    const pixmap = xcb.xcb_generate_id(conn.conn);
    const name_cookie = xcb.xcb_composite_name_window_pixmap_checked(conn.conn, window, pixmap);
    if (xcb.xcb_request_check(conn.conn, name_cookie)) |err| {
        std.c.free(err);
        return error.PixmapCreationFailed;
    }

    const glx_attribs = [_]c_int{
        xlib.GLX_TEXTURE_TARGET_EXT, xlib.GLX_TEXTURE_2D_EXT,
        xlib.GLX_TEXTURE_FORMAT_EXT, xlib.GLX_TEXTURE_FORMAT_RGBA_EXT,
        0,
    };

    const glx_pixmap = xlib.glXCreatePixmap(conn.display, conn.fb_config, pixmap, &glx_attribs);
    if (glx_pixmap == 0) {
        _ = xcb.xcb_free_pixmap(conn.conn, pixmap);
        return error.GLXPixmapCreationFailed;
    }

    var gl_texture: c_uint = undefined;
    glGenTextures(1, &gl_texture);
    glBindTexture(GL_TEXTURE_2D, gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    conn.glx_bind(conn.display, glx_pixmap, xlib.GLX_FRONT_LEFT_EXT, null);
    glBindTexture(GL_TEXTURE_2D, 0);

    const damage = xcb.xcb_generate_id(conn.conn);
    _ = xcb.xcb_damage_create(conn.conn, damage, window, xcb.XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);

    return WindowTexture{
        .window_id = window,
        .width = width,
        .height = height,
        .pixmap = pixmap,
        .glx_pixmap = glx_pixmap,
        .gl_texture = gl_texture,
        .damage = damage,
    };
}

Note on GL imports: x11.zig currently doesn't import GL. Either add @cImport(@cInclude("GL/gl.h")) to x11.zig, or move createWindowTexture +
WindowTexture into a new glx_texture.zig module that can import both x11 and GL.

Step 5: Restructure Worker Thread

File: src/worker.zig

The worker currently does: (a) discover windows + titles + icons, and (b) capture + process thumbnails. With GLX, job (b) moves to the main thread.

Changes to UpdateTask (line 9):

Simplify WindowAdded -- remove pixel data fields:

pub const WindowAdded = struct {
    window_id: xcb.xcb_window_t,
    title: []const u8,      // owned
    icon_id: []const u8,    // owned (WM_CLASS)
    is_minimized: bool,
    allocator: std.mem.Allocator,
};

Remove ThumbnailUpdated entirely -- damage events replace polling.

Keep WindowRemoved, TitleUpdated, and IconAdded unchanged.

Changes to backgroundWorker (line 217):

- Use Connection.initXcbOnly() (no GLX needed)
- Skip captureRawImage and processRawCapture entirely
- Remove the thread pool for parallel thumbnail processing
- Keep polling for window list changes at a reasonable interval

Step 6: Main Thread Texture Management

File: src/app.zig

Add a window_textures: std.AutoHashMap(xcb.xcb_window_t, x11.WindowTexture) field to App.

Changes to drainUpdateQueue (line 221):

When processing window_added, create GLX texture on the main thread instead of uploading pixel bytes:

.window_added => |*data| {
    const win_tex = x11.createWindowTexture(&self.conn, data.window_id) catch |err| {
        log.err("GLX texture failed for {x}: {}", .{ data.window_id, err });
        continue; // or fall back to xcb_get_image
    };

    const rl_texture = win_tex.toRaylibTexture();

    const new_item = ui.DisplayWindow{
        .id = data.window_id,
        .title = data.title,
        .thumbnail_texture = rl_texture,
        .source_width = @intCast(win_tex.width),
        .source_height = @intCast(win_tex.height),
        // ... rest of fields
    };

    self.window_textures.put(data.window_id, win_tex) catch {};
    self.items.append(new_item) catch { ... };
},

Window removal: Call WindowTexture.deinit() instead of rl.UnloadTexture() -- the GL resource is owned by WindowTexture, not raylib.

Step 7: Handle Damage Events in Main Loop

File: src/main.zig

In processXcbEvents (line 146), the damage event type is dynamic so it can't be a switch case. Add to the else branch:

else => {
    if (response_type == conn.damage_event_base + x11.xcb.XCB_DAMAGE_NOTIFY) {
        const damage_event: *x11.xcb.xcb_damage_notify_event_t = @ptrCast(event);
        application.handleDamageEvent(damage_event.drawable);
    }
},

File: src/app.zig -- add:

pub fn handleDamageEvent(self: *Self, drawable: xcb.xcb_window_t) void {
    if (self.window_textures.getPtr(drawable)) |tex| {
        tex.rebind(&self.conn);
        _ = xcb.xcb_damage_subtract(self.conn.conn, tex.damage, 0, 0);
    }
}

Note: processXcbEvents currently receives *xcb.xcb_connection_t (line 146). It needs to receive *Connection instead to access damage_event_base.

Step 8: Y-Axis Flipping in Rendering

File: src/ui.zig

GLX textures have bottom-left origin. In renderSwitcher where DrawTexturePro is called (around line 354), flip the source rectangle:

const source_rect = rl.Rectangle{
    .x = 0,
    .y = @floatFromInt(item.thumbnail_texture.height),
    .width = @floatFromInt(item.thumbnail_texture.width),
    .height = -@as(f32, @floatFromInt(item.thumbnail_texture.height)),
};

If keeping the fallback path, add a is_glx: bool flag to DisplayWindow to know whether to flip.

Step 9: Update build.zig

File: build.zig

Add only two new libraries. Everything else is already linked.

After the existing xcb-keysyms line (line 31), add:

exe.linkSystemLibrary("xcb-damage");
exe.linkSystemLibrary("X11-xcb");

Do NOT add "GLX" -- GLX functions are in libGL.so which is already linked (line 35). Linking GLX separately would fail.

Apply the same two additions to the test executable block (around line 68).

---
Modules Affected
File: src/x11.zig
Changes: Replace Connection.init() with mixed Xlib/XCB; add initXcbOnly(); add WindowTexture, createWindowTexture(), selectFBConfig(), initDamage(); keep

  RawCapture + captureRawImage for fallback
────────────────────────────────────────
File: src/main.zig
Changes: Pass *Connection to processXcbEvents; add damage event handling in else branch
────────────────────────────────────────
File: src/app.zig
Changes: Add window_textures hashmap; change drainUpdateQueue to create GLX textures; add handleDamageEvent(); update window removal cleanup
────────────────────────────────────────
File: src/worker.zig
Changes: Simplify WindowAdded (no pixel data); remove ThumbnailUpdated; use initXcbOnly(); remove thumbnail capture from worker loop
────────────────────────────────────────
File: src/window_scanner.zig
Changes: Add lightweight scan mode that skips capture/processing; keep full pipeline for fallback
────────────────────────────────────────
File: src/ui.zig
Changes: Flip source_rect Y-axis for GLX textures
────────────────────────────────────────
File: build.zig
Changes: Add xcb-damage and X11-xcb to exe and test link lists
Modules NOT Affected
┌──────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────┐
│         File         │                                        Why unchanged                                         │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/thumbnail.zig    │ Still needed for icon processing (processIconArgb). Window thumbnail path kept for fallback. │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/color.zig        │ BGRA-to-RGBA SIMD only used by fallback path                                                 │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/layout.zig       │ Pure math, no pixel dependency                                                               │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/navigation.zig   │ Pure navigation logic                                                                        │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/queue.zig        │ Generic queue, still used for worker communication                                           │
├──────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
│ src/desktop_icon.zig │ Icons come from _NET_WM_ICON (ARGB data), not window pixmaps                                 │
└──────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────┘
Important Notes

Texture Ownership

The GL texture is owned by WindowTexture, not raylib. The existing code calls rl.UnloadTexture() when removing thumbnails (app.zig:283, app.zig:296).
With GLX, calling rl.UnloadTexture would delete the GL resource out from under WindowTexture. All cleanup must go through WindowTexture.deinit().

Window Resize

When a window resizes, the composite pixmap changes and the old handle becomes invalid. Detect this via ConfigureNotify events or by checking geometry on
  damage, then recreate the entire WindowTexture.

Minimized Windows

xcb_composite_name_window_pixmap only works for mapped windows. When minimized, the pixmap is invalid. Options: cache the last valid texture (shows stale
  content), or show the desktop icon instead.

Fallback Strategy

Keep the entire xcb_get_image path as a fallback. At Connection.init(), if selectFBConfig or glXGetProcAddress fails, set use_glx = false and use the
existing pipeline unchanged. This handles software rendering, incompatible drivers, and VMs.

Compositor Interaction

If a compositor (picom, mutter) is running, windows are already redirected. The xcb_composite_redirect_window call is harmless (double-redirect with
AUTOMATIC mode is a no-op).

Testing

1. Verify GLX extension: glxinfo | grep GLX_EXT_texture_from_pixmap
2. Test single window texture binding
3. Confirm Y-axis is correct (not upside-down)
4. Open/close windows repeatedly to verify cleanup (no GL resource leaks)
5. Resize a window and verify texture updates
6. Test with minimized windows
7. Force use_glx = false and verify fallback path still works
8. Test on systems without compositor, with picom, with mutter
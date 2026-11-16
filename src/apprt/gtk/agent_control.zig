//! A D-Bus interface that lets local agents list, read, type into and focus
//! Ghostty tabs by the ID that "Copy Tab ID" puts on the clipboard. It is the
//! Linux counterpart of the macOS AppleScript tab and terminal objects.
//!
//! Each Ghostty process registers the interface on its own session bus
//! connection and owns `com.mitchellh.ghostty.Control.p<pid>`, so callers can
//! find every process when `gtk-single-instance` is false.

const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const terminal = @import("../../terminal/main.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;

const log = std.log.scoped(.gtk_agent_control);

pub const object_path = "/com/mitchellh/ghostty/Control";
pub const interface_name = "com.mitchellh.ghostty.Control1";
pub const bus_name_prefix = "com.mitchellh.ghostty.Control.p";

const introspection_xml =
    \\<node>
    \\  <interface name="com.mitchellh.ghostty.Control1">
    \\    <method name="ListTabs">
    \\      <arg name="tabs" type="a(sssb)" direction="out"/>
    \\    </method>
    \\    <method name="ReadText">
    \\      <arg name="id" type="s" direction="in"/>
    \\      <arg name="scrollback" type="b" direction="in"/>
    \\      <arg name="text" type="s" direction="out"/>
    \\    </method>
    \\    <method name="SendText">
    \\      <arg name="id" type="s" direction="in"/>
    \\      <arg name="text" type="s" direction="in"/>
    \\      <arg name="raw" type="b" direction="in"/>
    \\    </method>
    \\    <method name="Focus">
    \\      <arg name="id" type="s" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

const vtable: gio.DBusInterfaceVTable = .{
    .f_method_call = methodCall,
    .f_get_property = null,
    .f_set_property = null,
    .f_padding = undefined,
};

pub fn register(app: *Application, conn: *gio.DBusConnection) void {
    var err: ?*glib.Error = null;

    // The node info stays alive for the life of the process because the
    // registration below holds pointers into it.
    const node = gio.DBusNodeInfo.newForXml(introspection_xml, &err) orelse {
        logError("parse introspection", err);
        return;
    };
    const iface = node.lookupInterface(interface_name) orelse {
        log.warn("agent control interface missing from introspection", .{});
        return;
    };

    if (conn.registerObject(object_path, iface, &vtable, app, noopDestroy, &err) == 0) {
        logError("register object", err);
        return;
    }

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, bus_name_prefix ++ "{d}", .{std.c.getpid()}, 0) catch return;
    _ = gio.busOwnNameOnConnection(conn, name, .{ .do_not_queue = true }, null, null, null, null);
    log.info("agent control ready on {s}", .{name});
}

fn noopDestroy(_: ?*anyopaque) callconv(.c) void {}

fn logError(what: []const u8, err: ?*glib.Error) void {
    const msg: []const u8 = if (err) |e| if (e.f_message) |m| std.mem.span(m) else "" else "";
    log.warn("agent control: failed to {s}: {s}", .{ what, msg });
    if (err) |e| e.free();
}

const Found = struct {
    window: *Window,
    view: *adw.TabView,
    page: *adw.TabPage,
    tab: *Tab,
};

const TabIter = struct {
    node: ?*glib.List,
    window: ?*Window = null,
    view: ?*adw.TabView = null,
    index: c_int = 0,

    fn init(app: *Application) TabIter {
        return .{ .node = @as(?*glib.List, app.as(gtk.Application).getWindows()) };
    }

    fn next(self: *TabIter) ?Found {
        while (true) {
            if (self.window) |window| {
                const view = self.view.?;
                if (self.index < view.getNPages()) {
                    const page = view.getNthPage(self.index);
                    self.index += 1;
                    const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                    return .{ .window = window, .view = view, .page = page, .tab = tab };
                }
                self.window = null;
            }

            const node = self.node orelse return null;
            self.node = node.f_next;
            const data = node.f_data orelse continue;
            const obj: *gobject.Object = @ptrCast(@alignCast(data));
            const window = gobject.ext.cast(Window, obj) orelse continue;
            self.window = window;
            self.view = window.getTabView();
            self.index = 0;
        }
    }
};

fn findTab(app: *Application, id: []const u8) ?Found {
    var it: TabIter = .init(app);
    while (it.next()) |found| {
        var buf: [32]u8 = undefined;
        if (std.mem.eql(u8, found.tab.controlId(&buf), id)) return found;
    }
    return null;
}

fn methodCall(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    params: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const app: *Application = @ptrCast(@alignCast(user_data orelse return));
    const method = std.mem.span(method_name);

    if (std.mem.eql(u8, method, "ListTabs")) return listTabs(app, invocation);

    const id_v = params.getChildValue(0);
    defer id_v.unref();
    const id = std.mem.span(id_v.getString(null));
    const found = findTab(app, id) orelse
        return fail(invocation, "no tab with this id in this Ghostty process");

    if (std.mem.eql(u8, method, "ReadText")) {
        const scrollback_v = params.getChildValue(1);
        defer scrollback_v.unref();
        return readText(found, scrollback_v.getBoolean() != 0, invocation);
    }

    if (std.mem.eql(u8, method, "SendText")) {
        const text_v = params.getChildValue(1);
        defer text_v.unref();
        const raw_v = params.getChildValue(2);
        defer raw_v.unref();
        return sendText(found, std.mem.span(text_v.getString(null)), raw_v.getBoolean() != 0, invocation);
    }

    if (std.mem.eql(u8, method, "Focus")) {
        const surface = found.tab.getActiveSurface() orelse
            return fail(invocation, "tab has no terminal");
        surface.present();
        return invocation.returnValue(null);
    }

    fail(invocation, "unknown method");
}

fn fail(invocation: *gio.DBusMethodInvocation, msg: [*:0]const u8) void {
    invocation.returnErrorLiteral(gio.DBusError.quark(), @intFromEnum(gio.DBusError.failed), msg);
}

fn listTabs(app: *Application, invocation: *gio.DBusMethodInvocation) void {
    const array_type = glib.VariantType.new("a(sssb)");
    defer array_type.free();

    var builder: glib.VariantBuilder = undefined;
    builder.init(array_type);

    var it: TabIter = .init(app);
    while (it.next()) |found| {
        var id_buf: [32]u8 = undefined;
        const pwd: [*:0]const u8 = pwd: {
            const surface = found.tab.getActiveSurface() orelse break :pwd "";
            break :pwd if (surface.getPwd()) |p| p.ptr else "";
        };
        const selected = if (found.view.getSelectedPage()) |p| p == found.page else false;
        var children = [_]*glib.Variant{
            glib.Variant.newString(found.tab.controlId(&id_buf)),
            glib.Variant.newString(found.page.getTitle()),
            glib.Variant.newString(pwd),
            glib.Variant.newBoolean(@intFromBool(selected)),
        };
        builder.addValue(glib.Variant.newTuple(&children, children.len));
    }

    var result = [_]*glib.Variant{builder.end()};
    invocation.returnValue(glib.Variant.newTuple(&result, result.len));
}

fn readText(found: Found, scrollback: bool, invocation: *gio.DBusMethodInvocation) void {
    const surface = found.tab.getActiveSurface() orelse
        return fail(invocation, "tab has no terminal");
    const core = surface.core() orelse
        return fail(invocation, "terminal is not ready");

    const alloc = Application.default().allocator();
    const text = dumpScreen(core, alloc, scrollback) catch
        return fail(invocation, "could not read the terminal text");
    defer alloc.free(text);

    var result = [_]*glib.Variant{glib.Variant.newString(text.ptr)};
    invocation.returnValue(glib.Variant.newTuple(&result, result.len));
}

fn dumpScreen(core: *CoreSurface, alloc: std.mem.Allocator, scrollback: bool) ![:0]const u8 {
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());

    const pages = &core.io.terminal.screens.active.pages;
    const tag: terminal.point.Tag = if (scrollback) .screen else .viewport;
    const br = pages.getBottomRight(tag) orelse return alloc.dupeSentinel(u8, "", 0);
    const sel = terminal.Selection.init(pages.getTopLeft(tag), br, false);

    const text = try core.dumpTextLocked(alloc, sel);
    return text.text;
}

fn sendText(found: Found, text: []const u8, raw: bool, invocation: *gio.DBusMethodInvocation) void {
    const surface = found.tab.getActiveSurface() orelse
        return fail(invocation, "tab has no terminal");
    const core = surface.core() orelse
        return fail(invocation, "terminal is not ready");

    // Raw input goes through the `text:` keybind action, which parses Zig
    // string escapes such as \r, \x03 and \x1b. Other input is pasted.
    if (raw) {
        _ = core.performBindingAction(.{ .text = text }) catch
            return fail(invocation, "could not send the input");
    } else {
        core.textCallback(text) catch
            return fail(invocation, "could not send the input");
    }
    invocation.returnValue(null);
}

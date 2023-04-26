const std = @import("std");
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

pub const Bus = struct {
    handle: ?*c.sd_bus = null,

    const Self = @This();

    pub fn openSystem() !Self {
        var system_bus: Self = .{};
        const rc = c.sd_bus_open_system(&system_bus.handle);
        if (rc >= 0)
            return system_bus;
        return switch (@intToEnum(std.os.E, -rc)) {
            .INVAL => error.INVAL,
            .NOMEDIUM => error.NOMEDIUM,
            .NOMEM => error.NOMEM,
            .SOCKTNOSUPPORT => error.SOCKTNOSUPPORT,
            else => unreachable,
        };
    }

    pub fn wait(self: Self, timeout: u64) !bool {
        const rc = c.sd_bus_wait(self.handle, timeout);
        if (rc < 0) {
            return switch (@intToEnum(std.os.E, -rc)) {
                else => unreachable,
            };
        }
        return switch (rc) {
            0 => false,
            else => true,
        };
    }

    pub fn process(self: Self) !bool {
        const rc = c.sd_bus_process(self.handle, null);
        if (rc < 0) {
            return switch (@intToEnum(std.os.E, -rc)) {
                else => unreachable,
            };
        }
        return switch (rc) {
            0 => false,
            else => true,
        };
    }

    pub fn unref(self: Self) void {
        _ = c.sd_bus_unref(self.handle);
    }

    pub fn get_fd(self: Self) !c_int {
        const rc = c.sd_bus_get_fd(self.handle);
        if (rc < 0) {
            return switch (@intToEnum(std.os.E, -rc)) {
                else => unreachable,
            };
        }
        return rc;
    }

    pub fn get_events(self: Self) !i16 {
        const rc = c.sd_bus_get_events(self.handle);
        if (rc < 0) {
            return switch (@intToEnum(std.os.E, -rc)) {
                else => unreachable,
            };
        }
        return @intCast(i16, rc);
    }

    pub fn get_timeout(self: Self) !i32 {
        var result: u64 = undefined;
        const rc = c.sd_bus_get_timeout(self.handle, &result);
        if (rc < 0) {
            return switch (@intToEnum(std.os.E, -rc)) {
                else => unreachable,
            };
        }
        var x = @intCast(i128, result) * 1000;
        var y = @divTrunc(x - std.time.nanoTimestamp(), 1000 * 1000);

        return @intCast(i32, y);
    }
};

pub const Object = struct {
    bus: Bus,
    destination: [*:0]const u8,
    path: [*:0]const u8,

    const Self = @This();

    pub fn callMethod(self: Self, interface: [*:0]const u8, method: [*:0]const u8, types: [*:0]const u8, args: anytype) !Message {
        // TODO: parameters
        var reply: Message = .{};
        const rc = @call(.auto, c.sd_bus_call_method, .{ self.bus.handle, self.destination, self.path, interface, method, null, &reply.handle, types } ++ args);
        if (rc >= 0)
            return reply;
        return switch (@intToEnum(std.os.E, -rc)) {
            .INVAL => error.INVAL,
            .NOTCONN => error.NOTCONN,
            .NOMEM => error.NOMEM,
            .PERM => error.PERM,
            .OPNOTSUPP => error.OPNOTSUPP,
            .STALE => error.STALE,
            .NXIO => error.NXIO,
            .CHILD => error.CHILD,
            .CONNRESET => error.CONNRESET,
            .TIMEDOUT => error.TIMEDOUT,
            .LOOP => error.LOOP,
            .IO => error.IO,
            else => unreachable,
        };
    }

    const SignalHandler = *const fn (Message, ?*anyopaque, ?*anyopaque) callconv(.C) c_int;
    pub fn matchSignal(self: Self, slot: ?*Slot, interface: [*:0]const u8, signal: [*:0]const u8, callback: SignalHandler, user_data: ?*anyopaque) !void {
        var p: ?*?*c.sd_bus_slot = if (slot) |s|
            &s.handle
        else
            null;
        const rc = c.sd_bus_match_signal(self.bus.handle, p, self.destination, self.path, interface, signal, @ptrCast(c.sd_bus_message_handler_t, callback), user_data);
        if (rc >= 0)
            return;
        return switch (@intToEnum(std.os.E, -rc)) {
            else => unreachable,
        };
    }
};

pub const Message = extern struct {
    handle: ?*c.sd_bus_message = null,

    const Self = @This();

    pub fn enterContainer(self: Self, t: u8, contents: [*:0]const u8) !bool {
        const rc = c.sd_bus_message_enter_container(self.handle, t, contents);
        return switch (rc) {
            0 => false,
            1 => true,
            else => switch (@intToEnum(std.os.E, -rc)) {
                .INVAL => error.INVAL,
                .PERM => error.PERM,
                .STALE => error.STALE,
                .NOMEM => error.NOMEM,
                else => {
                    std.debug.print("{}\n", .{rc});
                    unreachable;
                },
            },
        };
    }

    pub fn skip(self: Self, types: [*:0]const u8) !void {
        const rc = c.sd_bus_message_skip(self.handle, types);
        if (rc >= 0)
            return;
        return switch (@intToEnum(std.os.E, -rc)) {
            .INVAL => error.INVAL,
            .BADMSG => error.BADMSG,
            .PERM => error.PERM,
            .NXIO => error.NXIO,
            .NOMEM => error.NOMEM,
            else => unreachable,
        };
    }

    pub fn readVariant(self: Self, t: [*:0]const u8, p: *anyopaque) !void {
        const rc = c.sd_bus_message_read(self.handle, "v", t, p);
        if (rc >= 0)
            return;
        return switch (@intToEnum(std.os.E, -rc)) {
            else => unreachable,
        };
    }

    pub fn readBasic(self: Self, @"type": u8, p: *anyopaque) !void {
        const rc = c.sd_bus_message_read_basic(self.handle, @"type", p);
        if (rc >= 0)
            return;
        return switch (@intToEnum(std.os.E, -rc)) {
            .INVAL => error.INVAL,
            .NXIO => error.NXIO,
            .BADMSG => error.BADMSG,
            else => unreachable,
        };
    }

    pub fn readString(self: Self) ![*:0]const u8 {
        var result: [*:0]const u8 = undefined;
        try self.readBasic('s', @ptrCast(*anyopaque, &result));
        return result;
    }

    pub fn readObjectPath(self: Self) ![*:0]const u8 {
        var result: [*:0]const u8 = undefined;
        try self.readBasic('o', @ptrCast(*anyopaque, &result));
        return result;
    }

    pub fn readUnixFd(self: Self) !c_int {
        var result: c_int = undefined;
        try self.readBasic('h', @ptrCast(*anyopaque, &result));
        return result;
    }

    pub fn readBoolean(self: Self) !bool {
        var result: c_int = undefined;
        try self.readBasic('b', @ptrCast(*anyopaque, &result));
        return result != 0;
    }

    pub fn exitContainer(self: Self) !void {
        const rc = c.sd_bus_message_exit_container(self.handle);
        if (rc >= 0)
            return;
        return switch (@intToEnum(std.os.E, -rc)) {
            .INVAL => error.INVAL,
            .PERM => error.PERM,
            .STALE => error.STALE,
            .NOMEM => error.NOMEM,
            .BUSY => error.BUSY,
            else => unreachable,
        };
    }

    pub fn dump(self: Self, f: ?*c.FILE, flags: u64) void {
        std.debug.assert(c.sd_bus_message_dump(self.handle, f, flags) >= 0);
    }
};

pub const Slot = extern struct {
    handle: ?*c.sd_bus_slot = null,

    pub const Self = @This();

    pub fn unref(self: Self) void {
        _ = c.sd_bus_slot_unref(self.handle);
    }
};

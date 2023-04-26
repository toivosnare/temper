const std = @import("std");
const SDBus = @import("SDBus.zig");
const assert = std.debug.assert;
const log = std.log;
const http = std.http;
const json = std.json;

const Device = struct {
    address: ?Address = null,
    blocked: bool = true,

    pub const Address = struct {
        bytes: [6]u8,

        pub fn fromSlice(slice: []const u8) !Address {
            if (slice.len < 17)
                return error.InvalidLength;

            var result: Device.Address = undefined;
            var i: usize = 0;
            while (i < 6) : (i += 1) {
                result.bytes[i] = try std.fmt.parseUnsigned(u8, slice[i * 3 ..][0..2], 16);
            }
            return result;
        }
    };

    const Self = @This();

    pub fn fromMessage(message: SDBus.Message) !Self {
        var result: Self = .{};
        assert(try message.enterContainer('a', "{sv}"));
        while (try message.enterContainer('e', "sv")) {
            var key = std.mem.span(try message.readString());
            if (std.mem.eql(u8, key, "Address")) {
                var str: [*:0]const u8 = undefined;
                try message.readVariant("s", @ptrCast(*anyopaque, &str));
                result.address = try Address.fromSlice(std.mem.span(str));
            } else if (std.mem.eql(u8, key, "Blocked")) {
                try message.readVariant("b", @ptrCast(*anyopaque, &result.blocked));
            } else {
                try message.skip("v");
            }
            try message.exitContainer();
        }
        try message.exitContainer();
        return result;
    }
};

const Node = struct {
    device: Device,
    object: SDBus.Object,
    slot: SDBus.Slot = .{},
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var bus: SDBus.Bus = undefined;
var device_map = std.AutoHashMap(Device.Address, *Node).init(allocator);
var pollfd_list = std.ArrayList(std.os.pollfd).init(allocator);

pub fn main() !void {
    bus = try SDBus.Bus.openSystem();
    defer bus.unref();

    _ = try pollfd_list.addOne();

    log.info("Listening for added interfaces.", .{});
    var root = SDBus.Object{ .bus = bus, .destination = "org.bluez", .path = "/" };
    try root.matchSignal(null, "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", &interfacesAddedCallback, null);
    // try root.matchSignal(null, "org.freedesktop.DBus.ObjectManager", "InterfacesRemoved", &interfacesRemovedCallback, null);

    log.info("Adding managed objects.", .{});
    try addManagedObjects(root);

    // log.info("Starting device discovery.", .{});
    // var adapter = SDBus.Object{ .bus = bus, .destination = "org.bluez", .path = "/org/bluez/hci0" };
    // _ = try adapter.callMethod("org.bluez.Adapter1", "StartDiscovery", "", .{});

    try eventLoop();
}

fn eventLoop() !void {
    var client = std.http.Client{ .allocator = allocator };
    const uri = std.Uri.parse("http://localhost:3000/temperature") catch unreachable;
    var headers = std.http.Headers{ .allocator = allocator };
    defer headers.deinit();
    try headers.append("Content-Type", "application/json");

    while (true) {
        pollfd_list.items[0].fd = try bus.get_fd();
        pollfd_list.items[0].events = try bus.get_events();

        _ = try std.os.poll(pollfd_list.items, 0);

        if (pollfd_list.items[0].revents != 0)
            _ = try bus.process();

        for (pollfd_list.items[1..]) |pollfd| {
            if (pollfd.revents == 0)
                continue;

            var file = std.fs.File{ .handle = pollfd.fd };
            var payload: struct { temperature: f32 } = undefined;
            _ = try file.read(std.mem.asBytes(&payload.temperature));
            log.info("Sending temperature {} C.", .{payload.temperature});

            var req = try client.request(.POST, uri, headers, .{});
            req.transfer_encoding = .chunked;
            defer req.deinit();
            try req.start();
            try json.stringify(payload, .{}, req.writer());
            try req.finish();
            try req.do();
            // log.info("Response status: {s}.", .{@tagName(req.response.status)});
        }
    }
}

fn addManagedObjects(root: SDBus.Object) !void {
    var reply = try root.callMethod("org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", .{});

    assert(try reply.enterContainer('a', "{oa{sa{sv}}}"));
    while (try reply.enterContainer('e', "oa{sa{sv}}")) {
        try checkObject(reply);
        try reply.exitContainer();
    }
    try reply.exitContainer();
}

fn checkObject(message: SDBus.Message) !void {
    var path = try message.readObjectPath();
    assert(try message.enterContainer('a', "{sa{sv}}"));

    while (try message.enterContainer('e', "sa{sv}")) {
        var interface = std.mem.span(try message.readString());
        if (std.mem.eql(u8, interface, "org.bluez.Device1")) {
            try checkDevice(message, path);
        } else if (std.mem.eql(u8, interface, "org.bluez.GattCharacteristic1")) {
            try checkCharacteristic(message, path);
        } else {
            try message.skip("a{sv}");
        }
        try message.exitContainer();
    }

    try message.exitContainer();
}

fn checkDevice(message: SDBus.Message, path: [*:0]const u8) !void {
    var device = try Device.fromMessage(message);
    if (device.address == null or device.blocked) {
        log.info("Skipping device {s}.", .{path});
        return;
    }

    // TODO
    if (!std.mem.eql(u8, std.mem.span(path), "/org/bluez/hci0/dev_24_AA_D9_7E_9D_70")) {
        return;
    }

    var node = try allocator.create(Node);
    node.* = .{
        .device = device,
        .object = .{
            .bus = bus,
            .destination = "org.bluez",
            .path = path,
        },
    };
    // try node.object.matchSignal(&node.slot, "org.freedesktop.DBus.Properties", "PropertiesChanged", &propertiesChangedCallback, node);

    log.info("Connecting to device {s}.", .{path});
    _ = node.object.callMethod("org.bluez.Device1", "Connect", "", .{}) catch |e| switch (e) {
        error.TIMEDOUT => {
            log.info("Connection timed out. Skipping.", .{});
            // node.slot.unref();
            allocator.destroy(node);
            return;
        },
        else => return e,
    };
    log.info("Connected successfully. Adding to device map.", .{});
    try device_map.put(node.device.address.?, node);
    log.info("Waiting for characteristics to be added or ServicesResolved property to be added.", .{});
}

fn checkCharacteristic(message: SDBus.Message, path: [*:0]const u8) !void {
    var uuid: ?[*:0]const u8 = null;
    var service_path: ?[*:0]const u8 = null;

    assert(try message.enterContainer('a', "{sv}"));
    while (try message.enterContainer('e', "sv")) {
        var key = std.mem.span(try message.readString());
        if (std.mem.eql(u8, key, "UUID")) {
            try message.readVariant("s", @ptrCast(*anyopaque, &uuid));
        } else if (std.mem.eql(u8, key, "Service")) {
            try message.readVariant("o", @ptrCast(*anyopaque, &service_path));
        } else {
            try message.skip("v");
        }
        try message.exitContainer();
    }
    try message.exitContainer();

    if (uuid == null or !std.mem.eql(u8, std.mem.span(uuid.?), "00002a1c-0000-1000-8000-00805f9b34fb") or service_path == null) {
        log.info("Skipping characteristic {s}.", .{path});
        return;
    }
    var service = SDBus.Object{ .bus = bus, .destination = "org.bluez", .path = service_path.? };
    var reply = try service.callMethod("org.freedesktop.DBus.Properties", "GetAll", "s", .{"org.bluez.GattService1"});
    if (try checkService(reply)) |addr| {
        var node = device_map.get(addr);
        _ = node;
        var characteristic = SDBus.Object{ .bus = bus, .destination = "org.bluez", .path = path };
        reply = try characteristic.callMethod("org.bluez.GattCharacteristic1", "AcquireNotify", "a{sv}", .{@as(c_int, 0)});
        var pollfd = try pollfd_list.addOne();
        pollfd.* = .{
            .fd = try reply.readUnixFd(),
            .events = std.os.POLL.IN,
            .revents = 0,
        };
    }
}

fn checkService(message: SDBus.Message) !?Device.Address {
    var uuid: ?[*:0]const u8 = null;
    var device_path: ?[*:0]const u8 = null;

    assert(try message.enterContainer('a', "{sv}"));
    while (try message.enterContainer('e', "sv")) {
        var key = std.mem.span(try message.readString());
        if (std.mem.eql(u8, key, "UUID")) {
            try message.readVariant("s", @ptrCast(*anyopaque, &uuid));
        } else if (std.mem.eql(u8, key, "Device")) {
            try message.readVariant("o", @ptrCast(*anyopaque, &device_path));
        } else {
            try message.skip("v");
        }
        try message.exitContainer();
    }
    try message.exitContainer();

    if (uuid == null or !std.mem.eql(u8, std.mem.span(uuid.?), "0000181a-0000-1000-8000-00805f9b34fb") or device_path == null) {
        return null;
    }
    var device = SDBus.Object{ .bus = bus, .destination = "org.bluez", .path = device_path.? };
    var reply = try device.callMethod("org.freedesktop.DBus.Properties", "Get", "ss", .{ "org.bluez.Device1", "Address" });

    var device_address_str: [*:0]const u8 = undefined;
    try reply.readVariant("s", @ptrCast(*anyopaque, &device_address_str));
    return try Device.Address.fromSlice(std.mem.span(device_address_str));
}

fn interfacesAddedCallback(message: SDBus.Message, _: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
    checkObject(message) catch unreachable;
    return 0;
}

fn interfacesRemovedCallback(message: SDBus.Message, _: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
    log.debug("Interface removed:", .{});
    message.dump(null, 0);
    return 0;
}

fn propertiesChangedCallback(message: SDBus.Message, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
    var node = @ptrCast(*Node, @alignCast(@alignOf(*Node), user_data));
    log.debug("Property added for {s}:", .{node.object.path});
    message.dump(null, 0);
    return 0;
}

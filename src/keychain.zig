//! The teams-zig items in the login keychain, read through `/usr/bin/security`. Items made by
//! `security` trust it, so no build of teams-zig gets an access prompt, as it would reading
//! through Security.framework itself (see docs/PLAN.md M1.7).

const std = @import("std");
const Io = std.Io;

/// The service name of the teams-zig items: `skype-token` and `region`.
pub const service = "teams-zig";

/// Apple's keychain tool.
pub const security_path = "/usr/bin/security";

/// security exits with the low byte of the OSStatus: errSecItemNotFound (-25300) becomes 44.
const security_exit_item_not_found = 44;

/// Far larger than any token; a bigger value means something else is stored there.
const value_size_max = 64 * 1024;

/// Failures reading a keychain item through `security`.
pub const ReadError = error{ ItemNotFound, KeychainReadFailed, OutOfMemory };

/// Reads one item of `service_name`. Owned by the caller.
pub fn read(
    gpa: std.mem.Allocator,
    io: Io,
    service_name: []const u8,
    account: []const u8,
) ReadError![]u8 {
    std.debug.assert(service_name.len > 0);
    std.debug.assert(account.len > 0);
    const result = std.process.run(gpa, io, .{
        .exe = .detect,
        .argv = &.{
            security_path, "find-generic-password", "-s", service_name, "-a", account, "-w",
        },
        .stderr_limit = .limited(value_size_max),
        .stdout_limit = .limited(value_size_max),
        .reserve_amount = 64,
        .cwd = .inherit,
        .environ_map = null,
        .expand_arg0 = .no_expand,
        .progress_node = .none,
        .create_no_window = true,
        .timeout = .none,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.KeychainReadFailed,
    };
    gpa.free(result.stderr);
    defer {
        std.crypto.secureZero(u8, result.stdout);
        gpa.free(result.stdout);
    }

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {},
            security_exit_item_not_found => return error.ItemNotFound,
            else => return error.KeychainReadFailed,
        },
        else => return error.KeychainReadFailed,
    }
    // security ends the value with a newline.
    const value = std.mem.trimEnd(u8, result.stdout, "\n");
    return gpa.dupe(u8, value);
}

/// One item to store: `value` under `account`.
pub const Item = struct {
    account: []const u8,
    value: []const u8,
};

/// Failures storing items. `UnstorableValue`: a value `security -i` would split or misread.
pub const WriteError = ReadError || error{ UnstorableValue, KeychainWriteFailed };

/// Stores each item under `service_name`, replacing an older value, then reads each back to
/// check it. The values go to `security -i` on its stdin, never in argv, where any process
/// could see them. `-A` opens the items' access list, as the token script did (M1.7).
pub fn write(
    gpa: std.mem.Allocator,
    io: Io,
    service_name: []const u8,
    items: []const Item,
) WriteError!void {
    std.debug.assert(items.len > 0);
    for (items) |item| {
        std.debug.assert(storable(item.account));
        if (!storable(item.value)) return error.UnstorableValue;
    }

    var child = std.process.spawn(io, .{
        .exe = .detect,
        .argv = &.{ security_path, "-i" },
        .cwd = .inherit,
        .environ_map = null,
        .expand_arg0 = .no_expand,
        .progress_node = .none,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .inherit_dirs = &.{},
        .inherit_files = &.{},
        .request_resource_usage_statistics = false,
        .uid = null,
        .gid = null,
        .pgid = null,
        .start_suspended = false,
        .create_no_window = true,
    }) catch return error.KeychainWriteFailed;
    defer child.kill(io);

    writeCommands(io, child.stdin.?, service_name, items) catch {
        return error.KeychainWriteFailed;
    };
    child.stdin.?.close(io);
    child.stdin = null;

    // security -i exits 1 when a command fails; the read-back below catches anything else.
    const term = child.wait(io) catch return error.KeychainWriteFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.KeychainWriteFailed,
        else => return error.KeychainWriteFailed,
    }

    for (items) |item| {
        const stored = try read(gpa, io, service_name, item.account);
        defer {
            std.crypto.secureZero(u8, stored);
            gpa.free(stored);
        }
        if (!std.mem.eql(u8, stored, item.value)) return error.KeychainWriteFailed;
    }
}

/// One `add-generic-password` line per item. The writer's buffer is zeroed after, as it held
/// the values.
fn writeCommands(
    io: Io,
    stdin: std.Io.File,
    service_name: []const u8,
    items: []const Item,
) Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var file_writer: std.Io.File.Writer = .init(stdin, io, &buffer);
    const writer = &file_writer.interface;
    for (items) |item| {
        try writer.print("add-generic-password -U -A -s {s} -a {s} -w {s}\n", .{
            service_name,
            item.account,
            item.value,
        });
    }
    try writer.flush();
}

/// `security -i` splits its lines on spaces and reads quotes and backslashes, and an empty
/// `-w` makes it prompt; tokens and regions are printable ASCII with none of those.
fn storable(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > value_size_max) return false;
    for (value) |byte| {
        if (byte <= ' ' or byte >= 0x7f) return false;
        if (byte == '"' or byte == '\'' or byte == '\\') return false;
    }
    return true;
}

/// A throwaway service per test run, so tests never touch the real items.
fn testServiceName(buffer: *[64]u8) []const u8 {
    var random_bytes: [6]u8 = undefined;
    std.testing.io.random(&random_bytes);
    return std.fmt.bufPrint(buffer, "teams-zig-test-{x}", .{random_bytes}) catch unreachable;
}

fn testDelete(service_name: []const u8, account: []const u8) void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ security_path, "delete-generic-password", "-s", service_name, "-a", account },
    }) catch return;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "write stores each item, replacing an older value, and read gives it back" {
    var buffer: [64]u8 = undefined;
    const service_name = testServiceName(&buffer);
    defer testDelete(service_name, "fake-token");
    defer testDelete(service_name, "fake-region");

    try write(std.testing.allocator, std.testing.io, service_name, &.{
        .{ .account = "fake-token", .value = "FAKE.old-1" },
    });
    try write(std.testing.allocator, std.testing.io, service_name, &.{
        .{ .account = "fake-token", .value = "FAKE.new-2_=+/%" },
        .{ .account = "fake-region", .value = "emea" },
    });

    const token = try read(std.testing.allocator, std.testing.io, service_name, "fake-token");
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("FAKE.new-2_=+/%", token);
    const region = try read(std.testing.allocator, std.testing.io, service_name, "fake-region");
    defer std.testing.allocator.free(region);
    try std.testing.expectEqualStrings("emea", region);
}

test "write refuses a value security -i would split, misread or prompt for, before running it" {
    const unstorable = [_][]const u8{
        "", "FAKE TOKEN", "FAKE\"", "FAKE'", "FAKE\\", "FAKE\n",
        "FAKÉ",
    };
    for (unstorable) |value| {
        try std.testing.expectError(error.UnstorableValue, write(
            std.testing.allocator,
            std.testing.io,
            "teams-zig-test-never-written",
            &.{.{ .account = "fake-token", .value = value }},
        ));
    }
}

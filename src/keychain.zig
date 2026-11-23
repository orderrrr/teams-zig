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

//! Generic passwords in the login keychain, keyed by service and account.

const std = @import("std");
const core_foundation = @import("core_foundation.zig");
const security = @import("security.zig");

pub const Error = error{
    ItemNotFound,
    UserCanceled,
    AuthFailed,
    InteractionNotAllowed,
    Unexpected,
    OutOfMemory,
};

/// Names one generic password. A struct, so service and account can't be swapped at a call site.
pub const Item = struct {
    service: []const u8,
    account: []const u8,
};

/// The item's names as CoreFoundation strings, which every SecItem query needs.
const Names = struct {
    service: *const core_foundation.String,
    account: *const core_foundation.String,

    fn init(item: Item) error{OutOfMemory}!Names {
        std.debug.assert(item.service.len > 0);
        std.debug.assert(item.account.len > 0);

        const service = try core_foundation.createString(item.service);
        errdefer core_foundation.release(service);

        return .{ .service = service, .account = try core_foundation.createString(item.account) };
    }

    fn deinit(names: *const Names) void {
        core_foundation.release(names.service);
        core_foundation.release(names.account);
    }

    fn query(names: *const Names) error{OutOfMemory}!*const core_foundation.Dictionary {
        return core_foundation.createDictionary(
            &.{ security.kSecClass, security.kSecAttrService, security.kSecAttrAccount },
            &.{ security.kSecClassGenericPassword, names.service, names.account },
        );
    }
};

/// Returns the stored value, owned by the caller: free it with `gpa`.
pub fn read(gpa: std.mem.Allocator, item: Item) Error![]u8 {
    const names = try Names.init(item);
    defer names.deinit();

    const query = try core_foundation.createDictionary(
        &.{
            security.kSecClass,
            security.kSecAttrService,
            security.kSecAttrAccount,
            security.kSecReturnData,
            security.kSecMatchLimit,
        },
        &.{
            security.kSecClassGenericPassword,
            names.service,
            names.account,
            core_foundation.kCFBooleanTrue,
            security.kSecMatchLimitOne,
        },
    );
    defer core_foundation.release(query);

    var result: ?*const anyopaque = null;
    try check(security.SecItemCopyMatching(query, &result));
    // With kSecReturnData and a success status, SecItemCopyMatching always hands back the data.
    std.debug.assert(result != null);
    const data: *const core_foundation.Data = @ptrCast(result.?);
    defer core_foundation.release(data);

    return gpa.dupe(u8, core_foundation.dataBytes(data));
}

/// Stores `value`, replacing any value already stored under `item`.
pub fn write(item: Item, value: []const u8) Error!void {
    const names = try Names.init(item);
    defer names.deinit();

    const data = try core_foundation.createData(value);
    defer core_foundation.release(data);

    const query = try names.query();
    defer core_foundation.release(query);

    const changes = try core_foundation.createDictionary(&.{security.kSecValueData}, &.{data});
    defer core_foundation.release(changes);

    switch (security.SecItemUpdate(query, changes)) {
        .item_not_found => {},
        else => |status| return check(status),
    }

    const attributes = try core_foundation.createDictionary(
        &.{
            security.kSecClass,
            security.kSecAttrService,
            security.kSecAttrAccount,
            security.kSecValueData,
        },
        &.{ security.kSecClassGenericPassword, names.service, names.account, data },
    );
    defer core_foundation.release(attributes);

    try check(security.SecItemAdd(attributes, null));
}

fn delete(item: Item) Error!void {
    const names = try Names.init(item);
    defer names.deinit();

    const query = try names.query();
    defer core_foundation.release(query);

    try check(security.SecItemDelete(query));
}

fn check(status: security.Status) Error!void {
    return switch (status) {
        .success => {},
        .item_not_found => error.ItemNotFound,
        .user_canceled => error.UserCanceled,
        .auth_failed => error.AuthFailed,
        .interaction_not_allowed => error.InteractionNotAllowed,
        else => error.Unexpected,
    };
}

const test_item: Item = .{ .service = "teams-zig-test", .account = "fake-account" };

test "write then read returns the value, and a second write replaces it" {
    const gpa = std.testing.allocator;
    try write(test_item, "fake-value-1");
    // A locked keychain can make cleanup fail; panic so the leftover item doesn't go unnoticed.
    defer delete(test_item) catch |err| {
        std.debug.panic("keychain test cleanup failed: {t}", .{err});
    };

    const first = try read(gpa, test_item);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("fake-value-1", first);

    try write(test_item, "fake-value-2");
    const second = try read(gpa, test_item);
    defer gpa.free(second);
    try std.testing.expectEqualStrings("fake-value-2", second);
}

test "reading a missing item fails with ItemNotFound" {
    const missing: Item = .{ .service = "teams-zig-test", .account = "missing-account" };
    try std.testing.expectError(error.ItemNotFound, read(std.testing.allocator, missing));
}

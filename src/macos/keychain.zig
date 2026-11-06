//! Generic passwords in the login keychain, keyed by service and account.

const std = @import("std");
const cf = @import("core_foundation.zig");
const security = @import("security.zig");

pub const Error = error{
    ItemNotFound,
    UserCanceled,
    AuthFailed,
    InteractionNotAllowed,
    Unexpected,
    OutOfMemory,
};

/// The service and account names as CoreFoundation strings, which every SecItem query needs.
const Names = struct {
    service: *const cf.String,
    account: *const cf.String,

    fn init(service: []const u8, account: []const u8) error{OutOfMemory}!Names {
        const service_string = try cf.createString(service);
        errdefer cf.release(service_string);
        return .{ .service = service_string, .account = try cf.createString(account) };
    }

    fn deinit(names: Names) void {
        cf.release(names.service);
        cf.release(names.account);
    }

    fn query(names: Names) error{OutOfMemory}!*const cf.Dictionary {
        return cf.createDictionary(
            &.{ security.kSecClass, security.kSecAttrService, security.kSecAttrAccount },
            &.{ security.kSecClassGenericPassword, names.service, names.account },
        );
    }
};

/// Returns the stored value, owned by the caller.
pub fn read(allocator: std.mem.Allocator, service: []const u8, account: []const u8) Error![]u8 {
    const names = try Names.init(service, account);
    defer names.deinit();
    const query = try cf.createDictionary(
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
            cf.kCFBooleanTrue,
            security.kSecMatchLimitOne,
        },
    );
    defer cf.release(query);

    var result: ?*const anyopaque = null;
    try check(security.SecItemCopyMatching(query, &result));
    const data: *const cf.Data = @ptrCast(result.?);
    defer cf.release(data);
    return allocator.dupe(u8, cf.dataBytes(data));
}

/// Stores `value`, replacing any value already under this service and account.
pub fn write(service: []const u8, account: []const u8, value: []const u8) Error!void {
    const names = try Names.init(service, account);
    defer names.deinit();
    const data = try cf.createData(value);
    defer cf.release(data);

    const query = try names.query();
    defer cf.release(query);
    const changes = try cf.createDictionary(&.{security.kSecValueData}, &.{data});
    defer cf.release(changes);
    switch (security.SecItemUpdate(query, changes)) {
        .item_not_found => {},
        else => |status| return check(status),
    }

    const attributes = try cf.createDictionary(
        &.{ security.kSecClass, security.kSecAttrService, security.kSecAttrAccount, security.kSecValueData },
        &.{ security.kSecClassGenericPassword, names.service, names.account, data },
    );
    defer cf.release(attributes);
    try check(security.SecItemAdd(attributes, null));
}

fn delete(service: []const u8, account: []const u8) Error!void {
    const names = try Names.init(service, account);
    defer names.deinit();
    const query = try names.query();
    defer cf.release(query);
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

const test_service = "teams-zig-test";

test "write then read returns the value, and a second write replaces it" {
    const allocator = std.testing.allocator;
    try write(test_service, "fake-account", "fake-value-1");
    defer delete(test_service, "fake-account") catch unreachable;

    const first = try read(allocator, test_service, "fake-account");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("fake-value-1", first);

    try write(test_service, "fake-account", "fake-value-2");
    const second = try read(allocator, test_service, "fake-account");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("fake-value-2", second);
}

test "reading a missing item fails with ItemNotFound" {
    try std.testing.expectError(
        error.ItemNotFound,
        read(std.testing.allocator, test_service, "missing-account"),
    );
}

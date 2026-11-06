//! The slice of Security.framework the keychain needs: the SecItem calls and their keys.

const std = @import("std");
const cf = @import("core_foundation.zig");

/// OSStatus values the keychain wrapper handles; any other code stays representable.
pub const Status = enum(i32) {
    success = 0,
    user_canceled = -128,
    auth_failed = -25293,
    duplicate_item = -25299,
    item_not_found = -25300,
    interaction_not_allowed = -25308,
    _,
};

pub extern const kSecClass: *const cf.String;
pub extern const kSecClassGenericPassword: *const cf.String;
pub extern const kSecAttrService: *const cf.String;
pub extern const kSecAttrAccount: *const cf.String;
pub extern const kSecValueData: *const cf.String;
pub extern const kSecReturnData: *const cf.String;
pub extern const kSecMatchLimit: *const cf.String;
pub extern const kSecMatchLimitOne: *const cf.String;

pub extern fn SecItemCopyMatching(query: *const cf.Dictionary, result: *?*const anyopaque) Status;
pub extern fn SecItemAdd(attributes: *const cf.Dictionary, result: ?*?*const anyopaque) Status;
pub extern fn SecItemUpdate(query: *const cf.Dictionary, changes: *const cf.Dictionary) Status;
pub extern fn SecItemDelete(query: *const cf.Dictionary) Status;

test "looking up a missing item reports item_not_found" {
    const service = try cf.createString("teams-zig-test-missing");
    defer cf.release(service);
    const query = try cf.createDictionary(
        &.{ kSecClass, kSecAttrService },
        &.{ kSecClassGenericPassword, service },
    );
    defer cf.release(query);

    var result: ?*const anyopaque = null;
    try std.testing.expectEqual(Status.item_not_found, SecItemCopyMatching(query, &result));
    try std.testing.expect(result == null);
}

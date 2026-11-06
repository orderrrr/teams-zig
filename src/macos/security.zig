//! The slice of Security.framework the keychain needs: the SecItem calls and their keys.

const std = @import("std");
const core_foundation = @import("core_foundation.zig");

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

pub extern const kSecClass: *const core_foundation.String;
pub extern const kSecClassGenericPassword: *const core_foundation.String;
pub extern const kSecAttrService: *const core_foundation.String;
pub extern const kSecAttrAccount: *const core_foundation.String;
pub extern const kSecValueData: *const core_foundation.String;
pub extern const kSecReturnData: *const core_foundation.String;
pub extern const kSecMatchLimit: *const core_foundation.String;
pub extern const kSecMatchLimitOne: *const core_foundation.String;

pub extern fn SecItemCopyMatching(
    query: *const core_foundation.Dictionary,
    result: *?*const anyopaque,
) Status;
pub extern fn SecItemAdd(
    attributes: *const core_foundation.Dictionary,
    result: ?*?*const anyopaque,
) Status;
pub extern fn SecItemUpdate(
    query: *const core_foundation.Dictionary,
    changes: *const core_foundation.Dictionary,
) Status;
pub extern fn SecItemDelete(query: *const core_foundation.Dictionary) Status;

test "looking up a missing item reports item_not_found" {
    const service = try core_foundation.createString("teams-zig-test-missing");
    defer core_foundation.release(service);
    const query = try core_foundation.createDictionary(
        &.{ kSecClass, kSecAttrService },
        &.{ kSecClassGenericPassword, service },
    );
    defer core_foundation.release(query);

    var result: ?*const anyopaque = null;
    const status = SecItemCopyMatching(query, &result);
    try std.testing.expectEqual(Status.item_not_found, status);
    try std.testing.expect(result == null);
}

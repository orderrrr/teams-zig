//! The signed-in user, from `GET /users/ME/properties`.

const User = @This();

const std = @import("std");

name: []const u8,
upn: []const u8,

pub const ParseError = std.json.ParseError(std.json.Scanner);

/// `properties` is the response body. Its `userDetails` field is itself a JSON string.
pub fn parse(allocator: std.mem.Allocator, properties: []const u8) ParseError!User {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const outer = try std.json.parseFromSlice(struct { userDetails: []const u8 }, allocator, properties, options);
    defer outer.deinit();
    const details = try std.json.parseFromSlice(
        struct { name: []const u8, upn: []const u8 },
        allocator,
        outer.value.userDetails,
        options,
    );
    defer details.deinit();

    const name = try allocator.dupe(u8, details.value.name);
    errdefer allocator.free(name);
    return .{ .name = name, .upn = try allocator.dupe(u8, details.value.upn) };
}

pub fn deinit(user: User, allocator: std.mem.Allocator) void {
    allocator.free(user.name);
    allocator.free(user.upn);
}

test "parse reads name and upn out of the nested userDetails string" {
    const properties =
        \\{"locale":"en-gb","userDetails":"{\"name\":\"Fake Person\",\"upn\":\"fake@example.com\"}"}
    ;
    const user = try parse(std.testing.allocator, properties);
    defer user.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Fake Person", user.name);
    try std.testing.expectEqualStrings("fake@example.com", user.upn);
}

test "parse fails when userDetails is missing" {
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, "{\"locale\":\"en-gb\"}"));
}

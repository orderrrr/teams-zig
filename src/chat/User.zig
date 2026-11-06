//! The signed-in user, from `GET /users/ME/properties`.

const User = @This();

const std = @import("std");
const json = @import("json.zig");

gpa: std.mem.Allocator,
name: []const u8,
upn: []const u8,

/// `properties` is the response body. Its `userDetails` field is itself a JSON string.
/// The result is owned by the caller: free it with `deinit`.
pub fn parse(gpa: std.mem.Allocator, properties: []const u8) json.ParseError!User {
    const Properties = struct { userDetails: []const u8 };
    const outer = try std.json.parseFromSlice(Properties, gpa, properties, json.parse_options);
    defer outer.deinit();

    const Details = struct { name: []const u8, upn: []const u8 };
    const details = try std.json.parseFromSlice(
        Details,
        gpa,
        outer.value.userDetails,
        json.parse_options,
    );
    defer details.deinit();

    const name = try gpa.dupe(u8, details.value.name);
    errdefer gpa.free(name);

    return .{ .gpa = gpa, .name = name, .upn = try gpa.dupe(u8, details.value.upn) };
}

pub fn deinit(user: *const User) void {
    user.gpa.free(user.name);
    user.gpa.free(user.upn);
}

test "parse reads name and upn out of the nested userDetails string" {
    const properties =
        \\{"locale":"en-gb",
        \\ "userDetails":"{\"name\":\"Fake Person\",\"upn\":\"fake@example.com\"}"}
    ;
    const user = try parse(std.testing.allocator, properties);
    defer user.deinit();

    try std.testing.expectEqualStrings("Fake Person", user.name);
    try std.testing.expectEqualStrings("fake@example.com", user.upn);
}

test "parse fails when userDetails is missing" {
    const result = parse(std.testing.allocator, "{\"locale\":\"en-gb\"}");
    try std.testing.expectError(error.MissingField, result);
}

test "parse fails when userDetails isn't valid JSON" {
    const properties = "{\"userDetails\":\"not json\"}";
    const result = parse(std.testing.allocator, properties);
    try std.testing.expectError(error.SyntaxError, result);
}

//! An authenticated connection to the Teams Chat Service at `{region}.ng.msg.teams.microsoft.com/v1`.

const Client = @This();

const std = @import("std");

allocator: std.mem.Allocator,
http: std.http.Client,
region: Region,
/// The `Authentication` header value, `skypetoken=<token>`. Owned.
authentication: []const u8,

pub const Region = enum { amer, emea, apac };

pub const Error = error{
    /// The skype token was rejected: it expires after about a day, so rerun the token script.
    TokenExpired,
    UnexpectedStatus,
} || std.http.Client.FetchError || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator, io: std.Io, region: Region, skype_token: []const u8) error{OutOfMemory}!Client {
    std.debug.assert(skype_token.len > 0);
    return .{
        .allocator = allocator,
        .http = .{ .allocator = allocator, .io = io },
        .region = region,
        .authentication = try std.fmt.allocPrint(allocator, "skypetoken={s}", .{skype_token}),
    };
}

pub fn deinit(client: *Client) void {
    client.http.deinit();
    client.allocator.free(client.authentication);
    client.* = undefined;
}

/// GETs `path` (starting with `/`) under the Chat Service base URL. Returns the body, owned by the caller.
pub fn get(client: *Client, path: []const u8) Error![]u8 {
    const full_url = try client.url(path);
    defer client.allocator.free(full_url);

    var body: std.Io.Writer.Allocating = .init(client.allocator);
    defer body.deinit();
    const result = try client.http.fetch(.{
        .location = .{ .url = full_url },
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "Authentication", .value = client.authentication },
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    switch (result.status) {
        .ok => return body.toOwnedSlice(),
        .unauthorized => return error.TokenExpired,
        else => return error.UnexpectedStatus,
    }
}

fn url(client: *const Client, path: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));
    return std.fmt.allocPrint(
        client.allocator,
        "https://{t}.ng.msg.teams.microsoft.com/v1{s}",
        .{ client.region, path },
    );
}

test "url puts the region in the host and the path under /v1" {
    var client: Client = try .init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    const result = try client.url("/users/ME/properties");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://emea.ng.msg.teams.microsoft.com/v1/users/ME/properties", result);
}

test "the Authentication header carries the skypetoken prefix" {
    var client: Client = try .init(std.testing.allocator, std.testing.io, .amer, "fake-token");
    defer client.deinit();
    try std.testing.expectEqualStrings("skypetoken=fake-token", client.authentication);
}

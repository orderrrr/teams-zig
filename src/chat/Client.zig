//! An authenticated connection to the Teams Chat Service at `{region}.ng.msg.teams.microsoft.com/v1`.

const Client = @This();

const std = @import("std");
const Conversation = @import("Conversation.zig");
const Message = @import("Message.zig");
const User = @import("User.zig");

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
    /// A link from the service pointed outside the Chat Service; it isn't followed, so the token stays put.
    ForeignLink,
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
    return client.getUrl(full_url);
}

/// GETs a full URL, such as a pagination link the service sent. It must be under the base URL.
pub fn getUrl(client: *Client, full_url: []const u8) Error![]u8 {
    const base = baseUrl(client.region);
    if (!std.mem.startsWith(u8, full_url, base)) return error.ForeignLink;
    if (full_url.len > base.len and full_url[base.len] != '/') return error.ForeignLink;

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

/// Returns the signed-in user, owned by the caller: free it with `User.deinit`.
pub fn whoami(client: *Client) (Error || User.ParseError)!User {
    const body = try client.get("/users/ME/properties");
    defer client.allocator.free(body);
    return User.parse(client.allocator, body);
}

/// Returns your most recent conversations, newest first, without system streams.
pub fn chats(client: *Client, page_size: u16) (Error || Conversation.ParseError)!Conversation.List {
    std.debug.assert(page_size > 0);
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/users/ME/conversations?view=mychats&pageSize={d}", .{page_size}) catch
        unreachable;
    const body = try client.get(path);
    defer client.allocator.free(body);
    return Conversation.parseList(client.allocator, body);
}

/// Returns up to `limit` of a conversation's messages, newest first, following older pages as needed.
pub fn messages(
    client: *Client,
    conversation_id: []const u8,
    limit: u32,
) (Error || Message.ParseError)!Message.List {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(limit > 0);
    const page_size = @min(limit, page_size_max);

    const arena = try client.allocator.create(std.heap.ArenaAllocator);
    errdefer client.allocator.destroy(arena);
    arena.* = .init(client.allocator);
    errdefer arena.deinit();

    var first_url: std.Io.Writer.Allocating = .init(arena.allocator());
    first_url.writer.print("{s}/users/ME/conversations/", .{baseUrl(client.region)}) catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(&first_url.writer, conversation_id, isUnreserved) catch return error.OutOfMemory;
    first_url.writer.print("/messages?view=superchat&pageSize={d}", .{page_size}) catch return error.OutOfMemory;

    var items: std.ArrayList(Message) = .empty;
    var link: ?[]const u8 = first_url.written();
    var pages: u32 = 0;
    while (link) |page_url| : (pages += 1) {
        if (items.items.len >= limit) break;
        std.debug.assert(pages <= limit / page_size + 1);
        const body = try client.getUrl(page_url);
        defer client.allocator.free(body);
        const page = try Message.parsePage(arena.allocator(), body);
        try items.appendSlice(arena.allocator(), page.items[0..@min(page.items.len, limit - items.items.len)]);
        link = page.backward_link;
    }
    return .{ .arena = arena, .items = items.items };
}

/// Keeps each response bounded; larger limits take more pages.
const page_size_max = 200;

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn baseUrl(region: Region) []const u8 {
    return switch (region) {
        inline else => |tag| "https://" ++ @tagName(tag) ++ ".ng.msg.teams.microsoft.com/v1",
    };
}

fn url(client: *const Client, path: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));
    return std.mem.concat(client.allocator, u8, &.{ baseUrl(client.region), path });
}

test "url puts the region in the host and the path under /v1" {
    var client: Client = try .init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    const result = try client.url("/users/ME/properties");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://emea.ng.msg.teams.microsoft.com/v1/users/ME/properties", result);
}

test "getUrl refuses links outside the Chat Service base URL" {
    var client: Client = try .init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    try std.testing.expectError(error.ForeignLink, client.getUrl("https://example.com/v1/users/ME"));
    try std.testing.expectError(error.ForeignLink, client.getUrl("https://emea.ng.msg.teams.microsoft.com/v1.evil.com/x"));
    try std.testing.expectError(error.ForeignLink, client.getUrl("https://amer.ng.msg.teams.microsoft.com/v1/users/ME"));
}

test "the Authentication header carries the skypetoken prefix" {
    var client: Client = try .init(std.testing.allocator, std.testing.io, .amer, "fake-token");
    defer client.deinit();
    try std.testing.expectEqualStrings("skypetoken=fake-token", client.authentication);
}

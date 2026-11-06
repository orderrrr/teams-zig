//! An authenticated connection to the Teams Chat Service,
//! at `{region}.ng.msg.teams.microsoft.com/v1`.

const Client = @This();

const std = @import("std");
const json = @import("json.zig");
const Conversation = @import("Conversation.zig");
const Message = @import("Message.zig");
const User = @import("User.zig");

gpa: std.mem.Allocator,
http: std.http.Client,
region: Region,
/// The `Authentication` header value, `skypetoken=<token>`. Owned.
authentication: []const u8,
/// Holds the latest response body. Allocated once, `body_size_max` long.
body_buffer: []u8,
/// The status of the latest response, for error messages.
response_status: ?std.http.Status = null,

pub const Region = enum {
    amer,
    emea,
    apac,

    pub fn baseUrl(region: Region) []const u8 {
        return switch (region) {
            inline else => |tag| "https://" ++ @tagName(tag) ++ ".ng.msg.teams.microsoft.com/v1",
        };
    }
};

pub const Error = error{
    /// The skype token was rejected: it expires after about a day, so rerun the token script.
    TokenExpired,
    /// 404: usually a conversation id that doesn't exist or isn't yours.
    NotFound,
    /// Any other non-200 status; `response_status` has it.
    UnexpectedStatus,
    /// A link from the service pointed outside the Chat Service. It isn't followed, so the token
    /// stays with the Chat Service.
    ForeignLink,
    ResponseTooLarge,
} || std.http.Client.FetchError || std.mem.Allocator.Error;

/// Big enough for a full page of HTML-heavy messages; anything larger is refused, not truncated.
const body_size_max = 8 * 1024 * 1024;

/// Keeps each response bounded; larger counts take more pages.
const page_size_max = 200;

/// Bounds how many pages `messages` follows. The service can send empty pages that still link to
/// older ones, so the page count isn't tied to the message count.
const page_count_max = 64;

comptime {
    std.debug.assert(page_size_max > 0);
    std.debug.assert(page_count_max > 0);
    std.debug.assert(body_size_max >= std.json.default_max_value_len);
}

pub fn init(
    client: *Client,
    gpa: std.mem.Allocator,
    io: std.Io,
    region: Region,
    skype_token: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(skype_token.len > 0);

    const authentication = try std.fmt.allocPrint(gpa, "skypetoken={s}", .{skype_token});
    errdefer gpa.free(authentication);

    client.* = .{
        .gpa = gpa,
        .http = .{ .allocator = gpa, .io = io },
        .region = region,
        .authentication = authentication,
        .body_buffer = try gpa.alloc(u8, body_size_max),
    };
}

pub fn deinit(client: *Client) void {
    std.debug.assert(client.authentication.len > 0);
    client.http.deinit();
    client.gpa.free(client.authentication);
    client.gpa.free(client.body_buffer);
    client.* = undefined;
}

/// GETs `path` (starting with `/`) under the Chat Service base URL.
/// The body is borrowed: it's valid until the next request.
pub fn get(client: *Client, path: []const u8) Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));

    const url = try std.mem.concat(client.gpa, u8, &.{ client.region.baseUrl(), path });
    defer client.gpa.free(url);

    return client.getUrl(url);
}

/// GETs a full URL, such as a pagination link the service sent. It must be under the base URL.
/// The body is borrowed: it's valid until the next request.
pub fn getUrl(client: *Client, url: []const u8) Error![]const u8 {
    std.debug.assert(client.authentication.len > 0);
    const base = client.region.baseUrl();
    if (!std.mem.startsWith(u8, url, base)) return error.ForeignLink;
    if (!std.mem.startsWith(u8, url[base.len..], "/")) return error.ForeignLink;
    std.debug.assert(url.len > base.len);

    var body: std.Io.Writer = .fixed(client.body_buffer);
    var redirect_buffer: [8 * 1024]u8 = undefined;
    const result = client.http.fetch(.{
        .location = .{ .url = url },
        .raw_uri = false,
        .method = .GET,
        .payload = null,
        .headers = .{
            .host = .default,
            .authorization = .default,
            .user_agent = .default,
            .connection = .default,
            .accept_encoding = .default,
            .content_type = .default,
        },
        .keep_alive = true,
        // Redirects are refused so the token never leaves the Chat Service host. std would
        // keep extra headers across a cross-domain redirect, and in 0.17 it never sends
        // privileged_headers at all, so those can't carry the token instead.
        .redirect_behavior = .not_allowed,
        .redirect_buffer = &redirect_buffer,
        .decompress_buffer = null,
        .response_writer = &body,
        .extra_headers = &.{
            .{ .name = "Authentication", .value = client.authentication },
            .{ .name = "Accept", .value = "application/json" },
        },
        .privileged_headers = &.{},
    }) catch |err| switch (err) {
        // The fixed writer only fails when the body outgrows the buffer.
        error.WriteFailed => return error.ResponseTooLarge,
        else => |other| return other,
    };

    client.response_status = result.status;
    return switch (result.status) {
        .ok => okBody: {
            std.debug.assert(body.buffered().len <= body_size_max);
            break :okBody body.buffered();
        },
        .unauthorized => error.TokenExpired,
        .not_found => error.NotFound,
        else => error.UnexpectedStatus,
    };
}

/// Returns the signed-in user, owned by the caller: free it with `User.deinit`.
pub fn whoami(client: *Client) (Error || json.ParseError)!User {
    const body = try client.get("/users/ME/properties");
    return User.parse(client.gpa, body);
}

/// Returns your most recent conversations, newest first, without system streams.
/// The result is owned by the caller: free it with `List.deinit`.
pub fn chats(client: *Client, page_size: u16) (Error || json.ParseError)!Conversation.List {
    std.debug.assert(page_size > 0);
    std.debug.assert(page_size <= page_size_max);

    const path_prefix = "/users/ME/conversations?view=mychats&pageSize=";
    // A u16 has at most 5 decimal digits, so the formatted path always fits.
    comptime std.debug.assert(std.math.maxInt(u16) < 100_000);
    var path_buffer: [path_prefix.len + 5]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, path_prefix ++ "{d}", .{page_size}) catch
        unreachable;

    const body = try client.get(path);
    return Conversation.parseList(client.gpa, body);
}

/// Returns up to `message_count_max` of a conversation's messages, newest first, following older
/// pages as needed. Stops early after `page_count_max` pages, returning what it has.
/// The result is owned by the caller: free it with `List.deinit`.
pub fn messages(
    client: *Client,
    conversation_id: []const u8,
    message_count_max: u32,
) (Error || json.ParseError)!Message.List {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(message_count_max > 0);
    const page_size = @min(message_count_max, page_size_max);

    var list: Message.List = try .init(client.gpa);
    errdefer list.deinit();

    const url_first = try client.messagesUrl(conversation_id, page_size);
    defer client.gpa.free(url_first);

    const arena = list.arena.allocator();
    var items: std.ArrayList(Message) = .empty;
    var link: ?[]const u8 = url_first;
    var page_count: u32 = 0;
    while (link) |page_url| : (page_count += 1) {
        if (items.items.len == message_count_max) break;
        if (page_count == page_count_max) break;

        const page = try Message.parsePage(arena, try client.getUrl(page_url));
        const room = message_count_max - items.items.len;
        try items.appendSlice(arena, page.items[0..@min(page.items.len, room)]);
        link = page.backward_link;
    }
    std.debug.assert(items.items.len <= message_count_max);

    list.items = items.items;
    return list;
}

/// The first messages page for a conversation, with the id percent-encoded. Owned by the caller.
fn messagesUrl(
    client: *const Client,
    conversation_id: []const u8,
    page_size: u32,
) error{OutOfMemory}![]u8 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(page_size > 0);
    std.debug.assert(page_size <= page_size_max);

    var url: std.Io.Writer.Allocating = .init(client.gpa);
    errdefer url.deinit();

    const writer = &url.writer;
    const base = client.region.baseUrl();
    writer.print("{s}/users/ME/conversations/", .{base}) catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(writer, conversation_id, isUnreserved) catch
        return error.OutOfMemory;
    writer.print("/messages?view=superchat&pageSize={d}", .{page_size}) catch
        return error.OutOfMemory;

    const result = try url.toOwnedSlice();
    std.debug.assert(std.mem.startsWith(u8, result, base));
    return result;
}

fn isUnreserved(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

test "baseUrl puts the region in the host" {
    const expected = "https://emea.ng.msg.teams.microsoft.com/v1";
    try std.testing.expectEqualStrings(expected, Region.emea.baseUrl());
}

test "messagesUrl percent-encodes the conversation id" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();

    const url = try client.messagesUrl("19:fake@thread.v2", 50);
    defer std.testing.allocator.free(url);

    const expected = "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/conversations/" ++
        "19%3Afake%40thread.v2/messages?view=superchat&pageSize=50";
    try std.testing.expectEqualStrings(expected, url);
}

test "getUrl refuses links outside the Chat Service base URL" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();

    const foreign_urls = [_][]const u8{
        "https://example.com/v1/users/ME",
        "https://emea.ng.msg.teams.microsoft.com/v1.evil.com/x",
        "https://emea.ng.msg.teams.microsoft.com/v1",
        "https://amer.ng.msg.teams.microsoft.com/v1/users/ME",
    };
    for (foreign_urls) |foreign_url| {
        try std.testing.expectError(error.ForeignLink, client.getUrl(foreign_url));
    }
}

test "the Authentication header carries the skypetoken prefix" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .amer, "fake-token");
    defer client.deinit();

    try std.testing.expectEqualStrings("skypetoken=fake-token", client.authentication);
}

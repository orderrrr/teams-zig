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
const page_item_count_max = 200;

/// Bounds how many pages `messages` follows. The service can send empty pages that still link to
/// older ones, so the page count isn't tied to the message count.
const page_count_max = 64;

/// The most messages `messages` can ever collect.
const message_count_limit = page_item_count_max * page_count_max;

comptime {
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
        // Configuration spelled out; the connection pool and CA bundle are state, left to std.
        // No TLS key log: it would let anyone reading it decrypt the token.
        .http = .{
            .allocator = gpa,
            .io = io,
            .tls_buffer_size = std.crypto.tls.Client.min_buffer_len,
            .ssl_key_log = null,
            // std's defaults. The read buffer also bounds a response head, and Chat Service
            // heads fit in 8 KiB.
            .read_buffer_size = 8192,
            .write_buffer_size = 1024,
            // Null: std reads the clock and rescans root certificates on the first HTTPS request.
            .now = null,
            .http_proxy = null,
            .https_proxy = null,
        },
        .region = region,
        .authentication = authentication,
        .body_buffer = try gpa.alloc(u8, body_size_max),
    };
}

pub fn deinit(client: *Client) void {
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
    const base = client.region.baseUrl();
    if (!std.mem.startsWith(u8, url, base)) return error.ForeignLink;
    if (!std.mem.startsWith(u8, url[base.len..], "/")) return error.ForeignLink;

    var body: std.Io.Writer = .fixed(client.body_buffer);
    // Redirects are refused, but std reads the head into this buffer and would heap-allocate one
    // if it were null; RFC 9110 recommends room for at least 8000 bytes.
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
        // WriteFailed comes from sending the request too, and the request is sent before any
        // body byte arrives: only a failure after body bytes means the body outgrew the buffer.
        error.WriteFailed => {
            if (body.end == 0) return error.WriteFailed;
            return error.ResponseTooLarge;
        },
        else => |other| return other,
    };

    client.response_status = result.status;
    return switch (result.status) {
        .ok => body.buffered(),
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
pub fn conversations(
    client: *Client,
    page_item_count: u16,
) (Error || json.ParseError)!Conversation.List {
    std.debug.assert(page_item_count > 0);
    std.debug.assert(page_item_count <= page_item_count_max);

    const path_prefix = "/users/ME/conversations?view=mychats&pageSize=";
    // A u16 has at most 5 decimal digits, so the formatted path always fits.
    comptime std.debug.assert(std.math.maxInt(u16) < 100_000);
    var path_buffer: [path_prefix.len + 5]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, path_prefix ++ "{d}", .{page_item_count}) catch
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
    // page_count_max pages can't hold more, so a larger count would only reserve dead memory.
    std.debug.assert(message_count_max <= message_count_limit);
    const page_item_count = @min(message_count_max, page_item_count_max);

    var list: Message.List = try .init(client.gpa);
    errdefer list.deinit();

    const url_first = try client.messagesUrl(conversation_id, page_item_count);
    defer client.gpa.free(url_first);

    list.items = try collectMessages(list.arena.allocator(), client, url_first, message_count_max);
    return list;
}

/// Walks pages from `url_first` through each `backwardLink`, keeping up to `message_count_max`
/// messages, and stops after `page_count_max` pages. `source.getUrl(url)` returns a page body,
/// borrowed until its next call: the Client in use, a canned source in tests.
fn collectMessages(
    arena: std.mem.Allocator,
    source: anytype,
    url_first: []const u8,
    message_count_max: u32,
) (Error || json.ParseError)![]const Message {
    std.debug.assert(url_first.len > 0);
    std.debug.assert(message_count_max > 0);
    std.debug.assert(message_count_max <= message_count_limit);

    var items: std.ArrayList(Message) = try .initCapacity(arena, message_count_max);
    var link: ?[]const u8 = url_first;
    var page_count: u32 = 0;
    while (link) |page_url| : (page_count += 1) {
        if (items.items.len == message_count_max) break;
        if (page_count == page_count_max) break;

        const page = try Message.parsePage(arena, try source.getUrl(page_url));
        const room_count = message_count_max - items.items.len;
        items.appendSliceAssumeCapacity(page.items[0..@min(page.items.len, room_count)]);
        link = page.backward_link;
    }
    std.debug.assert(items.items.len <= message_count_max);
    std.debug.assert(page_count <= page_count_max);

    return items.items;
}

/// The first messages page for a conversation, with the id percent-encoded. Owned by the caller.
fn messagesUrl(
    client: *const Client,
    conversation_id: []const u8,
    page_item_count: u32,
) error{OutOfMemory}![]u8 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(page_item_count > 0);
    std.debug.assert(page_item_count <= page_item_count_max);

    var url: std.Io.Writer.Allocating = .init(client.gpa);
    errdefer url.deinit();

    const writer = &url.writer;
    const base = client.region.baseUrl();
    // An Allocating writer fails only when it can't grow, so every writer error here is OOM.
    writer.print("{s}/users/ME/conversations/", .{base}) catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(writer, conversation_id, isUnreserved) catch
        return error.OutOfMemory;
    writer.print("/messages?view=superchat&pageSize={d}", .{page_item_count}) catch
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

/// Serves canned page bodies in order, repeating the last one, and counts the requests.
const CannedPages = struct {
    bodies: []const []const u8,
    request_count: u32 = 0,

    fn getUrl(pages: *CannedPages, url: []const u8) Error![]const u8 {
        std.debug.assert(url.len > 0);
        std.debug.assert(pages.bodies.len > 0);
        const index = @min(pages.request_count, pages.bodies.len - 1);
        pages.request_count += 1;
        return pages.bodies[index];
    }
};

const canned_empty_with_link =
    \\{"_metadata":{"backwardLink":"https://x/older"},"messages":[]}
;
const canned_two_with_link =
    \\{"_metadata":{"backwardLink":"https://x/older"},"messages":[
    \\ {"id":"2","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:02Z"},
    \\ {"id":"1","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:01Z"}]}
;
const canned_one_oldest =
    \\{"_metadata":{"backwardLink":null},"messages":[
    \\ {"id":"0","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:00Z"}]}
;

test "collectMessages keeps going past empty pages that link to older ones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{
        .bodies = &.{ canned_empty_with_link, canned_empty_with_link, canned_one_oldest },
    };
    const items = try collectMessages(arena.allocator(), &pages, "https://x/first", 50);
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqualStrings("0", items[0].id);
    try std.testing.expectEqual(3, pages.request_count);
}

test "collectMessages stops at the message count without fetching further" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{ .bodies = &.{ canned_two_with_link, canned_two_with_link } };
    const items = try collectMessages(arena.allocator(), &pages, "https://x/first", 3);
    try std.testing.expectEqual(3, items.len);
    try std.testing.expectEqual(2, pages.request_count);
}

test "collectMessages stops after page_count_max endless empty pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{ .bodies = &.{canned_empty_with_link} };
    const items = try collectMessages(arena.allocator(), &pages, "https://x/first", 50);
    try std.testing.expectEqual(0, items.len);
    try std.testing.expectEqual(page_count_max, pages.request_count);
}

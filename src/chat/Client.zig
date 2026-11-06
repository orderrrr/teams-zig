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
authentication: []u8,
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
    /// A link from the service pointed outside the Chat Service, or carried bytes that don't belong
    /// on a request line. It isn't followed, so the token stays with the Chat Service.
    ForeignLink,
    ResponseTooLarge,
    /// Couldn't reach the Chat Service: the name lookup, the connection or TLS failed.
    ConnectFailed,
    /// Sending the request failed, such as on a connection the server had closed.
    SendFailed,
    /// The connection dropped before the whole response arrived.
    ConnectionDropped,
    /// The response broke HTTP: malformed headers or chunks, or an unsupported encoding.
    BadResponse,
    /// The service redirected. Redirects are refused, so the token stays with the Chat Service.
    Redirected,
    /// The JSON didn't have the shape the client expects; the service may have changed it.
    UnexpectedJson,
    OutOfMemory,
};

/// Big enough for a full page of HTML-heavy messages; anything larger is refused, not truncated.
const body_size_max = 8 * 1024 * 1024;

/// Keeps each response bounded; larger counts take more pages.
const page_item_count_max = 200;

/// Bounds how many pages `messages` follows. The service can send empty pages that still link to
/// older ones, so the page count isn't tied to the message count.
const page_count_max = 64;

/// The most messages `messages` can ever collect.
const message_count_limit = page_item_count_max * page_count_max;

pub fn init(
    client: *Client,
    gpa: std.mem.Allocator,
    io: std.Io,
    region: Region,
    skype_token: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(skype_token.len > 0);
    // The token goes into a header, where a line break would end it early.
    std.debug.assert(std.mem.indexOfAny(u8, skype_token, "\r\n") == null);

    const authentication = try std.fmt.allocPrint(gpa, "skypetoken={s}", .{skype_token});
    errdefer {
        std.crypto.secureZero(u8, authentication);
        gpa.free(authentication);
    }

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
    // It holds the token: zero our copy. std's connection buffers keep their own until exit.
    std.crypto.secureZero(u8, client.authentication);
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
    // Cleared first, so a status only ever describes this request.
    client.response_status = null;
    const base = client.region.baseUrl();
    if (!std.mem.startsWith(u8, url, base)) return error.ForeignLink;
    if (!std.mem.startsWith(u8, url[base.len..], "/")) return error.ForeignLink;

    // std writes the path and query onto the request line as given, so a link carrying spaces,
    // control bytes or non-ASCII could add headers or a second request.
    for (url) |byte| {
        if (byte <= ' ') return error.ForeignLink;
        if (byte >= 0x7f) return error.ForeignLink;
    }
    const uri = std.Uri.parse(url) catch return error.ForeignLink;
    var request = client.http.request(.GET, uri, .{
        .version = .@"HTTP/1.1",
        .handle_continue = true,
        .keep_alive = true,
        // Redirects are refused so the token never leaves the Chat Service host. std would keep
        // extra headers across a cross-domain redirect, and in 0.17 it never sends
        // privileged_headers at all, so those can't carry the token instead.
        .redirect_behavior = .not_allowed,
        .connection = null,
        .headers = .{
            .host = .default,
            .authorization = .default,
            .user_agent = .default,
            .connection = .default,
            // Written out: with only identity enabled, std 0.17 sends a bare "accept-encoding" line
            // with no colon (it undoes the ", " of a list it never wrote), which gets a 400.
            .accept_encoding = .{ .override = "identity" },
            .content_type = .default,
        },
        .extra_headers = &.{
            .{ .name = "Authentication", .value = client.authentication },
            .{ .name = "Accept", .value = "application/json" },
        },
        .privileged_headers = &.{},
    }) catch |err| return requestError(err);
    defer request.deinit();

    // Uncompressed only: receiveHead refuses any encoding not listed here, so the body never
    // needs a decompressor (std's zstd path would need a bigger buffer than fetch gives it).
    request.accept_encoding = @splat(false);
    request.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;

    request.sendBodiless() catch return error.SendFailed;
    // Redirects are refused, so receiveHead never needs a redirect buffer.
    var response = request.receiveHead(&.{}) catch |err| return receiveHeadError(err);

    client.response_status = response.head.status;
    switch (response.head.status) {
        .ok => {},
        .unauthorized => return error.TokenExpired,
        .not_found => return error.NotFound,
        else => return error.UnexpectedStatus,
    }

    std.debug.assert(response.head.content_encoding == .identity);

    var body: std.Io.Writer = .fixed(client.body_buffer);
    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    // Read here rather than through fetch: fetch unwraps bodyErr() on ReadFailed, which is null
    // when the connection drops mid-body, and crashes.
    _ = reader.streamRemaining(&body) catch |err| return bodyError(err, response.bodyErr());

    try bodyEndCheck(request.reader.state);
    return body.buffered();
}

/// After a clean read, says whether the whole body arrived. A clean close mid-body reads as the
/// end of the stream, so a content length not yet met means the connection dropped.
fn bodyEndCheck(state: std.http.Reader.State) error{ConnectionDropped}!void {
    switch (state) {
        .ready => {},
        // No length to check against: the body runs until the server closes the connection.
        .body_none => {},
        .body_remaining_content_length => return error.ConnectionDropped,
        // streamRemaining only ends cleanly in the states above, and a client never closes.
        .received_head, .body_remaining_chunk_len, .closing => unreachable,
    }
}

/// Name lookup, TCP and TLS failures, and failing to load the system's root certificates, all
/// mean the Chat Service couldn't be reached.
fn requestError(err: std.http.Client.RequestError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectFailed,
    };
}

fn receiveHeadError(err: std.http.Client.Request.ReceiveHeadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyHttpRedirects => error.Redirected,
        error.ReadFailed, error.HttpRequestTruncated, error.HttpConnectionClosing => {
            return error.ConnectionDropped;
        },
        error.WriteFailed => error.SendFailed,
        else => error.BadResponse,
    };
}

/// The body writer is a fixed buffer, so its only failure is running out of room. A read failure
/// with no body error is a socket or TLS failure; a truncated chunk is a dropped connection too;
/// other body errors mean the server broke HTTP.
fn bodyError(err: std.Io.Reader.StreamRemainingError, body_err: ?std.http.Reader.BodyError) Error {
    return switch (err) {
        error.WriteFailed => error.ResponseTooLarge,
        error.ReadFailed => {
            const reason = body_err orelse return error.ConnectionDropped;
            return switch (reason) {
                error.HttpChunkTruncated => error.ConnectionDropped,
                error.HttpChunkInvalid, error.HttpHeadersOversize => error.BadResponse,
            };
        },
    };
}

/// Running out of memory stays itself; any other parse failure means the JSON's shape changed.
fn parseError(err: json.ParseError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedJson,
    };
}

/// Returns the signed-in user, owned by the caller: free it with `User.deinit`.
pub fn whoami(client: *Client) Error!User {
    const body = try client.get("/users/ME/properties");
    return User.parse(client.gpa, body) catch |err| parseError(err);
}

/// Returns your most recent conversations, newest first, without system streams.
/// The result is owned by the caller: free it with `List.deinit`.
pub fn conversations(
    client: *Client,
    conversation_count_max: u16,
) Error!Conversation.List {
    std.debug.assert(conversation_count_max > 0);
    std.debug.assert(conversation_count_max <= page_item_count_max);

    const path_prefix = "/users/ME/conversations?view=mychats&pageSize=";
    // Sized for the largest count the assert above allows, so the formatted path always fits.
    var path_buffer: [path_prefix.len + std.fmt.count("{d}", .{page_item_count_max})]u8 = undefined;
    const path_format = path_prefix ++ "{d}";
    const path = std.fmt.bufPrint(&path_buffer, path_format, .{conversation_count_max}) catch
        unreachable;

    const body = try client.get(path);
    return Conversation.parseList(client.gpa, body) catch |err| parseError(err);
}

/// Returns up to `message_count_max` of a conversation's messages, newest first, following older
/// pages as needed. Stops early after `page_count_max` pages, returning what it has.
/// The result is owned by the caller: free it with `List.deinit`.
pub fn messages(
    client: *Client,
    conversation_id: []const u8,
    message_count_max: u32,
) Error!Message.List {
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
) Error![]const Message {
    std.debug.assert(url_first.len > 0);
    std.debug.assert(message_count_max > 0);
    std.debug.assert(message_count_max <= message_count_limit);

    var items: std.ArrayList(Message) = try .initCapacity(arena, message_count_max);
    var link: ?[]const u8 = url_first;
    var page_count: u32 = 0;
    while (link) |page_url| : (page_count += 1) {
        if (items.items.len == message_count_max) break;
        if (page_count == page_count_max) break;

        const body = try source.getUrl(page_url);
        const page = Message.parsePage(arena, body) catch |err| return parseError(err);
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
        "https://emea.ng.msg.teams.microsoft.com/v1/x\r\nX-Injected: 1",
        "https://emea.ng.msg.teams.microsoft.com/v1/x HTTP/1.1",
        "https://emea.ng.msg.teams.microsoft.com/v1/caf\xc3\xa9",
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
    /// Borrowed: the canned bodies must outlive the source.
    bodies: []const []const u8,
    request_count: u32 = 0,

    fn getUrl(pages: *CannedPages, url: []const u8) Error![]const u8 {
        _ = url;
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

test "bodyError tells a dropped connection from a broken chunk and a full buffer" {
    try std.testing.expectEqual(error.ConnectionDropped, bodyError(error.ReadFailed, null));
    const broken_chunk = bodyError(error.ReadFailed, error.HttpChunkInvalid);
    try std.testing.expectEqual(error.BadResponse, broken_chunk);
    try std.testing.expectEqual(error.ResponseTooLarge, bodyError(error.WriteFailed, null));
    const truncated_chunk = bodyError(error.ReadFailed, error.HttpChunkTruncated);
    try std.testing.expectEqual(error.ConnectionDropped, truncated_chunk);
}

test "request and head errors map to what the user can act on" {
    try std.testing.expectEqual(error.ConnectFailed, requestError(error.TlsInitializationFailed));
    try std.testing.expectEqual(error.OutOfMemory, requestError(error.OutOfMemory));
    try std.testing.expectEqual(error.Redirected, receiveHeadError(error.TooManyHttpRedirects));
    try std.testing.expectEqual(error.ConnectionDropped, receiveHeadError(error.ReadFailed));
    try std.testing.expectEqual(error.SendFailed, receiveHeadError(error.WriteFailed));
    try std.testing.expectEqual(error.BadResponse, receiveHeadError(error.HttpHeadersInvalid));
}

test "parse errors other than running out of memory mean unexpected JSON" {
    try std.testing.expectEqual(error.UnexpectedJson, parseError(error.MissingField));
    try std.testing.expectEqual(error.OutOfMemory, parseError(error.OutOfMemory));
}

test "bodyEndCheck catches a body short of its content length" {
    try bodyEndCheck(.ready);
    try bodyEndCheck(.body_none);
    const short = bodyEndCheck(.{ .body_remaining_content_length = 10 });
    try std.testing.expectError(error.ConnectionDropped, short);
}

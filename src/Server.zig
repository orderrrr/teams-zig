//! The MCP server behind `teams-zig mcp`: JSON-RPC 2.0 requests, one per line on `reader`, each
//! answered with one line on `writer`, as MCP's stdio transport has it.

const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const json = teams.chat.json;
const build_options = @import("build_options");
const commands = @import("commands.zig");

const Server = @This();

/// A request line must be shorter than its buffer (see `request_size_max`), which also holds
/// the newline.
reader: *Io.Reader,
writer: *Io.Writer,
/// Holds one request while it is answered, so nothing is allocated while serving; its size is
/// `request_memory_size_max` in `main`.
request_memory: []u8,
/// Holds one command's text and then its hint; its size is `output_size_max` in `main`.
output_buffer: []u8,
runner: Runner,

/// The size `main` gives the stdin reader's buffer: a request line and its newline.
pub const request_size_max = 256 * 1024;

/// What one request may use while it is parsed and answered. Requests are small objects; one
/// that needs more gets an error answer of its own.
pub const request_memory_size_max = 8 * request_size_max;

/// The size `main` gives `output_buffer`: the most text a tool call returns, and room for the
/// hint after it. Far more than an agent can use; `messages` with a large count can reach it.
pub const output_size_max = 1024 * 1024 + hint_size_max;

/// Room kept at the end of `output_buffer` for a failed command's hint.
const hint_size_max = 512;

/// The longest line skipped before the server gives up on its input.
const skipped_line_size_max = 64 * 1024 * 1024;

comptime {
    // A `send` of the most text can grow about six times with JSON escapes.
    std.debug.assert(request_size_max >= 6 * commands.send_text_size_max);
    std.debug.assert(request_memory_size_max >= request_size_max);
    std.debug.assert(output_size_max > hint_size_max);
    std.debug.assert(skipped_line_size_max > request_size_max);
    // Each tool runs the CLI command of its name.
    for (std.meta.fieldNames(Tool)) |name| std.debug.assert(@hasField(commands.Command, name));
}

pub const Error = Io.Writer.Error || error{ ReadFailed, RequestLineTooLong };

/// Runs the tools' commands: connecting, then `commands.Command.run`, in `main`; a fake in tests.
pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (
        context: *anyopaque,
        command: *const commands.Command,
        output: *Io.Writer,
    ) ?Failure,

    /// Writes the command's text to `output`; returns how it failed, or null.
    fn run(runner: Runner, command: *const commands.Command, output: *Io.Writer) ?Failure {
        // `watch` never ends, so no tool runs it.
        std.debug.assert(command.* != .watch);
        const failure = runner.run_fn(runner.context, command, output) orelse return null;
        if (failure.err == error.UnexpectedStatus) std.debug.assert(failure.status != null);
        return failure;
    }
};

/// How a command failed, for its hint (see `commands.writeErrorHint`).
pub const Failure = struct {
    err: commands.CommandError,
    /// The response's status, set whenever `err` is UnexpectedStatus.
    status: ?std.http.Status,
};

/// JSON-RPC's error codes, as MCP uses them.
const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

/// A request's id, echoed in its answer. MCP never uses null.
const Id = union(enum) {
    number: i64,
    string: []const u8,

    /// `value` as an id, if it is one of the kinds MCP allows. Borrows `value`.
    fn fromJson(value: *const std.json.Value) ?Id {
        return switch (value.*) {
            .integer => |number| .{ .number = number },
            .string => |string| .{ .string = string },
            else => null,
        };
    }

    pub fn jsonStringify(id: Id, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (id) {
            .number => |number| try writer.write(number),
            .string => |string| try writer.write(string),
        }
    }
};

/// A JSON-RPC request's envelope: `{"jsonrpc":"2.0","id":…,"method":…,"params":{…}}`.
const Request = struct {
    /// Null for a notification.
    id: ?Id,
    method: Method,
    /// Empty when the request has none.
    params: std.json.ObjectMap,

    /// The methods served; any other is answered -32601.
    const Method = enum { initialize, ping, @"tools/list", @"tools/call", other };

    /// Borrows `value`.
    fn parse(value: *const std.json.Value) error{InvalidRequest}!Request {
        // A batch (an array) is no longer part of JSON-RPC as MCP uses it.
        if (value.* != .object) return error.InvalidRequest;
        const object = &value.object;

        const version = objectString(object, "jsonrpc") orelse return error.InvalidRequest;
        // A guard clause: any version but 2.0 ends here (STYLE 5.4).
        if (!std.mem.eql(u8, version, "2.0")) return error.InvalidRequest;
        const method = objectString(object, "method") orelse return error.InvalidRequest;

        const id: ?Id = if (object.getPtr("id")) |id_value|
            Id.fromJson(id_value) orelse return error.InvalidRequest
        else
            null;

        return .{
            .id = id,
            .method = std.meta.stringToEnum(Method, method) orelse .other,
            .params = objectObject(object, "params") catch return error.InvalidRequest,
        };
    }

    /// The id of a request that `parse` refuses, if it can be read, for its error answer.
    fn readId(value: *const std.json.Value) ?Id {
        if (value.* != .object) return null;
        return Id.fromJson(value.object.getPtr("id") orelse return null);
    }
};

/// A `tools/call` result: the command's text, and whether it failed.
const CallResult = struct {
    text: []const u8,
    is_error: bool,

    /// MCP's shape: `{"content":[{"type":"text","text":…}],"isError":…}`.
    pub fn jsonStringify(
        result: CallResult,
        writer: *std.json.Stringify,
    ) std.json.Stringify.Error!void {
        try writer.beginObject();
        try writer.objectField("content");
        try writer.beginArray();
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write("text");
        try writer.objectField("text");
        try writer.write(result.text);
        try writer.endObject();
        try writer.endArray();
        try writer.objectField("isError");
        try writer.write(result.is_error);
        try writer.endObject();
    }
};

/// The tools, named as the CLI commands they run.
const Tool = enum {
    whoami,
    chats,
    messages,
    unread,
    send,

    /// The command that `arguments` ask for, with the CLI's checks, or null if they are wrong:
    /// a field the tool doesn't take, a field of the wrong type, or a value the CLI refuses.
    /// Borrows `arguments`.
    fn command(tool: Tool, arguments: *const std.json.ObjectMap) ?commands.Command {
        const fields_taken: []const []const u8 = switch (tool) {
            .whoami, .unread => &.{},
            .chats => &.{"count"},
            .messages => &.{ "chat", "count" },
            .send => &.{ "chat", "text" },
        };
        for (arguments.keys()) |key| {
            for (fields_taken) |taken| {
                if (std.mem.eql(u8, key, taken)) break;
            } else return null;
        }
        return switch (tool) {
            .whoami => .whoami,
            .unread => .unread,
            .chats => commands.Command.initChats(commandCount(arguments) catch return null),
            .messages => commands.Command.initMessages(
                objectString(arguments, "chat") orelse return null,
                commandCount(arguments) catch return null,
            ),
            .send => commands.Command.initSend(
                objectString(arguments, "chat") orelse return null,
                objectString(arguments, "text") orelse return null,
            ),
        };
    }

    /// The `count` argument: null if absent, or an error if it isn't a whole number that fits.
    fn commandCount(arguments: *const std.json.ObjectMap) error{WrongArgument}!?u32 {
        const count = arguments.get("count") orelse return null;
        if (count != .integer) return error.WrongArgument;
        return std.math.cast(u32, count.integer) orelse error.WrongArgument;
    }

    /// The arguments the tool takes, for the error that wrong ones get.
    fn usage(tool: Tool) []const u8 {
        return switch (tool) {
            .whoami, .unread => "no arguments",
            .chats => std.fmt.comptimePrint(
                "count (optional): 1 to {d}",
                .{commands.conversation_count_limit},
            ),
            .messages => std.fmt.comptimePrint(
                "chat: its exact name or id; count (optional): 1 to {d}",
                .{commands.message_count_limit},
            ),
            .send => "chat: its exact name or id; text: Markdown, not only whitespace",
        };
    }
};

/// The protocol versions served, newest first. The server uses nothing that differs between
/// them, and neither has JSON-RPC batches.
const protocol_versions = [_][]const u8{ "2025-11-25", "2025-06-18" };

/// Field names are MCP's.
const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: struct { tools: Empty = .{} } = .{},
    serverInfo: struct {
        name: []const u8 = "teams-zig",
        version: []const u8 = build_options.version,
    } = .{},
};

/// An empty JSON object. (An empty `.{}` is a tuple, which std.json writes as `[]`.)
const Empty = struct {};

/// JSON written as it is, for answers fixed at comptime.
const RawJson = struct {
    text: []const u8,

    pub fn jsonStringify(raw: RawJson, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll(raw.text);
        writer.endWriteRaw();
    }
};

/// The `tools/list` result: each tool takes the CLI command's arguments, with its limits. Field
/// names are MCP's (schema 2025-11-25).
const tools_list = std.fmt.comptimePrint(
    \\{{"tools":[
++
    \\{{"name":"whoami","description":"Show the signed-in user.",
++ schema_none ++
    \\"annotations":{{"readOnlyHint":true}}}},
++
    \\{{"name":"chats","description":"List your newest chats, one per line: a * if unread,
++
    \\ the last message's time, the kind, the name and the id.",
++
    \\"inputSchema":{{"type":"object","properties":{{
++
    \\"count":{{"type":"integer","minimum":1,"maximum":{[chats_max]d},
++
    \\"description":"How many chats (default {[chats_default]d})."}}
++
    \\}},"additionalProperties":false}},
++
    \\"annotations":{{"readOnlyHint":true}}}},
++
    \\{{"name":"messages","description":"Show a chat's messages, oldest first,
++
    \\ each as its time, sender and text in Markdown.",
++
    \\"inputSchema":{{"type":"object","properties":{{"chat":{[chat_schema]s},
++
    \\"count":{{"type":"integer","minimum":1,"maximum":{[messages_max]d},
++
    \\"description":"How many of the newest messages (default {[messages_default]d})."}}
++
    \\}},"required":["chat"],"additionalProperties":false}},
++
    \\"annotations":{{"readOnlyHint":true}}}},
++
    \\{{"name":"unread","description":"Show what's new since you last read,
++
    \\ in up to {[unread_max]d} of your {[chats_default]d} newest chats.",
++ schema_none ++
    \\"annotations":{{"readOnlyHint":true}}}},
++
    \\{{"name":"send","description":"Send one message, written in Markdown, to a chat.
++
    \\ Never retried: after a failure, check the chat before sending again.",
++
    \\"inputSchema":{{"type":"object","properties":{{"chat":{[chat_schema]s},
++
    \\"text":{{"type":"string","minLength":1,"maxLength":{[send_text_size_max]d},
++
    \\"description":"The message in Markdown, at most {[send_text_kib_max]d} KiB."}}
++
    \\}},"required":["chat","text"],"additionalProperties":false}},
++
    \\"annotations":{{"readOnlyHint":false,"destructiveHint":false,
++
    \\"idempotentHint":false,"openWorldHint":true}}}}
++
    \\]}}
, .{
    .chats_max = commands.conversation_count_limit,
    .chats_default = commands.conversation_count_default,
    .messages_max = commands.message_count_limit,
    .messages_default = commands.message_count_default,
    .unread_max = commands.unread_read_count_limit,
    .send_text_size_max = commands.send_text_size_max,
    .send_text_kib_max = @divExact(commands.send_text_size_max, 1024),
    .chat_schema =
    \\{"type":"string","minLength":1,
    ++
        \\"description":"The chat's exact name as chats shows it, or its id."}
    ,
});

/// The input schema of a tool that takes no arguments, in `tools_list`'s format string.
const schema_none =
    \\"inputSchema":{{"type":"object","properties":{{}},"additionalProperties":false}},
;

/// Answers every request until `reader` ends.
pub fn serve(server: *Server) Error!void {
    std.debug.assert(server.output_buffer.len > hint_size_max);
    std.debug.assert(server.request_memory.len > 0);
    // The server's event loop: it runs once per request line, for as long as the client keeps
    // stdin open, so it has no bound of its own. It ends when the reader ends or fails.
    while (true) {
        const line = server.reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => {
                try server.serveLongLine();
                continue;
            },
        } orelse return;
        var request_allocator: std.heap.FixedBufferAllocator = .init(server.request_memory);
        try server.answer(request_allocator.allocator(), line);
    }
}

/// Drops the rest of a line too long for the reader's buffer, and answers it as unreadable. A
/// line past `skipped_line_size_max` ends the server: its input is not MCP.
fn serveLongLine(server: *Server) Error!void {
    // One more than the longest line skipped, since the limit counts up to the newline too.
    _ = server.reader.discardDelimiterLimit('\n', .limited(skipped_line_size_max + 1)) catch |err| {
        return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.StreamTooLong => error.RequestLineTooLong,
        };
    };
    // The newline, unless the input ended first; the last line still gets its answer.
    if (server.reader.bufferedLen() > 0) {
        std.debug.assert(server.reader.buffered()[0] == '\n');
        server.reader.toss(1);
    }
    try server.answerError(null, .parse_error, "Parse error: the request line is too long");
}

/// Every option spelled out, for requests. Numbers are parsed, so a count or id is an integer
/// only when written as one.
const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = true,
    .max_value_len = null,
    .allocate = .alloc_always,
    .parse_numbers = true,
};

/// Answers one request line. `arena` holds what parsing it needs; running out of it fails only
/// this request.
fn answer(server: *Server, arena: std.mem.Allocator, line: []const u8) Error!void {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        line,
        parse_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return server.answerOutOfMemory(null),
        else => return server.answerError(null, .parse_error, "Parse error"),
    };
    const request = Request.parse(&value) catch |err| switch (err) {
        error.InvalidRequest => {
            const id: ?Id = Request.readId(&value);
            const known_id: ?*const Id = if (id) |*known| known else null;
            return server.answerError(known_id, .invalid_request, "Invalid Request");
        },
    };
    // Notifications get no answer, and run nothing.
    const id = request.id orelse return;
    switch (request.method) {
        .initialize => return server.answerResult(&id, answerInitialize(&request.params)),
        .ping => return server.answerResult(&id, Empty{}),
        .@"tools/list" => return server.answerResult(&id, RawJson{ .text = tools_list }),
        .@"tools/call" => return server.answerCall(arena, &id, &request.params),
        .other => return server.answerError(&id, .method_not_found, "Method not found"),
    }
}

/// What `initialize` answers: the client's protocol version if it is served, else the newest
/// (the client then decides whether to go on), and the tools capability.
fn answerInitialize(params: *const std.json.ObjectMap) InitializeResult {
    const version: []const u8 = version: {
        if (objectString(params, "protocolVersion")) |asked| {
            for (protocol_versions) |served| {
                if (std.mem.eql(u8, asked, served)) break :version served;
            }
        }
        break :version protocol_versions[0];
    };
    return .{ .protocolVersion = version };
}

/// Answers a `tools/call`: a call whose name or arguments object is missing or wrong is a
/// protocol error; arguments the tool refuses are a tool error, so the agent can correct them.
fn answerCall(
    server: *Server,
    arena: std.mem.Allocator,
    id: *const Id,
    params: *const std.json.ObjectMap,
) Error!void {
    const name = objectString(params, "name") orelse {
        return server.answerError(id, .invalid_params, "Invalid params: tools/call needs a name");
    };
    const tool = std.meta.stringToEnum(Tool, name) orelse {
        const message = std.fmt.allocPrint(arena, "Unknown tool: {s}", .{name}) catch {
            return server.answerOutOfMemory(id);
        };
        return server.answerError(id, .invalid_params, message);
    };
    const arguments = objectObject(params, "arguments") catch {
        const message = "Invalid params: a tool's arguments are an object";
        return server.answerError(id, .invalid_params, message);
    };

    const command = tool.command(&arguments) orelse {
        const message = std.fmt.allocPrint(
            arena,
            "bad arguments for {t}; it takes {s}",
            .{ tool, tool.usage() },
        ) catch return server.answerOutOfMemory(id);
        return server.answerResult(id, CallResult{ .text = message, .is_error = true });
    };
    return server.answerResult(id, server.answerCallRun(&command));
}

/// Runs `command`, and gives its text as the result, or on failure its text and then its hint.
/// The result borrows `output_buffer`.
fn answerCallRun(server: *Server, command: *const commands.Command) CallResult {
    const output_text_size_max = server.output_buffer.len - hint_size_max;
    var output: Io.Writer = .fixed(server.output_buffer[0..output_text_size_max]);
    const failure = server.runner.run(command, &output) orelse {
        return .{ .text = output.buffered(), .is_error = false };
    };

    // Every hint fits in `hint_size_max`, so the writers below never fill.
    // Only `output` fails with WriteFailed, and a fixed writer fails only when it is full.
    if (failure.err == error.WriteFailed) {
        var too_large: Io.Writer = .fixed(server.output_buffer[0..hint_size_max]);
        too_large.print(
            "the output is larger than teams-zig returns ({d} bytes); ask for fewer",
            .{output_text_size_max},
        ) catch unreachable;
        return .{ .text = too_large.buffered(), .is_error = true };
    }
    const text_size = output.buffered().len;
    var hint: Io.Writer = .fixed(server.output_buffer[text_size..]);
    commands.writeErrorHint(&hint, failure.err, failure.status) catch unreachable;
    const text = server.output_buffer[0 .. text_size + hint.buffered().len];
    return .{ .text = text, .is_error = true };
}

/// The string field `name` of `object`, or null if it is absent or not a string. Borrows
/// `object`.
fn objectString(object: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// The object field `name` of `object`, empty if it is absent, or an error if it is not an
/// object. Borrows `object`.
fn objectObject(
    object: *const std.json.ObjectMap,
    name: []const u8,
) error{NotAnObject}!std.json.ObjectMap {
    const value = object.get(name) orelse return .empty;
    if (value != .object) return error.NotAnObject;
    return value.object;
}

/// Writes a JSON-RPC answer carrying `result` as one line.
fn answerResult(server: *Server, id: *const Id, result: anytype) Error!void {
    const answer_value: struct {
        jsonrpc: []const u8 = "2.0",
        id: Id,
        result: @TypeOf(result),
    } = .{ .id = id.*, .result = result };
    try server.writeLine(&answer_value);
}

/// Writes a JSON-RPC error answer as one line. `id` is null when the request's id can't be read.
fn answerError(server: *Server, id: ?*const Id, code: ErrorCode, message: []const u8) Error!void {
    const Answer = struct {
        jsonrpc: []const u8 = "2.0",
        id: ?Id,
        @"error": struct { code: i32, message: []const u8 },
    };
    const error_answer: Answer = .{
        .id = if (id) |known| known.* else null,
        .@"error" = .{ .code = @backingInt(code), .message = message },
    };
    try server.writeLine(&error_answer);
}

/// Answers a request that needs more than `request_memory`.
fn answerOutOfMemory(server: *Server, id: ?*const Id) Error!void {
    const message = "Internal error: the request needs more memory than teams-zig keeps";
    try server.answerError(id, .internal_error, message);
}

/// Writes `value` as one line of JSON, and sends it.
fn writeLine(server: *Server, value: anytype) Error!void {
    // Minified JSON escapes every newline inside strings, so the answer stays on one line.
    try std.json.Stringify.value(value.*, json.stringify_options, server.writer);
    try server.writer.writeByte('\n');
    try server.writer.flush();
}

/// Reads `source` through a buffer smaller than it, as stdin is read. (std.testing.ReaderIndirect
/// hangs once a line fills its buffer.)
const SliceReader = struct {
    source: []const u8,
    interface: Io.Reader,

    fn stream(
        reader: *Io.Reader,
        writer: *Io.Writer,
        limit: Io.Limit,
    ) Io.Reader.StreamError!usize {
        const slice_reader: *SliceReader = @alignCast(@fieldParentPtr("interface", reader));
        if (slice_reader.source.len == 0) return error.EndOfStream;
        const size = limit.minInt(slice_reader.source.len);
        const written = try writer.write(slice_reader.source[0..size]);
        slice_reader.source = slice_reader.source[written..];
        return written;
    }
};

/// Writes `output` for every command, then fails with `failure` if it is set.
const FakeRunner = struct {
    output: []const u8,
    failure: ?Failure,
    runs_allowed: bool,

    fn interface(fake: *FakeRunner) Runner {
        return .{ .context = fake, .run_fn = run };
    }

    fn run(context: *anyopaque, command: *const commands.Command, output: *Io.Writer) ?Failure {
        const fake: *FakeRunner = @ptrCast(@alignCast(context));
        std.debug.assert(fake.runs_allowed);
        std.debug.assert(command.* != .watch);
        output.writeAll(fake.output) catch |err| return .{ .err = err, .status = null };
        return fake.failure;
    }
};

/// Memory for one test request, far less than `request_memory_size_max` but enough for any
/// request the tests send.
const test_request_memory_size = 64 * 1024;

/// Runs a server over `reader` with `runner` for its commands, and checks its answers. The
/// output buffer has `output_size` bytes for text, plus room for a hint.
fn expectServed(
    reader: *Io.Reader,
    runner: *FakeRunner,
    output_size: u32,
    expected: []const u8,
) !void {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const request_memory = try std.testing.allocator.alloc(u8, test_request_memory_size);
    defer std.testing.allocator.free(request_memory);
    const output_buffer = try std.testing.allocator.alloc(u8, output_size + hint_size_max);
    defer std.testing.allocator.free(output_buffer);

    var server: Server = .{
        .reader = reader,
        .writer = &out.writer,
        .request_memory = request_memory,
        .output_buffer = output_buffer,
        .runner = runner.interface(),
    };
    // The answers are checked even when `serve` fails, then its error is passed on.
    const served = server.serve();
    try std.testing.expectEqualStrings(expected, out.written());
    return served;
}

/// Runs a server over `input` and checks that its answers are `expected`. No command runs.
fn expectAnswers(input: []const u8, expected: []const u8) !void {
    var runner: FakeRunner = .{ .output = "", .failure = null, .runs_allowed = false };
    try expectAnswersWith(&runner, 64, input, expected);
}

/// Runs a server over `input`, with `runner` for its commands, and checks its answers.
fn expectAnswersWith(
    runner: *FakeRunner,
    output_size: u32,
    input: []const u8,
    expected: []const u8,
) !void {
    var reader: Io.Reader = .fixed(input);
    try expectServed(&reader, runner, output_size, expected);
}

test "an unknown method is answered with its id and -32601" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":7,"method":"fake/method"}
        \\{"jsonrpc":"2.0","id":"fake-id","method":"fake/method","params":{}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":"fake-id","error":{"code":-32601,"message":"Method not found"}}
        \\
    );
}

test "a notification gets no answer" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","method":"notifications/fake"}
        \\
    , "");
}

test "a tools/call without an id runs nothing and gets no answer" {
    // The fake runner asserts if a command runs: a send here would post with no answer.
    try expectAnswers(
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"send",
    ++
        \\"arguments":{"chat":"48:notes","text":"fake"}}}
        \\
    , "");
}

test "a line that isn't JSON gets -32700 with a null id" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":1,
        \\
    ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
        \\
    );
}

test "a batch, a missing method or a wrong envelope gets -32600" {
    try expectAnswers(
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"}]
        \\{"jsonrpc":"2.0","id":2}
        \\{"jsonrpc":"1.0","id":3,"method":"ping"}
        \\{"jsonrpc":"2.0","id":4,"method":5}
        \\{"jsonrpc":"2.0","id":5,"method":"ping","params":[]}
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
        \\
    ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":5,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
        \\
    );
}

test "a line longer than the reader's buffer gets -32700 and is skipped to its newline" {
    const long_line: [100]u8 = @splat('x');
    var buffer: [64]u8 = undefined;
    var reader: SliceReader = .{
        .source = long_line ++ "\n" ++
            \\{"jsonrpc":"2.0","id":1,"method":"fake"}
            \\
        ++ long_line,
        .interface = .{
            .vtable = &.{ .stream = SliceReader.stream },
            .buffer = &buffer,
            .seek = 0,
            .end = 0,
        },
    };
    var runner: FakeRunner = .{ .output = "", .failure = null, .runs_allowed = false };
    const too_long =
        \\{"jsonrpc":"2.0","id":null,
    ++
        \\"error":{"code":-32700,"message":"Parse error: the request line is too long"}}
        \\
    ;
    try expectServed(&reader.interface, &runner, 64, too_long ++
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        \\
    ++ too_long);
}

test "a request that needs more than the request memory gets -32603" {
    const item_count = test_request_memory_size / 2;
    var items: [item_count * 2]u8 = undefined;
    for (0..item_count) |index| {
        items[index * 2] = '1';
        items[index * 2 + 1] = ',';
    }
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"fake\":[" ++
        items[0 .. items.len - 1] ++ "]}}\n";
    try expectAnswers(input,
        \\{"jsonrpc":"2.0","id":null,
    ++
        \\"error":{"code":-32603,
    ++
        \\"message":"Internal error: the request needs more memory than teams-zig keeps"}}
        \\
    );
}

test "initialize answers with the client's version when known, and the newest otherwise" {
    const client = "\"capabilities\":{},\"clientInfo\":{\"name\":\"fake\",\"version\":\"1\"}";
    const server_info =
        \\"capabilities":{"tools":{}},"serverInfo":{"name":"teams-zig","version":"
    ++ build_options.version ++
        \\"}}}
    ;
    const initialize = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",";
    try expectAnswers(
        initialize ++ "\"id\":1,\"params\":{\"protocolVersion\":\"2025-06-18\"," ++
            client ++ "}}\n" ++
            initialize ++ "\"id\":2,\"params\":{\"protocolVersion\":\"2025-11-25\"," ++
            client ++ "}}\n" ++
            initialize ++ "\"id\":3,\"params\":{\"protocolVersion\":\"2024-11-05\"," ++
            client ++ "}}\n" ++
            initialize ++ "\"id\":4}\n",
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",
        ++ server_info ++ "\n" ++
            \\{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25",
        ++ server_info ++ "\n" ++
            \\{"jsonrpc":"2.0","id":3,"result":{"protocolVersion":"2025-11-25",
        ++ server_info ++ "\n" ++
            \\{"jsonrpc":"2.0","id":4,"result":{"protocolVersion":"2025-11-25",
        ++ server_info ++ "\n",
    );
}

test "ping gets an empty result, and notifications/initialized no answer" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":"fake-ping","method":"ping"}
        \\
    ,
        \\{"jsonrpc":"2.0","id":"fake-ping","result":{}}
        \\
    );
}

/// `tools/list`'s expected result, written out by hand.
const tools_list_expected =
    \\{"tools":[
++
    \\{"name":"whoami","description":"Show the signed-in user.",
++
    \\"inputSchema":{"type":"object","properties":{},"additionalProperties":false},
++
    \\"annotations":{"readOnlyHint":true}},
++
    \\{"name":"chats","description":"List your newest chats, one per line: a * if unread,
++
    \\ the last message's time, the kind, the name and the id.",
++
    \\"inputSchema":{"type":"object","properties":{"count":{"type":"integer","minimum":1,
++
    \\"maximum":100,"description":"How many chats (default 50)."}},
++
    \\"additionalProperties":false},"annotations":{"readOnlyHint":true}},
++
    \\{"name":"messages","description":"Show a chat's messages, oldest first,
++
    \\ each as its time, sender and text in Markdown.",
++
    \\"inputSchema":{"type":"object","properties":{"chat":{"type":"string","minLength":1,
++
    \\"description":"The chat's exact name as chats shows it, or its id."},
++
    \\"count":{"type":"integer","minimum":1,"maximum":12800,
++
    \\"description":"How many of the newest messages (default 50)."}},
++
    \\"required":["chat"],"additionalProperties":false},"annotations":{"readOnlyHint":true}},
++
    \\{"name":"unread","description":"Show what's new since you last read,
++
    \\ in up to 10 of your 50 newest chats.",
++
    \\"inputSchema":{"type":"object","properties":{},"additionalProperties":false},
++
    \\"annotations":{"readOnlyHint":true}},
++
    \\{"name":"send","description":"Send one message, written in Markdown, to a chat.
++
    \\ Never retried: after a failure, check the chat before sending again.",
++
    \\"inputSchema":{"type":"object","properties":{"chat":{"type":"string","minLength":1,
++
    \\"description":"The chat's exact name as chats shows it, or its id."},
++
    \\"text":{"type":"string","minLength":1,"maxLength":16384,
++
    \\"description":"The message in Markdown, at most 16 KiB."}},
++
    \\"required":["chat","text"],"additionalProperties":false},
++
    \\"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,
++
    \\"openWorldHint":true}}
++
    \\]}
;

test "tools/list lists the five tools with their arguments and hints" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
        \\
    , "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" ++ tools_list_expected ++ "}\n");
}

test "one session: initialize, then tools/list, then the end of input" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ,
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25",
    ++
        \\"capabilities":{"tools":{}},"serverInfo":{"name":"teams-zig","version":"
    ++ build_options.version ++ "\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++ tools_list_expected ++ "}\n");
}

/// Parses `arguments_json` as a tool call's arguments for `tool`, and gives the command it asks
/// for, with its borrowed strings dropped, since they go with the parse.
fn parseToolCommand(tool: Tool, arguments_json: []const u8) !?commands.Command {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        arguments_json,
        parse_options,
    );
    const command = tool.command(&value.object) orelse return null;
    return switch (command) {
        .whoami, .unread, .chats, .watch => command,
        .messages => |messages| .{
            .messages = .{ .chat = .{ .id = "" }, .count = messages.count },
        },
        .send => .{ .send = .{ .chat = .{ .id = "" }, .text = "" } },
    };
}

test "Tool.command takes each tool's arguments with the CLI's limits" {
    try std.testing.expectEqual(.whoami, (try parseToolCommand(.whoami, "{}")).?);
    try std.testing.expectEqual(.unread, (try parseToolCommand(.unread, "{}")).?);
    try std.testing.expectEqual(50, (try parseToolCommand(.chats, "{}")).?.chats);
    const chats_max = try parseToolCommand(.chats,
        \\{"count":100}
    );
    try std.testing.expectEqual(100, chats_max.?.chats);
    const messages_max = try parseToolCommand(.messages,
        \\{"chat":"48:notes","count":12800}
    );
    try std.testing.expectEqual(12800, messages_max.?.messages.count);
    const messages_default = try parseToolCommand(.messages,
        \\{"chat":"Fake Person"}
    );
    try std.testing.expectEqual(50, messages_default.?.messages.count);
    const send = try parseToolCommand(.send,
        \\{"chat":"48:notes","text":"**fake**"}
    );
    try std.testing.expect(send != null);
}

test "Tool.command refuses unknown fields, wrong types and values the CLI refuses" {
    const refused = [_]struct { Tool, []const u8 }{
        .{ .whoami, "{\"count\":1}" },
        .{ .unread, "{\"fake\":true}" },
        .{ .chats, "{\"count\":0}" },
        .{ .chats, "{\"count\":101}" },
        .{ .chats, "{\"count\":\"10\"}" },
        .{ .chats, "{\"count\":10.5}" },
        .{ .chats, "{\"count\":-1}" },
        .{ .chats, "{\"count\":10,\"fake\":1}" },
        .{ .messages, "{}" },
        .{ .messages, "{\"chat\":\"\"}" },
        .{ .messages, "{\"chat\":5}" },
        .{ .messages, "{\"chat\":\"48:notes\",\"count\":12801}" },
        .{ .send, "{\"chat\":\"48:notes\"}" },
        .{ .send, "{\"chat\":\"48:notes\",\"text\":\" \\n\"}" },
        .{ .send, "{\"text\":\"fake\"}" },
        .{ .send, "{\"chat\":\"48:notes\",\"text\":\"fake\",\"fake\":1}" },
    };
    for (refused) |case| {
        const tool, const arguments = case;
        try std.testing.expectEqual(null, try parseToolCommand(tool, arguments));
    }
}

test "tools/call answers bad arguments with isError and the usage, a bad call with -32602" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call",
    ++
        \\"params":{"name":"chats","arguments":{"count":0}}}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fake"}}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chats","arguments":[]}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text",
    ++
        \\"text":"bad arguments for chats; it takes count (optional): 1 to 100"}],"isError":true}}
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Unknown tool: fake"}}
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32602,
    ++
        \\"message":"Invalid params: tools/call needs a name"}}
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32602,
    ++
        \\"message":"Invalid params: a tool's arguments are an object"}}
        \\
    );
}

test "tools/call answers with the command's text" {
    var runner: FakeRunner = .{
        .output = "Fake Person <fake@example.com>\n",
        .failure = null,
        .runs_allowed = true,
    };
    try expectAnswersWith(&runner, 64,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami"}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text",
    ++
        \\"text":"Fake Person <fake@example.com>\n"}],"isError":false}}
        \\
    );
}

test "tools/call answers a failure with the text so far and the hint" {
    var runner: FakeRunner = .{
        .output = "  10:00  chat  Fake  19:fake@thread.v2\n",
        .failure = .{ .err = error.ChatNameAmbiguous, .status = null },
        .runs_allowed = true,
    };
    try expectAnswersWith(&runner, 64,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call",
    ++
        \\"params":{"name":"messages","arguments":{"chat":"Fake"}}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text",
    ++
        \\"text":"  10:00  chat  Fake  19:fake@thread.v2\n
    ++
        \\several chats have that name; use one of the ids above"}],"isError":true}}
        \\
    );

    runner = .{
        .output = "",
        .failure = .{ .err = error.UnexpectedStatus, .status = .forbidden },
        .runs_allowed = true,
    };
    try expectAnswersWith(&runner, 64,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"unread"}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text",
    ++
        \\"text":"the Chat Service answered HTTP 403"}],"isError":true}}
        \\
    );
}

test "tools/call refuses output larger than the output buffer" {
    var runner: FakeRunner = .{
        .output = "more than eight bytes",
        .failure = null,
        .runs_allowed = true,
    };
    try expectAnswersWith(&runner, 8,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chats"}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text",
    ++
        \\"text":"the output is larger than teams-zig returns (8 bytes); ask for fewer"}],
    ++
        \\"isError":true}}
        \\
    );
}

test "every command error's hint fits in the room kept for it" {
    var buffer: [hint_size_max]u8 = undefined;
    inline for (@typeInfo(commands.CommandError).error_set.error_names.?) |name| {
        var hint: Io.Writer = .fixed(&buffer);
        const err = @field(anyerror, name);
        try commands.writeErrorHint(&hint, @errorCast(err), .forbidden);
        try std.testing.expect(hint.buffered().len > 0);
    }
}

test "a line of the skip limit is skipped, and a longer one stops the server with no answer" {
    // Two runs over the same bytes: first a line of the limit and its newline, then, with the
    // newline made an `x`, a line one byte longer.
    const source = try std.testing.allocator.alloc(u8, skipped_line_size_max + 1);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    source[skipped_line_size_max] = '\n';

    var buffer: [64]u8 = undefined;
    var reader: SliceReader = .{
        .source = source,
        .interface = .{
            .vtable = &.{ .stream = SliceReader.stream },
            .buffer = &buffer,
            .seek = 0,
            .end = 0,
        },
    };
    var runner: FakeRunner = .{ .output = "", .failure = null, .runs_allowed = false };
    try expectServed(&reader.interface, &runner, 64,
        \\{"jsonrpc":"2.0","id":null,
    ++
        \\"error":{"code":-32700,"message":"Parse error: the request line is too long"}}
        \\
    );

    // Reset the reader: the first run used up `source` and moved the buffer's `seek` and `end`.
    source[skipped_line_size_max] = 'x';
    reader.source = source;
    reader.interface.seek = 0;
    reader.interface.end = 0;
    const result = expectServed(&reader.interface, &runner, 64, "");
    try std.testing.expectError(error.RequestLineTooLong, result);
}

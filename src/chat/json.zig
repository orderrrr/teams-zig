//! JSON settings shared by every Chat Service response.

const std = @import("std");

pub const ParseError = std.json.ParseError(std.json.Scanner);

/// Every option spelled out. Responses carry many fields we don't read, and parsed strings must
/// outlive the response body, so they're always copied. `max_value_len` null means the input
/// length, std's default for a slice: any body the client accepts parses.
pub const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = true,
    .max_value_len = null,
    .allocate = .alloc_always,
};

/// Every option spelled out, for request bodies: compact, with strings as text.
pub const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .minified,
    .emit_null_optional_fields = true,
    .emit_strings_as_arrays = false,
    .escape_unicode = false,
    .emit_nonportable_numbers_as_strings = false,
};

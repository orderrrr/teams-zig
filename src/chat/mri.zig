//! MRIs, the ids the Chat Service gives people: `8:orgid:<uuid>` for a user in an organisation.

const std = @import("std");

/// The MRI at the end of a contact URL: `https://.../contacts/8:orgid:<uuid>`. A value with no
/// slash is returned whole.
pub fn fromContactUrl(contact_url: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, contact_url, '/')) |slash| slash + 1 else 0;
    return contact_url[start..];
}

test "fromContactUrl takes the MRI off the end of a contact URL" {
    const url = "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/contacts/8:orgid:fake-uuid";
    try std.testing.expectEqualStrings("8:orgid:fake-uuid", fromContactUrl(url));
}

test "fromContactUrl returns the whole value when there is no slash" {
    try std.testing.expectEqualStrings("8:orgid:fake-uuid", fromContactUrl("8:orgid:fake-uuid"));
}

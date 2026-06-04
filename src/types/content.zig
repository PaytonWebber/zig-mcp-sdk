const core = @import("core.zig");
const json_utils = @import("json_utils.zig");
const Annotations = core.Annotations;

pub const TextContent = struct {
    text: []const u8,
    annotations: ?Annotations = null,

    pub fn jsonStringify(self: TextContent, jw: anytype) !void {
        try json_utils.stringifyWithTypeTag("text", self, jw);
    }
};

pub const ImageContent = struct {
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,

    pub fn jsonStringify(self: ImageContent, jw: anytype) !void {
        try json_utils.stringifyWithTypeTag("image", self, jw);
    }
};

pub const AudioContent = struct {
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,

    pub fn jsonStringify(self: AudioContent, jw: anytype) !void {
        try json_utils.stringifyWithTypeTag("audio", self, jw);
    }
};

pub const TextResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: []const u8,
};

pub const BlobResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    blob: []const u8,
};

pub const ResourceContents = union(enum) {
    text: TextResourceContents,
    blob: BlobResourceContents,

    pub fn jsonStringify(self: ResourceContents, jw: anytype) !void {
        switch (self) {
            inline else => |c| try jw.write(c),
        }
    }
};

pub const EmbeddedResource = struct {
    resource: ResourceContents,
    annotations: ?Annotations = null,

    pub fn jsonStringify(self: EmbeddedResource, jw: anytype) !void {
        try json_utils.stringifyWithTypeTag("resource", self, jw);
    }
};

/// A link to a resource the client can read separately (a tool may return these
/// instead of embedding the content). Serialized with type tag `resource_link`.
pub const ResourceLink = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,

    pub fn jsonStringify(self: ResourceLink, jw: anytype) !void {
        try json_utils.stringifyWithTypeTag("resource_link", self, jw);
    }
};

pub const Content = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    resource: EmbeddedResource,
    resource_link: ResourceLink,

    /// Convenience constructor for a text content item.
    pub fn textContent(t: []const u8) Content {
        return .{ .text = .{ .text = t } };
    }

    /// Convenience constructor for an image content item (base64 `data`).
    pub fn imageContent(data: []const u8, mime_type: []const u8) Content {
        return .{ .image = .{ .data = data, .mimeType = mime_type } };
    }

    /// Convenience constructor for an audio content item (base64 `data`).
    pub fn audioContent(data: []const u8, mime_type: []const u8) Content {
        return .{ .audio = .{ .data = data, .mimeType = mime_type } };
    }

    /// Deprecated: use `textContent`. Kept for backward compatibility.
    pub fn text_content(t: []const u8) Content {
        return textContent(t);
    }

    pub fn jsonStringify(self: Content, jw: anytype) !void {
        switch (self) {
            inline else => |c| try c.jsonStringify(jw),
        }
    }
};

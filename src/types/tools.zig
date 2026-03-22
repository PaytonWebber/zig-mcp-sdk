const std = @import("std");
const json = std.json;
const content = @import("content.zig");
const Content = content.Content;
const json_utils = @import("json_utils.zig");

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    readOnlyHint: ?bool = null,
    destructiveHint: ?bool = null,
    idempotentHint: ?bool = null,
    openWorldHint: ?bool = null,
};

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    /// Raw JSON string for the input schema. Defaults to `{"type":"object"}`.
    inputSchema: ?[]const u8 = null,
    annotations: ?ToolAnnotations = null,

    pub fn jsonStringify(self: Tool, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |d| {
            try jw.objectField("description");
            try jw.write(d);
        }
        try jw.objectField("inputSchema");
        // Write raw JSON for the schema
        try jw.beginWriteRaw();
        try jw.writer.writeAll(self.inputSchema orelse
            \\{"type":"object"}
        );
        jw.endWriteRaw();
        if (self.annotations) |a| {
            try jw.objectField("annotations");
            try jw.write(a);
        }
        try jw.endObject();
    }
};

pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,
};

pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?json.Value = null,

    pub fn fromJson(val: json.Value) error{InvalidParams}!CallToolParams {
        return json_utils.parseFromJsonObject(CallToolParams, val);
    }
};

pub const CallToolResult = struct {
    content: []const Content,
    isError: ?bool = null,
};

const std = @import("std");
const json = std.json;
const content = @import("content.zig");
const ResourceContents = content.ResourceContents;
const json_utils = @import("json_utils.zig");

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,
};

pub const ListResourceTemplatesResult = struct {
    resourceTemplates: []const ResourceTemplate,
    nextCursor: ?[]const u8 = null,
};

pub const ReadResourceParams = struct {
    uri: []const u8,

    pub fn fromJson(val: json.Value) error{InvalidParams}!ReadResourceParams {
        return json_utils.parseFromJsonObject(ReadResourceParams, val);
    }
};

pub const ReadResourceResult = struct {
    contents: []const ResourceContents,
};

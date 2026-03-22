const std = @import("std");
const json = std.json;
const core = @import("core.zig");
const Role = core.Role;
const content = @import("content.zig");
const Content = content.Content;
const json_utils = @import("json_utils.zig");

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,
};

pub const GetPromptParams = struct {
    name: []const u8,
    arguments: ?json.Value = null,

    pub fn fromJson(val: json.Value) error{InvalidParams}!GetPromptParams {
        return json_utils.parseFromJsonObject(GetPromptParams, val);
    }
};

pub const PromptMessage = struct {
    role: Role,
    content: Content,
};

pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
};

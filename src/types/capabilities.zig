const std = @import("std");
const json = std.json;

pub const ToolsCapability = struct {
    listChanged: ?bool = null,
};

pub const ResourcesCapability = struct {
    listChanged: ?bool = null,
    subscribe: ?bool = null,
};

pub const PromptsCapability = struct {
    listChanged: ?bool = null,
};

pub const LoggingCapability = struct {};
pub const CompletionsCapability = struct {};

pub const ServerCapabilities = struct {
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
    prompts: ?PromptsCapability = null,
    logging: ?LoggingCapability = null,
    completions: ?CompletionsCapability = null,
    experimental: ?json.Value = null,
};

pub const RootsCapability = struct {
    listChanged: ?bool = null,
};

pub const SamplingCapability = struct {};

pub const ClientCapabilities = struct {
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
    experimental: ?json.Value = null,
};

//! MCP protocol types — re-exports from domain-specific modules.
//!
//! Each domain lives in its own file under `types/` for single-responsibility
//! separation. This module provides a flat namespace so consumers can write
//! `types.Tool`, `types.Content`, etc.

// Core
const core = @import("types/core.zig");
pub const protocol_version = core.protocol_version;
pub const supported_protocol_versions = core.supported_protocol_versions;
pub const Implementation = core.Implementation;
pub const Role = core.Role;
pub const Annotations = core.Annotations;

// Capabilities
const caps = @import("types/capabilities.zig");
pub const ToolsCapability = caps.ToolsCapability;
pub const ResourcesCapability = caps.ResourcesCapability;
pub const PromptsCapability = caps.PromptsCapability;
pub const LoggingCapability = caps.LoggingCapability;
pub const CompletionsCapability = caps.CompletionsCapability;
pub const ServerCapabilities = caps.ServerCapabilities;
pub const RootsCapability = caps.RootsCapability;
pub const SamplingCapability = caps.SamplingCapability;
pub const ClientCapabilities = caps.ClientCapabilities;

// Content
const content_mod = @import("types/content.zig");
pub const TextContent = content_mod.TextContent;
pub const ImageContent = content_mod.ImageContent;
pub const AudioContent = content_mod.AudioContent;
pub const TextResourceContents = content_mod.TextResourceContents;
pub const BlobResourceContents = content_mod.BlobResourceContents;
pub const EmbeddedResource = content_mod.EmbeddedResource;
pub const ResourceLink = content_mod.ResourceLink;
pub const ResourceContents = content_mod.ResourceContents;
pub const Content = content_mod.Content;

// Tools
const tools_mod = @import("types/tools.zig");
pub const ToolAnnotations = tools_mod.ToolAnnotations;
pub const Tool = tools_mod.Tool;
pub const ListToolsResult = tools_mod.ListToolsResult;
pub const CallToolParams = tools_mod.CallToolParams;
pub const CallToolResult = tools_mod.CallToolResult;

// Resources
const resources_mod = @import("types/resources.zig");
pub const Resource = resources_mod.Resource;
pub const ResourceTemplate = resources_mod.ResourceTemplate;
pub const ListResourcesResult = resources_mod.ListResourcesResult;
pub const ListResourceTemplatesResult = resources_mod.ListResourceTemplatesResult;
pub const ReadResourceParams = resources_mod.ReadResourceParams;
pub const ReadResourceResult = resources_mod.ReadResourceResult;

// Prompts
const prompts_mod = @import("types/prompts.zig");
pub const PromptArgument = prompts_mod.PromptArgument;
pub const Prompt = prompts_mod.Prompt;
pub const ListPromptsResult = prompts_mod.ListPromptsResult;
pub const GetPromptParams = prompts_mod.GetPromptParams;
pub const PromptMessage = prompts_mod.PromptMessage;
pub const GetPromptResult = prompts_mod.GetPromptResult;

// Channel
const channel_mod = @import("types/channel.zig");
pub const ChannelEventParams = channel_mod.ChannelEventParams;
pub const PermissionBehavior = channel_mod.PermissionBehavior;
pub const PermissionRequestParams = channel_mod.PermissionRequestParams;
pub const PermissionVerdictParams = channel_mod.PermissionVerdictParams;
pub const experimentalCapabilities = channel_mod.experimentalCapabilities;
pub const channel_event_method = channel_mod.channel_event_method;
pub const permission_request_method = channel_mod.permission_request_method;
pub const permission_verdict_method = channel_mod.permission_verdict_method;

// Schema generation + argument parsing
pub const schemaForStruct = @import("types/schema.zig").schemaForStruct;
pub const parseArgs = @import("types/json_utils.zig").parseArgs;

// Logging
pub const LoggingLevel = @import("types/logging.zig").LoggingLevel;

// Initialize
const init = @import("types/initialize.zig");
pub const InitializeParams = init.InitializeParams;
pub const InitializeResult = init.InitializeResult;

test {
    @import("std").testing.refAllDecls(@This());
}

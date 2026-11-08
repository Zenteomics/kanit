//! `kanit schema`: a JSON Schema of the workflow format, for editors that
//! check TOML against one (Taplo, Even Better TOML). The keys of every
//! table come from the parser's own key lists, so the schema accepts and
//! rejects the keys `validate` does; each key here only adds its type and
//! a line of help.
const std = @import("std");
const workflow = @import("workflow.zig");

const Type = enum { any, string, integer, boolean, strings, string_table, integer_table, resources };

const Key = struct { name: []const u8, type: Type, help: []const u8 };

const workflow_types = [_]Key{
    .{ .name = "name", .type = .string, .help = "name of the workflow, required" },
    .{ .name = "version", .type = .string, .help = "your version label" },
    .{ .name = "description", .type = .any, .help = "what the workflow does; any value, not read" },
    .{ .name = "author", .type = .any, .help = "who wrote it; any value, not read" },
    .{ .name = "format_version", .type = .integer, .help = "workflow format, 1" },
};
const default_types = [_]Key{
    .{ .name = "threads", .type = .integer, .help = "threads of rules that set none" },
    .{ .name = "memory", .type = .string, .help = "memory of rules that set none, such as \"4G\"" },
};
const group_types = [_]Key{
    .{ .name = "max", .type = .integer, .help = "units taken at once, 1 to 1000000" },
};
const shared_types = [_]Key{
    .{ .name = "path", .type = .string, .help = "file or directory held once; a service's read-only index" },
    .{ .name = "container", .type = .string, .help = "image of a service" },
    .{ .name = "command", .type = .string, .help = "command that loads a service" },
    .{ .name = "memory", .type = .string, .help = "memory a service holds, such as \"30G\"" },
    .{ .name = "timeout", .type = .string, .help = "limit on a service's loading, such as \"30m\"" },
    .{ .name = "retries", .type = .integer, .help = "starts of a service again, 0 to 3" },
    .{ .name = "mounts", .type = .string_table, .help = "host path = path in the image" },
};
const rule_types = [_]Key{
    .{ .name = "name", .type = .string, .help = "unique rule name, required" },
    .{ .name = "input", .type = .strings, .help = "files and directories it reads" },
    .{ .name = "output", .type = .strings, .help = "files it writes, at least one" },
    .{ .name = "shell", .type = .string, .help = "the command, required" },
    .{ .name = "threads", .type = .integer, .help = "threads, 1 to 4096" },
    .{ .name = "memory", .type = .string, .help = "memory, such as \"8G\"" },
    .{ .name = "resources", .type = .resources, .help = "threads, memory, groups and shared inputs" },
    .{ .name = "priority", .type = .integer, .help = "higher starts first" },
    .{ .name = "log", .type = .string, .help = "copy of stdout and stderr" },
    .{ .name = "benchmark", .type = .string, .help = "JSON summary of a completed attempt" },
    .{ .name = "retries", .type = .integer, .help = "extra attempts, 0 to 3" },
    .{ .name = "timeout", .type = .string, .help = "limit per attempt, such as \"2h\"" },
    .{ .name = "cutoff", .type = .boolean, .help = "key consumers on output bytes" },
    .{ .name = "container", .type = .string, .help = "run in this local image" },
    .{ .name = "mounts", .type = .string_table, .help = "host path = path in the image" },
    .{ .name = "workdir", .type = .string, .help = "directory the command starts in" },
    .{ .name = "links", .type = .string_table, .help = "link name = input, in workdir" },
    .{ .name = "step", .type = .string, .help = "pipeline step it is an instance of" },
    .{ .name = "category", .type = .string, .help = "group of steps it belongs to" },
    .{ .name = "tool", .type = .string, .help = "program it runs" },
    .{ .name = "sample", .type = .string, .help = "data it works on" },
    .{ .name = "diagnostics", .type = .strings, .help = "files kept when an attempt fails" },
    .{ .name = "version", .type = .string, .help = "command that prints the tool version" },
};
const resource_types = [_]Key{
    .{ .name = "threads", .type = .integer, .help = "threads, 1 to 4096" },
    .{ .name = "memory", .type = .string, .help = "memory, such as \"8G\"" },
    .{ .name = "groups", .type = .integer_table, .help = "resource group = units" },
    .{ .name = "shared", .type = .strings, .help = "shared inputs it uses" },
};

pub fn find(types: []const Key, name: []const u8) ?Key {
    for (types) |k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

pub const tables = [_]struct { keys: []const []const u8, types: []const Key }{
    .{ .keys = &workflow.workflow_keys, .types = &workflow_types },
    .{ .keys = &workflow.default_keys, .types = &default_types },
    .{ .keys = &workflow.group_keys, .types = &group_types },
    .{ .keys = &workflow.shared_keys, .types = &shared_types },
    .{ .keys = &workflow.rule_keys, .types = &rule_types },
    .{ .keys = &workflow.resource_keys, .types = &resource_types },
};

fn value(w: *std.Io.Writer, k: Key) std.Io.Writer.Error!void {
    switch (k.type) {
        .any => return w.print("{{\"description\":{f}}}", .{std.json.fmt(k.help, .{})}),
        .string => try w.writeAll("{\"type\":\"string\""),
        .integer => try w.writeAll("{\"type\":\"integer\""),
        .boolean => try w.writeAll("{\"type\":\"boolean\""),
        .strings => try w.writeAll("{\"type\":\"array\",\"items\":{\"type\":\"string\"}"),
        .string_table => try w.writeAll("{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}"),
        .integer_table => try w.writeAll("{\"type\":\"object\",\"additionalProperties\":{\"type\":\"integer\"}"),
        .resources => {
            try w.writeAll("{");
            try object(w, &workflow.resource_keys, &resource_types);
        },
    }
    try w.print(",\"description\":{f}}}", .{std.json.fmt(k.help, .{})});
}

fn object(w: *std.Io.Writer, keys: []const []const u8, types: []const Key) std.Io.Writer.Error!void {
    try w.writeAll("\"type\":\"object\",\"additionalProperties\":false,\"properties\":{");
    for (keys, 0..) |name, n| {
        if (n > 0) try w.writeAll(",");
        try w.print("{f}:", .{std.json.fmt(name, .{})});
        try value(w, find(types, name) orelse .{ .name = name, .type = .string, .help = "" });
    }
    try w.writeAll("}");
}

pub fn write(w: *std.Io.Writer) !void {
    try w.writeAll("{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"title\":\"kanit workflow, format 1\",");
    try w.writeAll("\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"workflow\",\"rules\"],\"properties\":{");
    try w.writeAll("\"workflow\":{");
    try object(w, &workflow.workflow_keys, &workflow_types);
    try w.writeAll(",\"required\":[\"name\"]},\"defaults\":{");
    try object(w, &workflow.default_keys, &default_types);
    try w.writeAll("},\"resource_groups\":{\"type\":\"object\",\"additionalProperties\":{");
    try object(w, &workflow.group_keys, &group_types);
    try w.writeAll(",\"required\":[\"max\"]}},\"shared\":{\"type\":\"object\",\"additionalProperties\":{");
    try object(w, &workflow.shared_keys, &shared_types);
    try w.writeAll("}},\"rules\":{\"type\":\"array\",\"items\":{");
    try object(w, &workflow.rule_keys, &rule_types);
    try w.writeAll(",\"required\":[\"name\",\"output\",\"shell\"]}}}}\n");
}

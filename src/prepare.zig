//! `workz prepare`: compiles a pipeline template into the explicit workflow
//! the engine runs. A template describes each step once; a step with
//! `for_each = "sample"` becomes one rule per row of the sample sheet, and
//! `{name}` placeholders take the row's columns, the template's `[params]`
//! and the step's name. Only known names are replaced, so the braces of
//! awk programs and shell variables stay as written. The result is a plain
//! workflow file with `step` and `sample` labels on every rule, checked by
//! the same parser as any other; the engine itself expands nothing.
const std = @import("std");
const toml = @import("toml");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const template_keys = [_][]const u8{ "workflow", "defaults", "resource_groups", "shared", "samples", "params", "steps" };
const sample_keys = [_][]const u8{ "sheet", "names", "defaults" };

/// The sample sheet: column names, and one row of values per sample.
pub const Sheet = struct {
    columns: []const []const u8,
    rows: []const []const []const u8,
    /// Where it was read from, for messages.
    source: []const u8,

    fn column(self: Sheet, name: []const u8) ?usize {
        for (self.columns, 0..) |c, i| if (eql(u8, c, name)) return i;
        return null;
    }
};

/// Why a template cannot be compiled, as one line; set with the error.
pub const Problem = struct {
    message: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory, WriteFailed };

fn fail(a: Allocator, problem: *Problem, comptime fmt: []const u8, args: anytype) Error {
    problem.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Invalid;
}

/// Column defaults of a sample sheet: an empty cell of a column with a
/// default takes it, and a column the sheet lacks takes it on every row.
pub const Defaults = std.StringArrayHashMapUnmanaged([]const u8);

/// Reads a TSV (or, for a `.csv` file, comma-separated) sample sheet with
/// a header line naming its columns, one of them `sample`. Empty lines and
/// lines starting with `#` are skipped. An empty cell is refused unless its
/// column has a default.
pub fn readSheet(gpa: Allocator, a: Allocator, path: []const u8, shown: []const u8, defaults: Defaults, problem: *Problem) Error!Sheet {
    const raw_bytes = sys.readFile(gpa, path, 64 << 20) catch |err| return fail(a, problem, "cannot read the sample sheet {s}: {s}", .{ shown, sys.errorText(err) });
    defer gpa.free(raw_bytes);
    // A spreadsheet program may start the file with a UTF-8 byte order mark.
    const bytes = if (std.mem.startsWith(u8, raw_bytes, "\xef\xbb\xbf")) raw_bytes[3..] else raw_bytes;
    const csv = std.mem.endsWith(u8, path, ".csv");
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var header: ?[]const []const u8 = null;
    var rows: std.ArrayList([]const []const u8) = .empty;
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0 or line[0] == '#') continue;
        var fields: std.ArrayList([]const u8) = .empty;
        if (csv) {
            splitCsv(a, line, &fields) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed => return fail(a, problem, "{s} line {d}: a quoted field must close its quote before the next comma or the end of the line", .{ shown, n }),
            };
        } else {
            var it = std.mem.splitScalar(u8, line, '\t');
            while (it.next()) |f| try fields.append(a, try a.dupe(u8, std.mem.trim(u8, f, " ")));
        }
        if (header) |h| {
            if (fields.items.len != h.len) return fail(a, problem, "{s} line {d}: {d} fields, but the header has {d}", .{ shown, n, fields.items.len, h.len });
            for (fields.items, h) |*v, col| if (v.len == 0) {
                v.* = defaults.get(col) orelse return fail(a, problem, "{s} line {d}: column {s} is empty", .{ shown, n, col });
            };
            try rows.append(a, fields.items);
        } else header = fields.items;
    }
    const h = header orelse return fail(a, problem, "{s} has no header line", .{shown});
    const sheet: Sheet = .{ .columns = h, .rows = rows.items, .source = shown };
    const si = sheet.column("sample") orelse return fail(a, problem, "{s} has no column named sample", .{shown});
    for (h, 0..) |col, i| for (h[i + 1 ..]) |other| if (eql(u8, col, other)) return fail(a, problem, "{s} names column {s} twice", .{ shown, col });
    for (h) |col| if (reserved(col)) return fail(a, problem, "{s}: column {s} has the name of a placeholder workz prepare fills; rename it", .{ shown, col });
    for (rows.items, 0..) |row, k| {
        if (!workflow.validName(row[si])) return fail(a, problem, "{s}: sample '{s}' must use letters, digits, '_', '.', '-', starting with a letter or digit", .{ shown, row[si] });
        for (rows.items[0..k]) |earlier| if (eql(u8, earlier[si], row[si])) return fail(a, problem, "{s} lists sample {s} twice", .{ shown, row[si] });
    }
    if (rows.items.len == 0) return fail(a, problem, "{s} lists no sample", .{shown});
    return withDefaults(a, sheet, defaults);
}

/// The sheet with a column for every default it lacks, holding the default on every row.
fn withDefaults(a: Allocator, sheet: Sheet, defaults: Defaults) Error!Sheet {
    var columns: std.ArrayList([]const u8) = .empty;
    try columns.appendSlice(a, sheet.columns);
    for (defaults.keys()) |col| if (sheet.column(col) == null) try columns.append(a, col);
    if (columns.items.len == sheet.columns.len) return sheet;
    const rows = try a.alloc([]const []const u8, sheet.rows.len);
    for (sheet.rows, rows) |row, *out| {
        const full = try a.alloc([]const u8, columns.items.len);
        @memcpy(full[0..row.len], row);
        for (columns.items[row.len..], full[row.len..]) |col, *v| v.* = defaults.get(col).?;
        out.* = full;
    }
    return .{ .columns = columns.items, .rows = rows, .source = sheet.source };
}

/// The placeholders `workz prepare` fills from the step itself; a column or
/// param of the same name would hide them, so the command and the request
/// could disagree.
fn reserved(name: []const u8) bool {
    for ([_][]const u8{ "step", "input", "output", "threads" }) |r| if (eql(u8, name, r)) return true;
    return false;
}

/// The fields of one CSV line, as RFC 4180 writes them: a field in double
/// quotes may hold commas, and `""` in it is one quote. Unquoted fields are
/// trimmed of spaces. A quoted field spans one line.
fn splitCsv(a: Allocator, line: []const u8, fields: *std.ArrayList([]const u8)) error{ OutOfMemory, Malformed }!void {
    var i: usize = 0;
    while (true) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i < line.len and line[i] == '"') {
            var field: std.ArrayList(u8) = .empty;
            i += 1;
            while (true) {
                if (i >= line.len) return error.Malformed;
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        try field.append(a, '"');
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                try field.append(a, line[i]);
                i += 1;
            }
            while (i < line.len and line[i] == ' ') i += 1;
            if (i < line.len and line[i] != ',') return error.Malformed;
            try fields.append(a, field.items);
        } else {
            const end = std.mem.indexOfScalarPos(u8, line, i, ',') orelse line.len;
            try fields.append(a, try a.dupe(u8, std.mem.trim(u8, line[i..end], " ")));
            i = end;
        }
        if (i >= line.len) return;
        i += 1;
    }
}

/// The values `{name}` placeholders take in one rule.
const Scope = struct {
    sheet: ?Sheet,
    /// The sample sheet row of a `for_each` rule.
    row: ?[]const []const u8,
    params: *const std.StringArrayHashMapUnmanaged([]const u8),
    /// Where the values are, for messages: `step NAME`, `shared.NAME`, `workflow`.
    place: []const u8,
    /// The value of `{step}`, in a step only.
    step: ?[]const u8 = null,
    /// Set for `shell`: its rule's inputs, outputs and threads.
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    threads: ?[]const u8 = null,

    fn get(self: Scope, name: []const u8) ?[]const u8 {
        if (self.row) |row| if (self.sheet.?.column(name)) |c| return row[c];
        if (self.params.get(name)) |v| return v;
        if (eql(u8, name, "step")) return self.step;
        if (eql(u8, name, "input")) return self.input;
        if (eql(u8, name, "output")) return self.output;
        if (eql(u8, name, "threads")) return self.threads;
        return null;
    }
};

fn isIdent(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Whether `s` names a sample-sheet column in a placeholder.
fn namesColumn(sheet: ?Sheet, s: []const u8) ?[]const u8 {
    const sh = sheet orelse return null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, s, open + 1, '}') orelse break;
        const name = s[open + 1 .. close];
        if (isIdent(name) and sh.column(name) != null) return name;
        i = open + 1;
    }
    return null;
}

/// Replaces each `{name}` that `scope` knows. In `shell` an unknown one
/// or a service's `command` stays as written; anywhere else it is an
/// error, since paths and labels never need braces.
fn subst(a: Allocator, problem: *Problem, scope: Scope, key: []const u8, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{') if (std.mem.indexOfScalarPos(u8, s, i + 1, '}')) |close| {
            const name = s[i + 1 .. close];
            if (isIdent(name)) {
                if (scope.get(name)) |v| {
                    try out.appendSlice(a, v);
                    i = close + 1;
                    continue;
                }
                // A sheet column outside a per-sample rule is a mistake even in
                // a command.
                if (scope.sheet) |sh| if (sh.column(name) != null)
                    return fail(a, problem, "{s}: {s} names {{{s}}}, a column of the sample sheet, but the step has no for_each = \"sample\"", .{ scope.place, key, name });
                if (!eql(u8, key, "shell") and !eql(u8, key, "command")) {
                    return fail(a, problem, "{s}: {s} names {{{s}}}, which is no sample-sheet column, param or placeholder", .{ scope.place, key, name });
                }
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

// ---- TOML output ----

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeKey(w: *std.Io.Writer, k: []const u8) !void {
    for (k) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return writeString(w, k);
    try w.writeAll(k);
}

/// A value as TOML, tables inline.
fn writeValue(w: *std.Io.Writer, v: toml.Value) !void {
    switch (v) {
        .string => |s| try writeString(w, s),
        .integer => |i| try w.print("{d}", .{i.value}),
        .float => |f| try w.print("{d}", .{f}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |arr| {
            try w.writeAll("[");
            for (arr.items, 0..) |item, k| {
                if (k > 0) try w.writeAll(", ");
                try writeValue(w, item);
            }
            try w.writeAll("]");
        },
        .table => |t| {
            try w.writeAll("{ ");
            var it = t.iterator();
            var k: usize = 0;
            while (it.next()) |e| : (k += 1) {
                if (k > 0) try w.writeAll(", ");
                try writeKey(w, e.key_ptr.*);
                try w.writeAll(" = ");
                try writeValue(w, e.value_ptr.*);
            }
            try w.writeAll(" }");
        },
        else => try w.writeAll("\"\""),
    }
}

/// A table of the template copied as written, under its header `[name]`,
/// or `[name.key]` with `key` quoted as a key must be.
fn writeTable(w: *std.Io.Writer, name: []const u8, key: ?[]const u8, t: *const toml.Table) !void {
    try w.print("[{s}", .{name});
    if (key) |k| {
        try w.writeByte('.');
        try writeKey(w, k);
    }
    try w.writeAll("]\n");
    var it = t.iterator();
    while (it.next()) |e| {
        try writeKey(w, e.key_ptr.*);
        try w.writeAll(" = ");
        try writeValue(w, e.value_ptr.*);
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}

// ---- compiling ----

/// One value of a step for one rule, placeholders replaced. In a step
/// without `for_each`, a list element naming a sheet column becomes one
/// element per sample.
fn ruleValue(a: Allocator, problem: *Problem, scope: Scope, key: []const u8, v: toml.Value) Error!toml.Value {
    switch (v) {
        .string => |s| return .{ .string = try subst(a, problem, scope, key, s) },
        .array => |arr| {
            const out = try a.create(toml.Array);
            out.* = .empty;
            for (arr.items) |item| {
                if (item == .string and scope.row == null) if (namesColumn(scope.sheet, item.string)) |_| {
                    for (scope.sheet.?.rows) |row| {
                        var each = scope;
                        each.row = row;
                        try out.append(a, .{ .string = try subst(a, problem, each, key, item.string) });
                    }
                    continue;
                };
                try out.append(a, try ruleValue(a, problem, scope, key, item));
            }
            return .{ .array = out };
        },
        .table => |t| {
            const out = try a.create(toml.Table);
            out.* = .empty;
            var it = t.iterator();
            while (it.next()) |e| try out.put(a, e.key_ptr.*, try ruleValue(a, problem, scope, e.key_ptr.*, e.value_ptr.*));
            return .{ .table = out };
        },
        else => return v,
    }
}

/// A step's `input` or `output` list as the shell's `{input}` or
/// `{output}`: its paths joined by spaces.
fn joined(a: Allocator, problem: *Problem, step: []const u8, key: []const u8, v: ?toml.Value) Error![]const u8 {
    const list = v orelse return "";
    if (list != .array) return fail(a, problem, "step {s}: {s} must be a list of paths", .{ step, key });
    var out: std.ArrayList(u8) = .empty;
    for (list.array.items, 0..) |item, k| {
        if (item != .string) return fail(a, problem, "step {s}: {s} must be a list of paths", .{ step, key });
        if (k > 0) try out.append(a, ' ');
        try out.appendSlice(a, item.string);
    }
    return out.items;
}

/// Writes the rule of step `name` for one sample (`row`), or the step's
/// single rule.
fn writeRule(a: Allocator, w: *std.Io.Writer, problem: *Problem, step: *const toml.Table, name: []const u8, scope: Scope) !void {
    var values: std.StringArrayHashMapUnmanaged(toml.Value) = .empty;
    var it = step.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (eql(u8, key, "name") or eql(u8, key, "for_each") or eql(u8, key, "shell")) continue;
        try values.put(a, key, try ruleValue(a, problem, scope, key, e.value_ptr.*));
    }
    // `shell` last: {input}, {output} and {threads} name the rule's own.
    if (step.get("shell")) |sh| {
        var s = scope;
        s.input = try joined(a, problem, name, "input", values.get("input"));
        s.output = try joined(a, problem, name, "output", values.get("output"));
        // The variable, not a number: a `--threads` override reaches the
        // command as it reaches the rule's request.
        s.threads = "${WORKZ_THREADS}";
        try values.put(a, "shell", try ruleValue(a, problem, s, "shell", sh));
    }
    const sample: ?[]const u8 = if (scope.row) |row| row[scope.sheet.?.column("sample").?] else null;
    try w.writeAll("[[rules]]\nname = ");
    try writeString(w, if (sample) |sm| try std.fmt.allocPrint(a, "{s}__{s}", .{ sm, name }) else name);
    try w.writeAll("\nstep = ");
    try writeString(w, name);
    try w.writeAll("\n");
    if (sample) |sm| {
        try w.writeAll("sample = ");
        try writeString(w, sm);
        try w.writeAll("\n");
    }
    for (values.keys(), values.values()) |key, v| {
        try writeKey(w, key);
        try w.writeAll(" = ");
        try writeValue(w, v);
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}

/// The sample sheet a `[samples]` table names: a file read beside `path`
/// (the template or the run file), or a list of names; null without one.
fn readSamples(gpa: Allocator, a: Allocator, value: ?toml.Value, path: []const u8, shown: []const u8, problem: *Problem) Error!?Sheet {
    const sv = value orelse return null;
    var sheet: ?Sheet = null;
    if (sv != .table) return fail(a, problem, "{s}: samples must be a table with sheet or names", .{shown});
    const st = sv.table;
    var kit = st.iterator();
    while (kit.next()) |e| if (!contains(&sample_keys, e.key_ptr.*)) return fail(a, problem, "{s}: unknown key '{s}' in [samples]; use sheet, names or defaults", .{ shown, e.key_ptr.* });
    if (st.get("sheet") != null and st.get("names") != null) return fail(a, problem, "{s}: [samples] takes sheet or names, not both", .{shown});
    var defaults: Defaults = .empty;
    if (st.get("defaults")) |dv| {
        if (dv != .table) return fail(a, problem, "{s}: samples.defaults must be a table of column = \"value\"", .{shown});
        var dit = dv.table.iterator();
        while (dit.next()) |e| {
            const col = e.key_ptr.*;
            if (e.value_ptr.* != .string) return fail(a, problem, "{s}: samples.defaults.{s} must be a string", .{ shown, col });
            if (eql(u8, col, "sample")) return fail(a, problem, "{s}: samples.defaults cannot name sample; every row names its own", .{shown});
            if (reserved(col)) return fail(a, problem, "{s}: samples.defaults.{s} has the name of a placeholder workz prepare fills; rename it", .{ shown, col });
            try defaults.put(a, col, e.value_ptr.string);
        }
    }
    if (st.get("sheet")) |p| {
        if (p != .string) return fail(a, problem, "{s}: samples.sheet must be a path", .{shown});
        const dir = std.fs.path.dirname(path) orelse ".";
        sheet = try readSheet(gpa, a, try sys.absolute(a, dir, p.string), p.string, defaults, problem);
    } else if (st.get("names")) |n| {
        if (n != .array) return fail(a, problem, "{s}: samples.names must be a list of names", .{shown});
        var rows: std.ArrayList([]const []const u8) = .empty;
        for (n.array.items) |item| {
            if (item != .string or !workflow.validName(item.string)) return fail(a, problem, "{s}: samples.names holds an invalid sample name", .{shown});
            const row = try a.alloc([]const u8, 1);
            row[0] = item.string;
            try rows.append(a, row);
        }
        const cols = try a.alloc([]const u8, 1);
        cols[0] = "sample";
        sheet = try withDefaults(a, .{ .columns = cols, .rows = rows.items, .source = "samples.names" }, defaults);
    } else return fail(a, problem, "{s}: [samples] needs sheet or names", .{shown});
    return sheet;
}

/// The values of a `[params]` table, put over those already in `params`.
fn addParams(a: Allocator, problem: *Problem, value: ?toml.Value, shown: []const u8, sheet: ?Sheet, params: *std.StringArrayHashMapUnmanaged([]const u8)) Error!void {
    const pv = value orelse return;
    if (pv != .table) return fail(a, problem, "{s}: params must be a table", .{shown});
    var pit = pv.table.iterator();
    while (pit.next()) |e| {
        const name = e.key_ptr.*;
        if (!isIdent(name)) return fail(a, problem, "{s}: param '{s}' must be a name of letters, digits and '_'", .{ shown, name });
        if (reserved(name)) return fail(a, problem, "{s}: param {s} has the name of a placeholder workz prepare fills; rename it", .{ shown, name });
        if (sheet) |sh| if (sh.column(name) != null) return fail(a, problem, "{s}: param {s} is also a column of {s}", .{ shown, name, sh.source });
        try params.put(a, name, switch (e.value_ptr.*) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i.value}),
            .boolean => |b| if (b) "true" else "false",
            else => return fail(a, problem, "{s}: param {s} must be a string, number or boolean", .{ shown, name }),
        });
    }
}

/// A run file given beside a template: the run's own `[workflow]` keys,
/// `[samples]` and `[params]`, so one template serves many runs.
pub const RunFile = struct { path: []const u8, shown: []const u8 };
const run_keys = [_][]const u8{ "workflow", "samples", "params" };

/// Compiles the template at `path` into workflow text.
pub fn compile(gpa: Allocator, a: Allocator, path: []const u8, shown: []const u8, problem: *Problem) Error![]const u8 {
    return compileWith(gpa, a, path, shown, null, problem);
}

/// The workflow a template describes, with a run file's values in place of
/// the template's: its `[workflow]` keys and `[params]` one by one, and its
/// `[samples]` whole, the sheet read beside the run file.
pub fn compileWith(gpa: Allocator, a: Allocator, path: []const u8, shown: []const u8, run: ?RunFile, problem: *Problem) Error![]const u8 {
    const source = sys.readFile(gpa, path, 64 << 20) catch |err| return fail(a, problem, "cannot read {s}: {s}", .{ shown, sys.errorText(err) });
    defer gpa.free(source);
    var info: toml.ErrorInfo = .{};
    const doc = toml.parseSlice(gpa, source, &info) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, problem, "{s}: line {d}, column {d}: {s}", .{ shown, info.line, info.col, info.message() }),
    };
    defer toml.deinit(doc, gpa);
    var it = doc.iterator();
    while (it.next()) |e| if (!contains(&template_keys, e.key_ptr.*)) {
        if (eql(u8, e.key_ptr.*, "rules")) return fail(a, problem, "{s}: write rules as [[steps]]; a step without for_each makes one rule", .{shown});
        if (workflow.closest(&template_keys, e.key_ptr.*)) |hint| return fail(a, problem, "{s}: unknown table '{s}'; did you mean '{s}'?", .{ shown, e.key_ptr.*, hint });
        return fail(a, problem, "{s}: unknown table '{s}'", .{ shown, e.key_ptr.* });
    };

    var run_doc: ?@TypeOf(doc) = null;
    var run_source: []u8 = &.{};
    defer if (run_doc) |d| toml.deinit(d, gpa);
    defer gpa.free(run_source);
    if (run) |r| {
        run_source = sys.readFile(gpa, r.path, 64 << 20) catch |err| return fail(a, problem, "cannot read {s}: {s}", .{ r.shown, sys.errorText(err) });
        var run_info: toml.ErrorInfo = .{};
        run_doc = toml.parseSlice(gpa, run_source, &run_info) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(a, problem, "{s}: line {d}, column {d}: {s}", .{ r.shown, run_info.line, run_info.col, run_info.message() }),
        };
        var rit = run_doc.?.iterator();
        while (rit.next()) |e| if (!contains(&run_keys, e.key_ptr.*)) return fail(a, problem, "{s}: unknown table '{s}'; a run file holds workflow, samples and params", .{ r.shown, e.key_ptr.* });
    }

    // The sample sheet: a file beside the template, or a list of names; a
    // run file's samples take the place of the template's.
    const run_samples = if (run_doc) |d| d.get("samples") else null;
    const sheet = try readSamples(gpa, a, run_samples orelse doc.get("samples"), if (run_samples != null) run.?.path else path, if (run_samples != null) run.?.shown else shown, problem);

    var params: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try addParams(a, problem, doc.get("params"), shown, sheet, &params);
    if (run_doc) |d| try addParams(a, problem, d.get("params"), run.?.shown, sheet, &params);

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    if (run) |r| {
        try w.print("# Written by `workz prepare` from {s} with {s}: edit those files and run it\n# again, since changes made here are lost.\n\n", .{ std.fs.path.basename(shown), std.fs.path.basename(r.shown) });
    } else try w.print("# Written by `workz prepare` from {s}: edit that file and run it again,\n# since changes made here are lost.\n\n", .{std.fs.path.basename(shown)});
    for ([_][]const u8{ "workflow", "defaults" }) |name| {
        const over: ?toml.Value = if (eql(u8, name, "workflow")) (if (run_doc) |d| d.get("workflow") else null) else null;
        const base = doc.get(name);
        if (base == null and over == null) continue;
        const merged = try a.create(toml.Table);
        merged.* = .empty;
        for ([_]?toml.Value{ base, over }, [_][]const u8{ shown, if (run) |r| r.shown else shown }) |part, place| if (part) |v| {
            if (v != .table) return fail(a, problem, "{s}: {s} must be a table", .{ place, name });
            var mit = v.table.iterator();
            while (mit.next()) |e| try merged.put(a, e.key_ptr.*, e.value_ptr.*);
        };
        // Its values may name params, as every table's may.
        const scope: Scope = .{ .sheet = null, .row = null, .params = &params, .place = name };
        try writeTable(w, name, null, (try ruleValue(a, problem, scope, name, .{ .table = merged })).table);
    }
    for ([_][]const u8{ "resource_groups", "shared" }) |name| if (doc.get(name)) |v| {
        if (v != .table) return fail(a, problem, "{s}: {s} must be a table", .{ shown, name });
        var git = v.table.iterator();
        while (git.next()) |e| {
            if (e.value_ptr.* != .table) return fail(a, problem, "{s}: {s}.{s} must be a table", .{ shown, name, e.key_ptr.* });
            // A shared input may use the params, such as an index's path.
            const scope: Scope = .{ .sheet = null, .row = null, .params = &params, .place = try std.fmt.allocPrint(a, "{s}.{s}", .{ name, e.key_ptr.* }) };
            const filled = try ruleValue(a, problem, scope, name, e.value_ptr.*);
            try writeTable(w, name, e.key_ptr.*, filled.table);
        }
    };

    const steps_v = doc.get("steps") orelse return fail(a, problem, "{s} declares no [[steps]]", .{shown});
    if (steps_v != .array) return fail(a, problem, "{s}: steps must be an array of tables, [[steps]]", .{shown});
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (steps_v.array.items, 0..) |sv, k| {
        if (sv != .table) return fail(a, problem, "{s}: step {d} must be a table", .{ shown, k + 1 });
        const step = sv.table;
        const name_v = step.get("name") orelse return fail(a, problem, "{s}: step {d} has no name", .{ shown, k + 1 });
        if (name_v != .string or !workflow.validName(name_v.string)) return fail(a, problem, "{s}: step {d} needs a name of letters, digits, '_', '.', '-'", .{ shown, k + 1 });
        const name = name_v.string;
        if ((try names.fetchPut(a, name, {})) != null) return fail(a, problem, "{s}: two steps are named {s}", .{ shown, name });
        var kit = step.iterator();
        while (kit.next()) |e| {
            const key = e.key_ptr.*;
            if (eql(u8, key, "for_each")) continue;
            if (eql(u8, key, "step") or eql(u8, key, "sample")) return fail(a, problem, "step {s}: {s} is set by workz prepare; leave it out", .{ name, key });
            if (contains(&workflow.rule_keys, key)) continue;
            if (workflow.closest(&workflow.rule_keys, key)) |hint| return fail(a, problem, "step {s}: unknown key '{s}'; did you mean '{s}'?", .{ name, key, hint });
            return fail(a, problem, "step {s}: unknown key '{s}'", .{ name, key });
        }
        const scope: Scope = .{ .sheet = sheet, .row = null, .params = &params, .place = try std.fmt.allocPrint(a, "step {s}", .{name}), .step = name };
        if (step.get("for_each")) |fe| {
            if (fe != .string or !eql(u8, fe.string, "sample")) return fail(a, problem, "step {s}: for_each takes \"sample\"", .{name});
            const sh = sheet orelse return fail(a, problem, "step {s}: for_each = \"sample\" needs a [samples] table", .{name});
            for (sh.rows) |row| {
                var s = scope;
                s.row = row;
                try writeRule(a, w, problem, step, name, s);
            }
        } else try writeRule(a, w, problem, step, name, scope);
    }
    return out.written();
}

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (eql(u8, k, key)) return true;
    return false;
}

// ---- comparing with the current workflow ----

/// The rules of a prepared workflow text, by name, each with its text.
fn ruleBlocks(a: Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, "\n[[rules]]\n");
    _ = it.next();
    while (it.next()) |block| {
        const line_end = std.mem.indexOfScalar(u8, block, '\n') orelse block.len;
        const first = block[0..line_end];
        const prefix = "name = \"";
        if (!std.mem.startsWith(u8, first, prefix)) continue;
        // Names hold no quote, so the next one closes it; a comment may follow.
        const end = std.mem.indexOfScalarPos(u8, first, prefix.len, '"') orelse continue;
        try map.put(a, first[prefix.len..end], block);
    }
    return map;
}

/// What `--check` prints: the rules a new compile adds, removes and
/// changes against `old`, and whether anything else changed. Returns
/// whether the two differ.
pub fn writeDiff(a: Allocator, w: *std.Io.Writer, old: []const u8, new: []const u8) !bool {
    if (eql(u8, old, new)) {
        try w.writeAll("unchanged: the workflow file is what the template prepares\n");
        return false;
    }
    const was = try ruleBlocks(a, old);
    const now = try ruleBlocks(a, new);
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;
    for (now.keys(), now.values()) |name, block| {
        const before = was.get(name) orelse {
            try added.append(a, name);
            continue;
        };
        if (!eql(u8, std.mem.trimEnd(u8, before, "\n"), std.mem.trimEnd(u8, block, "\n"))) try changed.append(a, name);
    }
    for (was.keys()) |name| if (!now.contains(name)) try removed.append(a, name);
    for ([_]struct { []const u8, []const []const u8 }{ .{ "add", added.items }, .{ "remove", removed.items }, .{ "change", changed.items } }) |row| {
        if (row[1].len == 0) continue;
        try w.print("{s} {d}: ", .{ row[0], row[1].len });
        for (row[1][0..@min(row[1].len, 10)], 0..) |name, k| try w.print("{s}{s}", .{ if (k == 0) "" else ", ", name });
        if (row[1].len > 10) try w.print(" and {d} more", .{row[1].len - 10});
        try w.writeAll("\n");
    }
    const head_old = old[0 .. std.mem.indexOf(u8, old, "\n[[rules]]\n") orelse old.len];
    const head_new = new[0 .. std.mem.indexOf(u8, new, "\n[[rules]]\n") orelse new.len];
    if (!eql(u8, head_old, head_new)) try w.writeAll("change: the workflow, defaults, groups or shared inputs\n");
    return true;
}

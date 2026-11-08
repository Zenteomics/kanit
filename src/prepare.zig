//! `kanit prepare`: compiles a pipeline template into the explicit workflow
//! the engine runs. A template describes each step once; a step with
//! `for_each = "sample"` becomes one rule per row of the sample sheet, and
//! `{name}` placeholders take the row's columns, the template's `[params]`
//! and the step's name. Only known names are replaced, so the braces of
//! awk programs stay as written, and `${name}` is always the shell's
//! variable. The result is a plain workflow file with `step` and `sample`
//! labels on every rule, checked by the same parser as any other; the engine
//! itself expands nothing.
const std = @import("std");
const toml = @import("toml");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const template_keys = [_][]const u8{ "workflow", "defaults", "resource_groups", "shared", "samples", "params", "steps" };
const sample_keys = [_][]const u8{ "sheet", "names", "defaults" };

pub const Sheet = struct {
    columns: []const []const u8,
    rows: []const []const []const u8,
    source: []const u8,

    fn column(self: Sheet, name: []const u8) ?usize {
        for (self.columns, 0..) |c, i| if (eql(u8, c, name)) return i;
        return null;
    }
};

pub const Problem = struct {
    message: []const u8 = "",
    notes: std.ArrayList([]const u8) = .empty,
};

pub const Error = error{ Invalid, OutOfMemory, WriteFailed };

fn fail(a: Allocator, problem: *Problem, comptime fmt: []const u8, args: anytype) Error {
    problem.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Invalid;
}

pub const Defaults = std.StringArrayHashMapUnmanaged([]const u8);

pub fn readSheet(gpa: Allocator, a: Allocator, path: []const u8, shown: []const u8, defaults: Defaults, problem: *Problem) Error!Sheet {
    const raw_bytes = sys.readFile(gpa, path, 64 << 20) catch |err| return fail(a, problem, "cannot read the sample sheet {s}: {s}", .{ shown, sys.errorText(err) });
    defer gpa.free(raw_bytes);
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
    for (h) |col| if (reserved(col)) return fail(a, problem, "{s}: column {s} has the name of a placeholder kanit prepare fills; rename it", .{ shown, col });
    for (rows.items, 0..) |row, k| {
        if (!workflow.validName(row[si])) return fail(a, problem, "{s}: sample '{s}' must use letters, digits, '_', '.', '-', starting with a letter or digit", .{ shown, row[si] });
        for (rows.items[0..k]) |earlier| if (eql(u8, earlier[si], row[si])) return fail(a, problem, "{s} lists sample {s} twice", .{ shown, row[si] });
    }
    if (rows.items.len == 0) return fail(a, problem, "{s} lists no sample", .{shown});
    return withDefaults(a, sheet, defaults);
}

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

fn reserved(name: []const u8) bool {
    for ([_][]const u8{ "step", "input", "output", "threads" }) |r| if (eql(u8, name, r)) return true;
    return false;
}

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

const Scope = struct {
    sheet: ?Sheet,
    row: ?[]const []const u8,
    params: *const std.StringArrayHashMapUnmanaged([]const u8),
    place: []const u8,
    step: ?[]const u8 = null,
    input: ?[]const []const u8 = null,
    output: ?[]const []const u8 = null,
    threads: ?[]const u8 = null,

    fn get(self: Scope, a: Allocator, name: []const u8) Error!?[]const u8 {
        if (self.row) |row| if (self.sheet.?.column(name)) |c| return row[c];
        if (self.params.get(name)) |v| return v;
        if (eql(u8, name, "step")) return self.step;
        if (eql(u8, name, "input")) return if (self.input) |p| try std.mem.join(a, " ", p) else null;
        if (eql(u8, name, "output")) return if (self.output) |p| try std.mem.join(a, " ", p) else null;
        if (eql(u8, name, "threads")) return self.threads;
        return null;
    }

    fn quoted(self: Scope, a: Allocator, name: []const u8) Error!?[]const u8 {
        if (eql(u8, name, "threads")) return self.threads;
        const listed: ?[]const []const u8 = if (eql(u8, name, "input")) self.input else if (eql(u8, name, "output")) self.output else null;
        if (listed) |list| {
            var out: std.ArrayList(u8) = .empty;
            for (list, 0..) |p, k| {
                if (k > 0) try out.append(a, ' ');
                try shellWord(a, &out, p);
            }
            return out.items;
        }
        const v = (try self.get(a, name)) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        try shellWord(a, &out, v);
        return out.items;
    }
};

fn shellWord(a: Allocator, out: *std.ArrayList(u8), v: []const u8) Error!void {
    const plain = v.len > 0 and for (v) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-./:=@%+,", c) != null)) break false;
    } else true;
    if (plain) return out.appendSlice(a, v);
    try out.append(a, '\'');
    for (v) |c| if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    try out.append(a, '\'');
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

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

fn subst(a: Allocator, problem: *Problem, scope: Scope, key: []const u8, s: []const u8) Error![]const u8 {
    const command = eql(u8, key, "shell") or eql(u8, key, "command");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{' and (i == 0 or s[i - 1] != '$')) if (std.mem.indexOfScalarPos(u8, s, i + 1, '}')) |close| {
            const written = s[i + 1 .. close];
            const quote = std.mem.endsWith(u8, written, ":q");
            const name = if (quote) written[0 .. written.len - 2] else written;
            if (isIdent(name)) {
                if (quote and !command)
                    return fail(a, problem, "{s}: {s} names {{{s}}}; :q quotes a value for the shell, in shell and a service's command only", .{ scope.place, key, written });
                if (try (if (quote) scope.quoted(a, name) else scope.get(a, name))) |v| {
                    try out.appendSlice(a, v);
                    i = close + 1;
                    continue;
                }
                if (scope.sheet) |sh| if (sh.column(name) != null)
                    return fail(a, problem, "{s}: {s} names {{{s}}}, a column of the sample sheet, but the step has no for_each = \"sample\"", .{ scope.place, key, written });
                if (!command) {
                    return fail(a, problem, "{s}: {s} names {{{s}}}, which is no sample-sheet column, param or placeholder", .{ scope.place, key, name });
                }
                try noteTypo(a, problem, scope, key, written, name);
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

fn noteTypo(a: Allocator, problem: *Problem, scope: Scope, key: []const u8, written: []const u8, name: []const u8) Error!void {
    var best: ?[]const u8 = null;
    var best_d: usize = @max(name.len / 3, 1) + 1;
    const fixed = [_][]const u8{ "step", "input", "output", "threads" };
    const columns: []const []const u8 = if (scope.sheet) |sh| sh.columns else &.{};
    for ([_][]const []const u8{ columns, scope.params.keys(), &fixed }) |list| for (list) |cand| {
        const d = workflow.editDistance(cand, name);
        if (d < best_d) {
            best_d = d;
            best = cand;
        }
    };
    const hint = best orelse return;
    const note = try std.fmt.allocPrint(a, "{s}: {s} keeps {{{s}}} as written; did you mean {{{s}}}?", .{ scope.place, key, written, hint });
    for (problem.notes.items) |n| if (eql(u8, n, note)) return;
    try problem.notes.append(a, note);
}

// --- TOML output ---

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

// --- Compiling ---

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

fn paths(a: Allocator, problem: *Problem, step: []const u8, key: []const u8, v: ?toml.Value) Error![]const []const u8 {
    const list = v orelse return &.{};
    if (list != .array) return fail(a, problem, "step {s}: {s} must be a list of paths", .{ step, key });
    const out = try a.alloc([]const u8, list.array.items.len);
    for (list.array.items, out) |item, *p| {
        if (item != .string) return fail(a, problem, "step {s}: {s} must be a list of paths", .{ step, key });
        p.* = item.string;
    }
    return out;
}

fn writeRule(a: Allocator, w: *std.Io.Writer, problem: *Problem, step: *const toml.Table, name: []const u8, scope: Scope) !void {
    var values: std.StringArrayHashMapUnmanaged(toml.Value) = .empty;
    var it = step.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (eql(u8, key, "name") or eql(u8, key, "for_each") or eql(u8, key, "shell")) continue;
        try values.put(a, key, try ruleValue(a, problem, scope, key, e.value_ptr.*));
    }
    if (step.get("shell")) |sh| {
        var s = scope;
        s.input = try paths(a, problem, name, "input", values.get("input"));
        s.output = try paths(a, problem, name, "output", values.get("output"));
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
            if (reserved(col)) return fail(a, problem, "{s}: samples.defaults.{s} has the name of a placeholder kanit prepare fills; rename it", .{ shown, col });
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
        if (rows.items.len == 0) return fail(a, problem, "{s}: samples.names lists no sample", .{shown});
        const cols = try a.alloc([]const u8, 1);
        cols[0] = "sample";
        sheet = try withDefaults(a, .{ .columns = cols, .rows = rows.items, .source = "samples.names" }, defaults);
    } else return fail(a, problem, "{s}: [samples] needs sheet or names", .{shown});
    return sheet;
}

fn addParams(a: Allocator, problem: *Problem, value: ?toml.Value, shown: []const u8, sheet: ?Sheet, params: *std.StringArrayHashMapUnmanaged([]const u8)) Error!void {
    const pv = value orelse return;
    if (pv != .table) return fail(a, problem, "{s}: params must be a table", .{shown});
    var pit = pv.table.iterator();
    while (pit.next()) |e| {
        const name = e.key_ptr.*;
        if (!isIdent(name)) return fail(a, problem, "{s}: param '{s}' must be a name of letters, digits and '_'", .{ shown, name });
        if (reserved(name)) return fail(a, problem, "{s}: param {s} has the name of a placeholder kanit prepare fills; rename it", .{ shown, name });
        if (sheet) |sh| if (sh.column(name) != null) return fail(a, problem, "{s}: param {s} is also a column of {s}", .{ shown, name, sh.source });
        try params.put(a, name, switch (e.value_ptr.*) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i.value}),
            .boolean => |b| if (b) "true" else "false",
            else => return fail(a, problem, "{s}: param {s} must be a string, number or boolean", .{ shown, name }),
        });
    }
}

pub const RunFile = struct { path: []const u8, shown: []const u8 };
const run_keys = [_][]const u8{ "workflow", "samples", "params" };

pub fn compile(gpa: Allocator, a: Allocator, path: []const u8, shown: []const u8, problem: *Problem) Error![]const u8 {
    return compileWith(gpa, a, path, shown, null, problem);
}

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

    const run_samples = if (run_doc) |d| d.get("samples") else null;
    const sheet = try readSamples(gpa, a, run_samples orelse doc.get("samples"), if (run_samples != null) run.?.path else path, if (run_samples != null) run.?.shown else shown, problem);

    var params: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try addParams(a, problem, doc.get("params"), shown, sheet, &params);
    if (run_doc) |d| try addParams(a, problem, d.get("params"), run.?.shown, sheet, &params);

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    if (run) |r| {
        try w.print("# Written by `kanit prepare` from {s} with {s}: edit those files and run it\n# again, since changes made here are lost.\n\n", .{ std.fs.path.basename(shown), std.fs.path.basename(r.shown) });
    } else try w.print("# Written by `kanit prepare` from {s}: edit that file and run it again,\n# since changes made here are lost.\n\n", .{std.fs.path.basename(shown)});
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
        const scope: Scope = .{ .sheet = null, .row = null, .params = &params, .place = name };
        try writeTable(w, name, null, (try ruleValue(a, problem, scope, name, .{ .table = merged })).table);
    }
    for ([_][]const u8{ "resource_groups", "shared" }) |name| if (doc.get(name)) |v| {
        if (v != .table) return fail(a, problem, "{s}: {s} must be a table", .{ shown, name });
        var git = v.table.iterator();
        while (git.next()) |e| {
            if (e.value_ptr.* != .table) return fail(a, problem, "{s}: {s}.{s} must be a table", .{ shown, name, e.key_ptr.* });
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
            if (eql(u8, key, "step") or eql(u8, key, "sample")) return fail(a, problem, "step {s}: {s} is set by kanit prepare; leave it out", .{ name, key });
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

// --- Comparing with the current workflow ---

fn ruleBlocks(a: Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, "\n[[rules]]\n");
    _ = it.next();
    while (it.next()) |block| {
        const line_end = std.mem.indexOfScalar(u8, block, '\n') orelse block.len;
        const first = block[0..line_end];
        const prefix = "name = \"";
        if (!std.mem.startsWith(u8, first, prefix)) continue;
        const end = std.mem.indexOfScalarPos(u8, first, prefix.len, '"') orelse continue;
        try map.put(a, first[prefix.len..end], block);
    }
    return map;
}

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
    if (!eql(u8, head_old, head_new)) {
        try w.writeAll("change: the workflow, defaults, groups or shared inputs\n");
    } else if (added.items.len + removed.items.len + changed.items.len == 0) {
        const reordered = for (was.keys(), now.keys()) |x, y| {
            if (!eql(u8, x, y)) break true;
        } else false;
        try w.writeAll(if (reordered) "change: the order of the rules\n" else "change: blank lines or comments between the rules\n");
    }
    return true;
}

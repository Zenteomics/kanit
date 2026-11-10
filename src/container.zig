//! Container rules through rootless Podman.
//!
//! The attempt process is `podman run` itself, started with conmon in the
//! run's shared containers cgroup; with the cgroupfs manager and the attempt
//! cgroup as parent, the container alone lives in the attempt's cgroup, so
//! its limits, OOM group and counters cover the tool. Images are never pulled.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const process = @import("process.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;

pub fn findPodman(gpa: Allocator, a: Allocator, path_env: []const u8) !?[]const u8 {
    return process.findProgram(gpa, a, path_env, "podman");
}

pub const Unresolved = struct {
    ref: []const u8,
    missing: bool,
    status: u32 = 0,

    pub fn text(self: Unresolved, a: Allocator) ![]const u8 {
        if (self.missing) return std.fmt.allocPrint(a, "container image {s} is not available locally; kanit does not pull images", .{self.ref});
        if (linux.W.IFEXITED(self.status)) return std.fmt.allocPrint(a, "podman image inspect {s} failed with status {d}; run it to see why", .{ self.ref, linux.W.EXITSTATUS(self.status) });
        return std.fmt.allocPrint(a, "podman image inspect {s} failed; run it to see why", .{self.ref});
    }
};

/// One line of `podman image inspect --format '{{.Id}} {{json .RepoDigests}}'`:
/// the image ID, and the image's digests in the registries it came from, as
/// `REPOSITORY@sha256:...`. A locally built image lists its own `localhost/`
/// name, which no registry serves; the reader of a record tells them apart.
pub const Inspected = struct { id: []const u8, digests: []const []const u8 };

/// Null for a line without an ID. A digest list Podman prints as `null`, or
/// that does not parse, reads as empty: the ID alone still names the image.
pub fn parseInspect(a: Allocator, line: []const u8) ?Inspected {
    const text = std.mem.trim(u8, line, " \n");
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const id = text[0..space];
    if (id.len == 0) return null;
    const list = std.mem.trim(u8, text[space..], " ");
    const digests = std.json.parseFromSliceLeaky([]const []const u8, a, list, .{ .allocate = .alloc_always }) catch &.{};
    return .{ .id = id, .digests = digests };
}

/// The image ID of each reference, from one `podman image inspect` each;
/// `digests`, when given, also receives each reference's registry digests.
pub fn resolveImages(gpa: Allocator, a: Allocator, podman: []const u8, refs: []const []const u8, envp: *const process.Vec, devnull: sys.Fd, unresolved: *?Unresolved, digests: ?*std.StringHashMapUnmanaged([]const []const u8)) !std.StringHashMapUnmanaged([]const u8) {
    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (refs) |ref| {
        if (ids.contains(ref)) continue;
        var status: u32 = 0;
        const out = process.capture(gpa, a, &.{ podman, "image", "inspect", "--format", "{{.Id}} {{json .RepoDigests}}", ref }, envp, devnull, &status) catch |err| switch (err) {
            error.CommandFailed => {
                var exists_status: u32 = 0;
                _ = process.capture(gpa, a, &.{ podman, "image", "exists", ref }, envp, devnull, &exists_status) catch {};
                const gone = linux.W.IFEXITED(exists_status) and linux.W.EXITSTATUS(exists_status) == 1;
                unresolved.* = .{ .ref = ref, .missing = gone, .status = status };
                return ids;
            },
            else => return err,
        };
        const image = parseInspect(a, out) orelse {
            unresolved.* = .{ .ref = ref, .missing = true };
            return ids;
        };
        try ids.put(a, ref, try a.dupe(u8, image.id));
        if (digests) |d| try d.put(a, ref, image.digests);
    }
    return ids;
}

pub fn removeLeftovers(gpa: Allocator, a: Allocator, podman: []const u8, root: []const u8, envp: *const process.Vec, devnull: sys.Fd) !usize {
    var status: u32 = 0;
    var found: usize = 0;
    for (0..3) |round| {
        const ids = listLeftovers(gpa, a, podman, root, envp, devnull) catch return found;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ podman, "rm", "--force", "--ignore", "--depend", "--time", "0" });
        const fixed = argv.items.len;
        try argv.appendSlice(a, ids);
        if (argv.items.len == fixed) break;
        if (round == 0) found = argv.items.len - fixed;
        if (round > 0) {
            const pause: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = linux.nanosleep(&pause, null);
        }
        _ = process.capture(gpa, a, argv.items, envp, devnull, &status) catch {};
    }
    return found;
}

pub fn listLeftovers(gpa: Allocator, a: Allocator, podman: []const u8, root: []const u8, envp: *const process.Vec, devnull: sys.Fd) ![]const []const u8 {
    var status: u32 = 0;
    const label = try std.fmt.allocPrint(a, "label=workz.workdir={s}", .{root});
    const out = try process.capture(gpa, a, &.{ podman, "ps", "--all", "--quiet", "--filter", label }, envp, devnull, &status);
    var ids: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, out, " \n");
    while (it.next()) |id| try ids.append(a, id);
    return ids.items;
}

pub fn removeAsync(a: Allocator, podman: []const u8, name: []const u8, envp: *const process.Vec, devnull: sys.Fd) ?linux.pid_t {
    const argv = process.Vec.init(a, &.{ podman, "rm", "--force", "--ignore", "--time", "0", name }) catch return null;
    const path = a.dupeZ(u8, podman) catch return null;
    const spec: process.Spec = .{ .path = path.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = devnull, .stdout = devnull, .stderr = devnull };
    return process.spawn(&spec) catch null;
}

pub const Mount = struct { dir: []const u8, write: bool };

pub fn mounts(a: Allocator, root: []const u8, r: *const workflow.Rule, extra_ro: []const []const u8) ![]Mount {
    var ro: std.ArrayList([]const u8) = .empty;
    try ro.append(a, root);
    for (r.input_abs) |in| {
        if (workflow.within(root, in)) continue;
        try ro.append(a, std.fs.path.dirname(in) orelse "/");
    }
    for (extra_ro) |p| try ro.append(a, p);
    var rw: std.ArrayList([]const u8) = .empty;
    for (r.output_abs) |o| try rw.append(a, std.fs.path.dirname(o) orelse root);
    if (r.workdir_abs) |d| try rw.append(a, d);
    const ro_min = try minimal(a, ro.items);
    const rw_min = try minimal(a, rw.items);
    var out: std.ArrayList(Mount) = .empty;
    for (ro_min) |d| {
        const also_rw = for (rw_min) |w| {
            if (std.mem.eql(u8, w, d)) break true;
        } else false;
        if (!also_rw) try out.append(a, .{ .dir = d, .write = false });
    }
    for (rw_min) |d| try out.append(a, .{ .dir = d, .write = true });
    const rec = try std.fs.path.join(a, &.{ root, ".workz" });
    for (rw_min) |d| if (workflow.within(d, rec)) {
        try out.append(a, .{ .dir = rec, .write = false });
        break;
    };
    return out.items;
}

fn minimal(a: Allocator, dirs: []const []const u8) ![]const []const u8 {
    const sorted = try a.dupe([]const u8, dirs);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    var out: std.ArrayList([]const u8) = .empty;
    for (sorted) |d| {
        const below = for (out.items) |k| {
            if (workflow.within(k, d)) break true;
        } else false;
        if (below) continue;
        try out.append(a, d);
    }
    return out.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const RunSpec = struct {
    podman: []const u8,
    name: []const u8,
    image_id: []const u8,
    root: []const u8,
    launch: []const u8,
    cgroup_parent: ?[]const u8,
    mounts: []const Mount,
    env: []const []const u8,
    ipc_service: ?[]const u8 = null,
    service: bool = false,
    image_mounts: []const workflow.ImageMount = &.{},
    workdir: ?[]const u8 = null,
    script: []const u8,
};

pub fn runArgv(a: Allocator, s: RunSpec) ![]const []const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    try v.appendSlice(a, &.{
        s.podman,                                           "run",
        "--rm",                                             "--pull=never",
        "--name",                                           s.name,
        "--label",                                          try std.fmt.allocPrint(a, "workz.workdir={s}", .{s.root}),
        "--label",                                          try std.fmt.allocPrint(a, "workz.launch={s}", .{s.launch}),
        "--network=none",                                   "--cap-drop=ALL",
        "--security-opt=no-new-privileges",                 "--security-opt=label=disable",
        "--read-only",                                      "--log-driver=none",
        "--init",                                           "--workdir",
        if (s.service) "/tmp" else s.workdir orelse s.root, "--entrypoint",
        "/bin/sh",
    });
    if (s.service) try v.append(a, "--ipc=shareable");
    if (s.cgroup_parent) |cg| try v.appendSlice(a, &.{ "--cgroup-manager=cgroupfs", try std.fmt.allocPrint(a, "--cgroup-parent={s}", .{cg}) });
    if (s.ipc_service) |svc| try v.append(a, try std.fmt.allocPrint(a, "--ipc=container:{s}", .{svc}));
    for (s.mounts) |m| try v.appendSlice(a, &.{ "--volume", try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ m.dir, m.dir, if (m.write) "rw" else "ro" }) });
    for (s.image_mounts) |m| try v.appendSlice(a, &.{ "--volume", try std.fmt.allocPrint(a, "{s}:{s}:ro", .{ m.source_abs, m.target }) });
    for (s.env) |e| try v.appendSlice(a, &.{ "--env", e });
    try v.appendSlice(a, &.{ s.image_id, s.script });
    return v.items;
}

pub fn script(a: Allocator, shell: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "set -eu\nif (set -o pipefail) 2>/dev/null; then set -o pipefail; fi\n{s}\n", .{shell});
}

pub fn serviceScript(a: Allocator, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "set -eu\nif (set -o pipefail) 2>/dev/null; then set -o pipefail; fi\n{{\n{s}\n}} </dev/null >&2\necho ready\nread -r _ < \"$WORKZ_SERVICE_STOP\" || true\n", .{command});
}

pub fn imageRefs(a: Allocator, wf: *const workflow.Workflow, mask: []const bool) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        if (r.container) |img| try refs.append(a, img);
        for (r.shared) |s| if (wf.sharedIndex(s)) |si| if (wf.shared[si].container) |img| try refs.append(a, img);
    }
    return refs.items;
}

pub fn ruleExtras(a: Allocator, wf: *const workflow.Workflow, images: *const std.StringHashMapUnmanaged([]const u8)) ![]const []const u8 {
    const out = try a.alloc([]const u8, wf.rules.len);
    for (wf.rules, out) |r, *e| {
        const img = r.container orelse {
            e.* = "";
            continue;
        };
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("image {s}", .{images.get(img) orelse img});
        for (r.mounts) |m| try w.writer.print(" mount {s} {s}", .{ m.target, workflow.keyPath(wf.root, m.source_abs) });
        for (r.shared) |s| if (wf.sharedIndex(s)) |si| {
            const svc = wf.shared[si];
            const simg = svc.container orelse continue;
            var text_w: std.Io.Writer.Allocating = .init(a);
            try text_w.writer.print("{s}\x00{s}\x00{s}", .{ images.get(simg) orelse simg, svc.command.?, if (svc.path_abs) |p| workflow.keyPath(wf.root, p) else "" });
            for (svc.mounts) |m| try text_w.writer.print("\x00mount {s} {s}", .{ m.target, workflow.keyPath(wf.root, m.source_abs) });
            const text = text_w.written();
            try w.writer.print(" service {s} {s}", .{ svc.name, &sys.sha256Bytes(text) });
        };
        e.* = try w.toOwnedSlice();
    }
    return out;
}

pub fn stopAsync(a: Allocator, podman: []const u8, name: []const u8, grace_s: u64, envp: *const process.Vec, devnull: sys.Fd) ?linux.pid_t {
    const argv = process.Vec.init(a, &.{ podman, "stop", "--ignore", "--time", std.fmt.allocPrint(a, "{d}", .{grace_s}) catch return null, name }) catch return null;
    const path = a.dupeZ(u8, podman) catch return null;
    const spec: process.Spec = .{ .path = path.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = devnull, .stdout = devnull, .stderr = devnull };
    return process.spawn(&spec) catch null;
}

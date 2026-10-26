//! Linux system calls used by the engine: files, identity, clocks, randomness.
//!
//! workz targets Linux only, so these wrappers call `std.os.linux` directly and
//! translate the errno values the engine distinguishes into Zig errors.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Error = error{
    FileNotFound,
    PathAlreadyExists,
    AccessDenied,
    Busy,
    NotDir,
    IsDir,
    NoSpace,
    Interrupted,
    WouldBlock,
    NoChild,
    NoProcess,
    InvalidArgument,
    Unexpected,
};

/// The errno of the last failed call made through `check`, for messages.
pub threadlocal var last_errno: linux.E = .SUCCESS;

pub fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return rc;
    last_errno = e;
    return switch (e) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .BUSY, .NOTEMPTY => error.Busy,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOSPC, .DQUOT => error.NoSpace,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .CHILD => error.NoChild,
        .SRCH => error.NoProcess,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

pub fn errnoName() []const u8 {
    return @tagName(last_errno);
}

/// Copies `path` into a null-terminated buffer owned by `gpa`.
pub fn z(gpa: Allocator, path: []const u8) ![:0]u8 {
    return gpa.dupeZ(u8, path);
}

pub const Fd = i32;

pub fn openRead(gpa: Allocator, path: []const u8) !Fd {
    const p = try z(gpa, path);
    defer gpa.free(p);
    return @intCast(try check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)));
}

/// Creates a FIFO and opens it for reading and writing, which does not wait
/// for a reader. Its readers see end of file once every such descriptor is
/// closed, also when the process holding it dies.
pub fn openFifo(gpa: Allocator, path: []const u8) !Fd {
    const p = try z(gpa, path);
    defer gpa.free(p);
    _ = try check(linux.mknodat(linux.AT.FDCWD, p, linux.S.IFIFO | 0o600, 0));
    return @intCast(try check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0)));
}

pub const WriteMode = enum { truncate, append, exclusive };

pub fn openWrite(gpa: Allocator, path: []const u8, mode: WriteMode) !Fd {
    const p = try z(gpa, path);
    defer gpa.free(p);
    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    switch (mode) {
        .truncate => flags.TRUNC = true,
        .append => flags.APPEND = true,
        .exclusive => flags.EXCL = true,
    }
    return @intCast(try check(linux.openat(linux.AT.FDCWD, p, flags, 0o644)));
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn writeAll(fd: Fd, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = check(linux.write(fd, bytes[done..].ptr, bytes.len - done)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
        done += n;
    }
}

pub fn read(fd: Fd, buf: []u8) !usize {
    while (true) {
        return check(linux.read(fd, buf.ptr, buf.len)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

pub fn fsync(fd: Fd) !void {
    _ = try check(linux.fsync(fd));
}

/// Reads a whole file, refusing files larger than `limit` bytes.
pub fn readFile(gpa: Allocator, path: []const u8, limit: usize) ![]u8 {
    const fd = try openRead(gpa, path);
    defer close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > limit) return error.FileTooBig;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

/// Returns at most the last `max` bytes of a file, or an empty slice if it is missing.
pub fn readTail(gpa: Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = openRead(gpa, path) catch |err| switch (err) {
        error.FileNotFound => return gpa.alloc(u8, 0),
        else => return err,
    };
    defer close(fd);
    const size = (try statFd(fd)).size;
    const start = if (size > max) size - max else 0;
    const len: usize = @intCast(size - start);
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    var done: usize = 0;
    while (done < len) {
        const n = try check(linux.pread(fd, out[done..].ptr, len - done, @intCast(start + done)));
        if (n == 0) break;
        done += n;
    }
    return out[0..done];
}

/// Writes `bytes` to `path` through a temporary file, fsync and rename, then
/// fsyncs the directory, so readers see either the old or the new file.
pub fn writeFileAtomic(gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    {
        const fd = try openWrite(gpa, tmp, .truncate);
        defer close(fd);
        try writeAll(fd, bytes);
        try fsync(fd);
    }
    try rename(gpa, tmp, path);
    try fsyncDir(gpa, std.fs.path.dirname(path) orelse ".");
}

/// Atomic replacement without fsync: readers never see a partial file, but a
/// power loss may lose the newest version. For records, not for resume state.
pub fn writeFileReplace(gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try writeFile(gpa, tmp, bytes);
    try rename(gpa, tmp, path);
}

pub fn writeFile(gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const fd = try openWrite(gpa, path, .truncate);
    defer close(fd);
    try writeAll(fd, bytes);
}

pub fn fsyncDir(gpa: Allocator, path: []const u8) !void {
    const p = try z(gpa, path);
    defer gpa.free(p);
    const fd: Fd = @intCast(try check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)));
    defer close(fd);
    try fsync(fd);
}

pub fn rename(gpa: Allocator, from: []const u8, to: []const u8) !void {
    const a = try z(gpa, from);
    defer gpa.free(a);
    const b = try z(gpa, to);
    defer gpa.free(b);
    _ = try check(linux.renameat(linux.AT.FDCWD, a, linux.AT.FDCWD, b));
}

pub fn mkdir(gpa: Allocator, path: []const u8) !void {
    const p = try z(gpa, path);
    defer gpa.free(p);
    _ = check(linux.mkdirat(linux.AT.FDCWD, p, 0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Creates `path` and every missing parent. The common case, an existing
/// parent, costs one call.
pub fn mkdirAll(gpa: Allocator, path: []const u8) !void {
    const p = try z(gpa, path);
    defer gpa.free(p);
    _ = check(linux.mkdirat(linux.AT.FDCWD, p, 0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try mkdirAll(gpa, parent);
            return mkdir(gpa, path);
        },
        else => return err,
    };
}

pub fn rmdir(gpa: Allocator, path: []const u8) !void {
    const p = try z(gpa, path);
    defer gpa.free(p);
    _ = try check(linux.unlinkat(linux.AT.FDCWD, p, linux.AT.REMOVEDIR));
}

/// File identity used for resume decisions: inode, size, and the
/// modification and change times in nanoseconds. A change time cannot be set
/// back by user programs, so a rewrite that restores mtime is still detected.
/// The device number tells files apart within one launch, such as two paths
/// that are hard links to one file, but is left out of the recorded text
/// (`format`): btrfs numbers its subvolumes anew at each mount, so a
/// recorded device number would change with every reboot.
pub const Identity = struct {
    dev: u64,
    ino: u64,
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
    mode: u32,

    pub fn isDir(self: Identity) bool {
        return self.mode & 0o170000 == 0o040000;
    }

    pub fn isReg(self: Identity) bool {
        return self.mode & 0o170000 == 0o100000;
    }

    pub fn format(self: Identity, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}:{d}:{d}", .{ self.ino, self.size, self.mtime_ns, self.ctime_ns });
    }
};

fn toNs(t: linux.statx_timestamp) i128 {
    return @as(i128, t.sec) * std.time.ns_per_s + t.nsec;
}

const statx_mask: linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true, .NLINK = true };

fn fromStatx(s: linux.Statx) Identity {
    return .{
        .dev = (@as(u64, s.dev_major) << 32) | s.dev_minor,
        .ino = s.ino,
        .size = s.size,
        .mtime_ns = toNs(s.mtime),
        .ctime_ns = toNs(s.ctime),
        .mode = s.mode,
    };
}

/// Identity of `path`, following symlinks; null when it does not exist.
pub fn stat(gpa: Allocator, path: []const u8) !?Identity {
    const p = try z(gpa, path);
    defer gpa.free(p);
    var s: linux.Statx = undefined;
    _ = check(linux.statx(linux.AT.FDCWD, p, 0, statx_mask, &s)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return fromStatx(s);
}

/// Identity of `path` itself, not following a final symlink.
pub fn lstat(gpa: Allocator, path: []const u8) !?Identity {
    const p = try z(gpa, path);
    defer gpa.free(p);
    var s: linux.Statx = undefined;
    _ = check(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, statx_mask, &s)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return fromStatx(s);
}

pub fn statFd(fd: Fd) !Identity {
    var s: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, statx_mask, &s));
    return fromStatx(s);
}

pub fn exists(gpa: Allocator, path: []const u8) bool {
    return (lstat(gpa, path) catch null) != null;
}

pub fn realNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn monoNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Writes an RFC 3339 UTC timestamp with milliseconds for `ns` since the epoch.
pub fn formatTime(w: *std.Io.Writer, ns: i128) !void {
    const secs: u64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    const ms: u64 = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_ms));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), ms,
    });
}

pub fn randomBytes(buf: []u8) void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = check(linux.getrandom(buf[done..].ptr, buf.len - done, 0)) catch continue;
        done += n;
    }
}

pub const Digest = [64]u8;

/// SHA-256 of a file's bytes as lowercase hex.
pub fn sha256File(gpa: Allocator, path: []const u8) !Digest {
    const fd = try openRead(gpa, path);
    defer close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    while (true) {
        const n = try read(fd, buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

pub fn sha256Bytes(bytes: []const u8) Digest {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
}

/// Absolute path of the running executable.
pub fn selfExe(gpa: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try check(linux.readlinkat(linux.AT.FDCWD, "/proc/self/exe", &buf, buf.len));
    return gpa.dupe(u8, buf[0..n]);
}

pub fn cwd(gpa: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try check(linux.getcwd(&buf, buf.len));
    // getcwd returns the length including the terminating zero.
    return gpa.dupe(u8, buf[0 .. n - 1]);
}

/// Resolves `path` against `base` and removes `.` and `..` components
/// lexically; symlinks are not followed.
pub fn absolute(gpa: Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(gpa, &.{path});
    return std.fs.path.resolve(gpa, &.{ base, path });
}

/// Resolves symlinks in `path` through /proc, for alias checks.
pub fn realpath(gpa: Allocator, path: []const u8) !?[]u8 {
    const p = try z(gpa, path);
    defer gpa.free(p);
    const fd = check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer close(@intCast(fd));
    var link: [64]u8 = undefined;
    const proc = try std.fmt.bufPrintZ(&link, "/proc/self/fd/{d}", .{fd});
    var buf: [4096]u8 = undefined;
    const n = try check(linux.readlinkat(linux.AT.FDCWD, proc, &buf, buf.len));
    return try gpa.dupe(u8, buf[0..n]);
}

/// The entries of an open directory, without "." and "..", read with
/// getdents64. An entry's name lives in the reader's buffer until the next
/// call of `next`.
pub const DirEntries = struct {
    fd: Fd,
    buf: [16384]u8 align(8) = undefined,
    n: usize = 0,
    off: usize = 0,

    /// `kind` is the d_type byte: 4 for a directory, 8 for a regular file,
    /// 10 for a symlink, 0 when the file system does not say.
    pub const Entry = struct { name: []const u8, kind: u8 };

    pub fn next(self: *DirEntries) Error!?Entry {
        while (true) {
            if (self.off >= self.n) {
                self.n = try check(linux.getdents64(self.fd, &self.buf, self.buf.len));
                self.off = 0;
                if (self.n == 0) return null;
            }
            const reclen = std.mem.readInt(u16, self.buf[self.off + 16 ..][0..2], .little);
            const kind = self.buf[self.off + 18];
            const name = std.mem.sliceTo(self.buf[self.off + 19 .. self.off + reclen], 0);
            self.off += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = kind };
        }
    }
};

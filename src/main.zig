const std = @import("std");
const c = std.c;
const posix = std.posix;
const Io = std.Io;

// Not exposed publicly by std.c.
extern "c" fn mkfifo(path: [*:0]const u8, mode: c.mode_t) c_int;
extern "c" fn fork() c_int;
extern "c" fn close(fd: c.fd_t) c_int;
extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// Printed instead of a FIFO path when coloring is disabled or setup fails,
/// so the wrapped command still runs and its output still reaches the screen.
const fallback = "/dev/stderr";

/// How long the listener waits for the shell to open the FIFO before giving up.
const open_timeout_s = 10;

const reset = "\x1b[0m";
const read_size = 4096;
const max_prefix = 32;
// Worst case every 3-byte "\x1b[m" in a chunk expands to reset + prefix.
const out_size = max_prefix + (read_size / 3 + 1) * (reset.len + max_prefix) + reset.len;

const usage =
    \\usage: cmd 2>$(staind [-b] [-d] [color])
    \\
    \\Prints the path of a fresh FIFO. Anything written to it is colored
    \\and echoed to the terminal. The default color is red.
    \\
    \\colors:
    \\  black red green yellow blue magenta cyan white
    \\  bright-<name>, gray
    \\  0-255      xterm 256-color index
    \\  #rrggbb    truecolor
    \\
    \\options:
    \\  -b         bold
    \\  -d         dim
    \\  -h         show this help
    \\
    \\Set NO_COLOR to pass output through uncolored.
    \\
;

const Options = struct {
    color: []const u8 = "red",
    bold: bool = false,
    dim: bool = false,
};

pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| {
        std.debug.print("staind: {s}\n", .{errorMessage(err)});
        printPath(fallback);
        std.process.exit(1);
    };
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownColor => "unknown color (see staind -h)",
        error.InvalidOption => "unknown option (see staind -h)",
        error.NoTerminal => "no terminal to write to",
        else => @errorName(err),
    };
}

fn run(init: std.process.Init.Minimal) !void {
    const options = try parseOptions(init.args);

    var prefix_buf: [max_prefix]u8 = undefined;
    const prefix = try getStaindPrefix(options, &prefix_buf);

    if (init.environ.getPosix("NO_COLOR")) |v| if (v.len > 0) {
        printPath(fallback);
        return;
    };

    const tty = c.open("/dev/tty", .{ .ACCMODE = .WRONLY, .NOCTTY = true });
    if (tty < 0) return error.NoTerminal;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try getStaindDir(init.environ, &dir_buf);
    if (c.mkdir(dir, 0o700) != 0) return error.MkdirFailed;
    errdefer _ = c.rmdir(dir);

    var fifo_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&fifo_buf, "{s}/fifo", .{dir}, 0);
    if (mkfifo(fifo, 0o600) != 0) return error.MkfifoFailed;
    errdefer _ = c.unlink(fifo);

    switch (fork()) {
        -1 => return error.ForkFailed,
        0 => listen(tty, fifo, dir, prefix),
        else => printPath(fifo),
    }
}

fn getStaindDir(env: std.process.Environ, dir_buf: []u8) ![:0]const u8 {
    var rand: [8]u8 = undefined;
    arc4random_buf(&rand, rand.len);
    const tmp = std.mem.trimEnd(
        u8,
        env.getPosix("TMPDIR") orelse "/tmp",
        "/",
    );
    return std.mem.printSentinel(
        dir_buf,
        "{s}/staind.{s}",
        .{ tmp, std.fmt.bytesToHex(rand, .lower) },
        0,
    );
}

fn getStaindPrefix(options: Options, prefix_buf: []u8) ![]const u8 {
    var code_buf: [24]u8 = undefined;
    const code = try colorCode(&code_buf, options.color);
    const prefix = try std.mem.print(prefix_buf, "\x1b[{s}{s}{s}m", .{
        if (options.bold) "1;" else "",
        if (options.dim) "2;" else "",
        code,
    });
    return prefix;
}

fn parseOptions(args: std.process.Args) !Options {
    var options = Options{};
    var it = args.iterate();
    _ = it.skip(); // skip program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-b")) {
            options.bold = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            options.dim = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return error.InvalidOption;
        } else {
            options.color = arg;
        }
    }
    return options;
}

fn printPath(path: []const u8) void {
    writeAll(posix.STDOUT_FILENO, path) catch {};
    writeAll(posix.STDOUT_FILENO, "\n") catch {};
}

fn listen(
    tty: c.fd_t,
    fifo: [:0]const u8,
    dir: [:0]const u8,
    prefix: []const u8,
) noreturn {
    // Let go of the $(...) pipe so the shell's command substitution finishes.
    const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (devnull < 0) std.process.exit(1);
    for ([_]c.fd_t{ 0, 1, 2 }) |fd| _ = c.dup2(devnull, fd);
    if (devnull > 2) _ = close(devnull);

    // We share the job's process group. Survive ^C, ^\ and ^Z so we can drain
    // the command's last words; we exit on EOF once it is gone. Survive hangup
    // too so we always get to clean up the FIFO; if the terminal is really
    // gone, the next write fails and we exit.
    const ignore = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{
        .HUP,
        .INT,
        .QUIT,
        .TSTP,
        .TTOU,
    }) |sig| posix.sigaction(sig, &ignore, null);

    // No SA_RESTART, so a blocked open() returns EINTR when the alarm fires.
    const on_alarm = posix.Sigaction{
        .handler = .{ .handler = onAlarm },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.ALRM, &on_alarm, null);
    _ = c.alarm(open_timeout_s);
    const fd = c.open(fifo, .{ .ACCMODE = .RDONLY });
    _ = c.alarm(0);

    _ = c.unlink(fifo);
    _ = c.rmdir(dir);
    if (fd < 0) std.process.exit(1);

    var in: [read_size]u8 = undefined;
    var out: [out_size]u8 = undefined;
    while (true) {
        const n = c.read(fd, &in, in.len);
        if (n < 0 and posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        writeAll(tty, colorize(&out, prefix, in[0..@intCast(n)])) catch break;
    }
    std.process.exit(0);
}

fn onAlarm(_: posix.SIG) callconv(.c) void {}

/// Wraps `chunk` in `prefix` ... reset, re-applying `prefix` after any reset
/// inside the chunk so the program's own escapes don't cancel the color.
/// A reset split across two reads is not caught; that is rare and harmless.
fn colorize(out: []u8, prefix: []const u8, chunk: []const u8) []const u8 {
    var n: usize = 0;
    const append = struct {
        fn f(buf: []u8, len: *usize, s: []const u8) void {
            @memcpy(buf[len.*..][0..s.len], s);
            len.* += s.len;
        }
    }.f;

    append(out, &n, prefix);
    var i: usize = 0;
    while (i < chunk.len) {
        const rest = chunk[i..];
        if (std.mem.startsWith(u8, rest, "\x1b[0m") or std.mem.startsWith(u8, rest, "\x1b[m")) {
            const len: usize = if (rest[2] == 'm') 3 else 4;
            append(out, &n, rest[0..len]);
            append(out, &n, prefix);
            i += len;
        } else {
            out[n] = chunk[i];
            n += 1;
            i += 1;
        }
    }
    append(out, &n, reset);
    return out[0..n];
}

/// Translates a color name, 256-color index, or #rrggbb into SGR parameters.
///
/// See https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797 for the
/// color names, and https://en.wikipedia.org/wiki/ANSI_escape_code#8-bit for
/// the 256-color index.
fn colorCode(buf: []u8, name: []const u8) ![]const u8 {
    // Order matters here. The first 8 are the standard colors, the next 8 are the bright versions.
    const names = [_][]const u8{
        "black",
        "red",
        "green",
        "yellow",
        "blue",
        "magenta",
        "cyan",
        "white",
    };

    // Use bright black for gray/grey ("a" for us here in 'merica).
    if (std.mem.eql(u8, name, "gray") or std.mem.eql(u8, name, "grey")) {
        return "90";
    }

    const bright = std.mem.startsWith(u8, name, "bright-");
    const base_name = if (bright) name["bright-".len..] else name;
    for (names, 0..) |candidate, i| {
        if (std.mem.eql(u8, base_name, candidate)) {
            return std.mem.print(
                buf,
                "{d}",
                .{@as(usize, if (bright) 90 else 30) + i},
            );
        }
    }
    // If the name is not recognized, we don't try to guess a bright version of it.
    if (bright) {
        return error.UnknownColor;
    }

    // Hex color code, e.g. #B00B00
    if (name.len == 7 and name[0] == '#') {
        const r = std.fmt.parseInt(u8, name[1..3], 16) catch return error.UnknownColor;
        const g = std.fmt.parseInt(u8, name[3..5], 16) catch return error.UnknownColor;
        const b = std.fmt.parseInt(u8, name[5..7], 16) catch return error.UnknownColor;
        return std.mem.print(buf, "38;2;{d};{d};{d}", .{ r, g, b });
    }

    // 256-color index, e.g. 208
    const index = std.fmt.parseInt(u8, name, 10) catch return error.UnknownColor;
    return std.mem.print(buf, "38;5;{d}", .{index});
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        i += @intCast(n);
    }
}

test colorCode {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("31", try colorCode(&buf, "red"));
    try std.testing.expectEqualStrings("96", try colorCode(&buf, "bright-cyan"));
    try std.testing.expectEqualStrings("90", try colorCode(&buf, "gray"));
    try std.testing.expectEqualStrings("38;5;208", try colorCode(&buf, "208"));
    try std.testing.expectEqualStrings("38;2;255;0;128", try colorCode(&buf, "#ff0080"));
    try std.testing.expectError(error.UnknownColor, colorCode(&buf, "chartreuse"));
    try std.testing.expectError(error.UnknownColor, colorCode(&buf, "bright-gray"));
    try std.testing.expectError(error.UnknownColor, colorCode(&buf, "256"));
    try std.testing.expectError(error.UnknownColor, colorCode(&buf, "#ff00"));
}

test colorize {
    var out: [out_size]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[31moops\n\x1b[0m", colorize(&out, "\x1b[31m", "oops\n"));
    try std.testing.expectEqualStrings(
        "\x1b[31ma\x1b[0m\x1b[31mb\x1b[m\x1b[31mc\x1b[0m",
        colorize(&out, "\x1b[31m", "a\x1b[0mb\x1b[mc"),
    );
}

test "worst case fits" {
    var in: [read_size]u8 = undefined;
    for (0..read_size) |i| in[i] = "\x1b[m"[i % 3];
    var out: [out_size]u8 = undefined;
    _ = colorize(&out, "\x1b[1;2;38;2;255;255;255m", &in);
}

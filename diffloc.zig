const std = @import("std");
const Term = std.ChildProcess.Term;
const Allocator = std.mem.Allocator;
const splitAny = std.mem.splitAny;
const parseInt = std.fmt.parseInt;

inline fn wrapStyle(style: [2][]const u8) [2][]const u8 {
    return [_][]const u8{ "\u{001B}[" ++ style[0] ++ "m", "\u{001B}[" ++ style[1] ++ "m" };
}

const red = wrapStyle([_][]const u8{ "31", "39" });
const green = wrapStyle([_][]const u8{ "32", "39" });

fn lineCount(f: *const std.fs.File) !u32 {
    var sum: u32 = 0;
    var buf_reader = std.io.bufferedReader(f.reader());
    var stream = buf_reader.reader();

    while (true) {
        const byte = stream.readByte() catch |err| switch (err) {
            error.EndOfStream => {
                sum += 1;
                break;
            },
            else => |e| return e,
        };
        if (byte == '\n') {
            sum += 1;
        }
    }

    return sum;
}

fn diffNewFiles(allocator: *const Allocator) !u32 {
    var sum: u32 = 0;

    const argv = [_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" };
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator.*,
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != Term.Exited) {
        @panic("git diff failed");
    }

    var files_it = splitAny(u8, result.stdout, "\n");
    while (files_it.next()) |line| {
        if (line.len == 0) {
            break;
        }
        const f = std.fs.cwd().openFile(line, .{}) catch {
            std.debug.panic("could not open {s}", .{line});
        };
        defer f.close();
        sum += try lineCount(&f);
    }

    return sum;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        // fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) @panic("leak");
    }
    const allocator = gpa.allocator();

    const argv = [_][]const u8{ "git", "diff", "--numstat" };
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != Term.Exited) {
        @panic("git diff failed");
    }

    var add: u32 = 0;
    var rm: u32 = 0;

    // go through every line of changed files
    var it = splitAny(u8, result.stdout, "\n");
    while (it.next()) |line| {
        // exit on new line
        if (line.len == 0) {
            break;
        }
        var line_it = splitAny(u8, line, "\t");

        var f_add = line_it.next() orelse @panic("invalid git diff response");
        var f_add_int = try parseInt(u32, f_add, 10);

        var f_rm = line_it.next() orelse @panic("invalid git diff response");
        var f_rm_int = try parseInt(u32, f_rm, 10);

        add += f_add_int;
        rm += f_rm_int;
    }

    add += try diffNewFiles(&allocator);

    const stdout = std.io.getStdOut().writer();

    try stdout.print("{s}+{d}{s} {s}-{d}{s}\n", .{ green[0], add, green[1], red[0], rm, red[1] });
}

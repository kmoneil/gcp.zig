//! Fails the build when the gnarl on the PATH is not the release CI
//! installs. Two gnarl releases can count the same function differently
//! (0.4.0 stopped counting a function's return type, 0.5.0 stopped
//! holding a flat dispatch to a cyclomatic limit), so a commit could pass
//! `zig build test` here and fail it in CI, or the other way round. The pin
//! is the `install gnarl v...` line of .github/actions/vet-tools/action.yml,
//! written once, beside the digests it goes with.
//!
//!     vet_pin TOOL ACTION_YML VERSION_FILE
//!
//! VERSION_FILE holds what `TOOL --version` printed. build.zig runs this
//! before the complexity step, when that step runs: build.zig ships in the
//! package and .github does not, so the pin is read here rather than while
//! the build is configured. Silent when the versions agree.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) fail("usage: vet_pin TOOL ACTION_YML VERSION_FILE", .{});
    const tool = args[1];
    const action = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 20));
    const printed = try std.Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(4096));
    const pinned = pin(action, tool) orelse
        fail("{s} has no `install {s} v...` line to judge it by", .{ args[2], tool });
    const found = std.mem.trim(u8, printed, " \t\r\n");
    if (agrees(found, tool, pinned)) return;
    fail(
        \\the {s} on the PATH says "{s}", but CI installs {s} {s} ({s}).
        \\Two releases can count the same function differently, so this build and CI
        \\would judge it apart. Install {s} {s} (a binary from its release, or Homebrew
        \\while its tap has that release), or move the pin in one change: the version
        \\and its digests there, and `{s} --update-baseline .` run with the new release.
    , .{ tool, found, tool, pinned, args[2], tool, pinned, tool });
}

/// The version on the action's `install TOOL vX.Y.Z` line, without its
/// `v`, or null when no line installs TOOL.
fn pin(action: []const u8, tool: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, action, '\n');
    while (lines.next()) |raw| {
        // A checkout with CRLF endings leaves a \r on each line.
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.cutPrefix(u8, line, "install ") orelse continue;
        var words = std.mem.tokenizeScalar(u8, rest, ' ');
        const name = words.next() orelse continue;
        const version = words.next() orelse continue;
        if (words.next() != null or !std.mem.eql(u8, name, tool)) continue;
        return std.mem.cutPrefix(u8, version, "v") orelse continue;
    }
    return null;
}

/// Whether `TOOL --version`, trimmed, names the pinned release: "gnarl 0.5.0".
fn agrees(found: []const u8, tool: []const u8, pinned: []const u8) bool {
    const rest = std.mem.cutPrefix(u8, found, tool) orelse return false;
    const version = std.mem.cutPrefix(u8, rest, " ") orelse return false;
    return std.mem.eql(u8, version, pinned);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("vet_pin: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const testing = std.testing;

test "pin: the release the action installs, for each tool" {
    const action =
        \\        install() {
        \\          local name=$1 version=$2 want
        \\        }
        \\        install zigvet v0.24.0
        \\        install gnarl v0.5.0
        \\
    ;
    try testing.expectEqualStrings("0.5.0", pin(action, "gnarl").?);
    try testing.expectEqualStrings("0.24.0", pin(action, "zigvet").?);
    try testing.expect(pin(action, "kcov") == null);
}

test "pin: CRLF lines, and lines that only look like an install" {
    try testing.expectEqualStrings("0.5.0", pin("x\r\n  install gnarl v0.5.0\r\n", "gnarl").?);
    try testing.expect(pin("install gnarl 0.5.0\n", "gnarl") == null);
    try testing.expect(pin("install gnarl v0.5.0 extra\n", "gnarl") == null);
    try testing.expect(pin("# install gnarl v0.5.0\n", "gnarl") == null);
    try testing.expect(pin("install gnarlish v0.5.0\n", "gnarl") == null);
}

test "agrees: only the pinned release, as --version prints it" {
    try testing.expect(agrees("gnarl 0.5.0", "gnarl", "0.5.0"));
    try testing.expect(!agrees("gnarl 0.4.0", "gnarl", "0.5.0"));
    try testing.expect(!agrees("gnarl 0.5.0-dev", "gnarl", "0.5.0"));
    try testing.expect(!agrees("zigvet 0.5.0", "gnarl", "0.5.0"));
    try testing.expect(!agrees("", "gnarl", "0.5.0"));
}

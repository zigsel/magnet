const std = @import("std");

// magnet - generic, zero-allocation UDP game-networking stack.
// Layered module graph: edges below ARE the allowed dependency direction, so the
// downward-only layering (`proto` never imports `runtime`, `config` never imports `proto`, …)
// is enforced by the *compiler* - a layer module physically cannot import what it doesn't list.
//   config ← trace        core (leaf)        wire (leaf)
//   magnet (root.zig) ← core, wire, config, trace   (proto/replication/runtime files live here)
const Graph = struct { magnet: *std.Build.Module, runs: [8]*std.Build.Step };

fn buildGraph(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, register: bool) Graph {
    const mk = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        fn m(self: @This(), path: []const u8) *std.Build.Module {
            return self.b.createModule(.{ .root_source_file = self.b.path(path), .target = self.target, .optimize = self.optimize });
        }
    }{ .b = b, .target = target, .optimize = optimize };

    // leaves
    const trace_mod = mk.m("src/trace.zig");
    const config_mod = mk.m("src/config.zig");
    config_mod.addImport("trace", trace_mod);
    const core_mod = mk.m("src/core/core.zig");
    const wire_mod = mk.m("src/wire/wire.zig");
    // L1–L3 protocol core
    const proto_mod = mk.m("src/proto/proto.zig");
    proto_mod.addImport("core", core_mod);
    proto_mod.addImport("wire", wire_mod);
    proto_mod.addImport("config", config_mod);
    proto_mod.addImport("trace", trace_mod);
    // L5 replication
    const repl_mod = mk.m("src/replication/replication.zig");
    repl_mod.addImport("core", core_mod);
    repl_mod.addImport("wire", wire_mod);
    // L0 runtime (top)
    const rt_mod = mk.m("src/runtime/runtime.zig");
    rt_mod.addImport("core", core_mod);
    rt_mod.addImport("config", config_mod);
    rt_mod.addImport("proto", proto_mod);

    const magnet = if (register)
        b.addModule("magnet", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize })
    else
        mk.m("src/root.zig");
    magnet.addImport("core", core_mod);
    magnet.addImport("wire", wire_mod);
    magnet.addImport("config", config_mod);
    magnet.addImport("trace", trace_mod);
    magnet.addImport("proto", proto_mod);
    magnet.addImport("replication", repl_mod);
    magnet.addImport("runtime", rt_mod);

    var runs: [8]*std.Build.Step = undefined;
    const mods = [_]*std.Build.Module{ core_mod, wire_mod, config_mod, trace_mod, proto_mod, repl_mod, rt_mod, magnet };
    for (mods, 0..) |m, i| runs[i] = &b.addRunArtifact(b.addTest(.{ .root_module = m })).step;
    return .{ .magnet = magnet, .runs = runs };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- mechanical rule enforcement (style / scope / imports) - now a backup to the
    // module graph, which already makes upward imports impossible to compile. ----
    const enforce_run = b.addSystemCommand(&.{ "sh", "-c", enforce_script });
    enforce_run.has_side_effects = true;
    const enforce_step = b.step("enforce", "Mechanically enforce layering + style rules");
    enforce_step.dependOn(&enforce_run.step);

    const g = buildGraph(b, target, optimize, true);

    const test_step = b.step("test", "Run all unit + integration tests");
    for (g.runs) |r| {
        r.dependOn(&enforce_run.step);
        test_step.dependOn(r);
    }

    const check_step = b.step("check", "Type-check the library");
    check_step.dependOn(&b.addTest(.{ .root_module = g.magnet }).step);

    // ---- API documentation (autodoc HTML from the `///` doc comments) ----
    const docs_obj = b.addObject(.{ .name = "magnet", .root_module = g.magnet });
    const docs_step = b.step("docs", "Generate API docs → zig-out/docs/ (open index.html)");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // ---- example recipes ----
    const examples = [_][]const u8{
        "echo",          "channels",      "typed_messages",   "serialize",
        "congestion",    "big_transfer",  "encrypted",        "connect_tokens",
        "cert_identity", "migration",     "udp_server",       "sharded_server",
        "discovery",     "observability", "replicate",        "fps",
        "interpolation", "mmo_interest",  "client_authority", "entity_refs",
        "lockstep_rts",  "p2p_rollback",  "nat_punch",
    };
    const examples_step = b.step("examples", "Build all example recipes");
    inline for (examples) |name| {
        const exe_mod = b.createModule(.{ .root_source_file = b.path("examples/" ++ name ++ ".zig"), .target = target, .optimize = optimize });
        exe_mod.addImport("magnet", g.magnet);
        const exe = b.addExecutable(.{ .name = name, .root_module = exe_mod });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
        run_step.dependOn(&b.addRunArtifact(exe).step);
    }

    // ---- perf: run the benchmark recipes in ReleaseFast ----
    const bench_step = b.step("bench", "Run the perf benchmarks (ReleaseFast)");
    inline for (.{ "bench_throughput", "bench_spatial" }) |name| {
        const bm = b.createModule(.{ .root_source_file = b.path("examples/" ++ name ++ ".zig"), .target = target, .optimize = .ReleaseFast });
        bm.addImport("magnet", buildGraph(b, target, .ReleaseFast, false).magnet);
        const exe = b.addExecutable(.{ .name = name ++ "-bench", .root_module = bm });
        bench_step.dependOn(&b.addRunArtifact(exe).step);
    }

    // ---- CI: the full suite across the optimize matrix ----
    const matrix_step = b.step("test-matrix", "Run all tests across Debug/ReleaseSafe/ReleaseFast/ReleaseSmall");
    for (g.runs) |r| matrix_step.dependOn(r); // Debug
    inline for (.{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        const mg = buildGraph(b, target, mode, false);
        for (mg.runs) |r| {
            r.dependOn(&enforce_run.step);
            matrix_step.dependOn(r);
        }
    }

    const ci_step = b.step("ci", "enforce + test-matrix + examples (the release gate)");
    ci_step.dependOn(matrix_step);
    ci_step.dependOn(examples_step);
}

// Layer import rules. (The module graph already enforces the cross-layer direction; this
// also bans `usingnamespace` and catches stray relative imports that skip a module.)
const enforce_script =
    \\viol=0
    \\check() {
    \\  d="$1"; shift
    \\  for pat in "$@"; do
    \\    m=$(grep -rn "@import(\"[^\"]*$pat" "$d" 2>/dev/null)
    \\    if [ -n "$m" ]; then echo "IMPORT VIOLATION: $d may not import '$pat'"; echo "$m"; viol=1; fi
    \\  done
    \\}
    \\check src/core   wire/ proto/ runtime/ replication/
    \\check src/wire    proto/ runtime/ replication/
    \\check src/proto   runtime/ replication/
    \\check src/replication runtime/
    \\if grep -rn "usingnamespace" src 2>/dev/null | grep -q .; then
    \\  echo "STYLE VIOLATION: usingnamespace is banned"; grep -rn "usingnamespace" src; viol=1
    \\fi
    \\if [ "$viol" != "0" ]; then echo "enforce: FAILED"; exit 1; fi
    \\echo "enforce: layering + style OK"
;

"""Generate Elixir modules from proto_library targets.

protoc and the protoc-gen-elixir plugin arrive through a toolchain, matching how every other
language's proto support is wired: the plugin is built from the `protobuf` Hex package, whose
repository name only the consumer knows.

Output is a directory, not a fixed file list. protoc derives each file name from the proto's
package and message names, so the set is not knowable at analysis time; elixir_library accepts
a directory of sources for exactly this reason.

Only the target's DIRECT sources are generated. Transitive protos are passed for descriptor
resolution and nothing more -- generating for them too would define the same modules in two
libraries, and the second one to load wins.
"""

load("@rules_proto//proto:defs.bzl", "ProtoInfo")

ElixirProtoToolchainInfo = provider(
    doc = "protoc and the Elixir plugin.",
    fields = {
        "protoc": "The protoc executable.",
        "plugin": "The protoc-gen-elixir escript.",
    },
)

def _toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        proto = ElixirProtoToolchainInfo(
            protoc = ctx.executable.protoc,
            # FilesToRunProvider, not the File: protoc execs the plugin directly, so Bazel has
            # to stage its runfiles tree -- which is where the plugin finds OTP.
            plugin = ctx.attr.plugin[DefaultInfo].files_to_run,
        ),
    )]

elixir_proto_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "protoc": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
        "plugin": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "protoc-gen-elixir, normally an elixir_escript over the protobuf package.",
        ),
    },
)

_TOOLCHAIN = "//:elixir_proto_toolchain_type"

def _impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].proto

    out = ctx.actions.declare_directory(ctx.label.name)

    # direct_sources is a list; the other two are depsets.
    direct = []
    for dep in ctx.attr.deps:
        direct.extend(dep[ProtoInfo].direct_sources)
    transitive = depset(transitive = [
        dep[ProtoInfo].transitive_sources
        for dep in ctx.attr.deps
    ])
    proto_paths = depset(transitive = [
        dep[ProtoInfo].transitive_proto_path
        for dep in ctx.attr.deps
    ])

    plugin_opts = []
    if ctx.attr.grpc:
        plugin_opts.append("plugins=grpc")
    if ctx.attr.module_prefix:
        plugin_opts.append("module_prefix=" + ctx.attr.module_prefix)

    args = ctx.actions.args()
    args.add("--plugin=protoc-gen-elixir=" + toolchain.plugin.executable.path)
    args.add_all(proto_paths, format_each = "--proto_path=%s")
    elixir_out = out.path
    if plugin_opts:
        elixir_out = ",".join(plugin_opts) + ":" + out.path
    args.add("--elixir_out=" + elixir_out)
    args.add_all(direct)

    ctx.actions.run(
        executable = toolchain.protoc,
        arguments = [args],
        inputs = depset(transitive = [transitive]),
        tools = [toolchain.plugin],
        outputs = [out],
        mnemonic = "ElixirProtoc",
        progress_message = "Generating Elixir sources for %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([out]))]

elixir_proto_library = rule(
    implementation = _impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            providers = [ProtoInfo],
        ),
        "grpc": attr.bool(
            default = False,
            doc = "Emit the <Pkg>.<Service>.Service behaviour and client stub.",
        ),
        "module_prefix": attr.string(
            doc = "Prefix for generated module names. Empty means package-derived.",
        ),
    },
    toolchains = [_TOOLCHAIN],
)

load(
    "@rules_erlang//private:erlang_build.bzl",
    "OtpInfo",
)
load(
    ":elixir_build.bzl",
    "ElixirInfo",
)

def _impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        otpinfo = ctx.attr.elixir[OtpInfo],
        elixirinfo = ctx.attr.elixir[ElixirInfo],
    )
    return [toolchain_info]

elixir_toolchain = rule(
    implementation = _impl,
    attrs = {
        "elixir": attr.label(
            mandatory = True,
            providers = [OtpInfo, ElixirInfo],
        ),
    },
    provides = [platform_common.ToolchainInfo],
)

def _build_info(ctx):
    return ctx.toolchains["//:toolchain_type"].otpinfo

# Mirrors @rules_erlang//tools:erlang_toolchain.bzl, resolved against the Elixir toolchain
# type, which carries the OtpInfo the Elixir distribution was built against.
def erlang_dirs(ctx, short_path = False):
    info = _build_info(ctx)
    erlang_home = info.erlang_home
    if info.release_dir != None:
        runfiles = ctx.runfiles([
            info.release_dir,
            info.version_file,
        ])
        if short_path:
            erlang_home = info.release_dir.short_path + erlang_home[len(info.release_dir.path):]
    else:
        runfiles = ctx.runfiles([
            info.version_file,
        ])
    return (erlang_home, info.release_dir, runfiles)

def elixir_dirs(ctx, short_path = False):
    info = ctx.toolchains["//:toolchain_type"].elixirinfo
    if info.elixir_home != None:
        return (info.elixir_home, ctx.runfiles([info.version_file]))
    else:
        p = info.release_dir.short_path if short_path else info.release_dir.path
        return (p, ctx.runfiles([info.release_dir, info.version_file]))

def erlang_preamble(ctx, short_path = False):
    """Shell defining $ABS_ERLANG_HOME. Emit before any use of the OTP tree."""
    (erlang_home, _, _) = erlang_dirs(ctx, short_path = short_path)
    return """\
if [[ "{erlang_home}" == /* ]]; then
    ABS_ERLANG_HOME="{erlang_home}"
else
    ABS_ERLANG_HOME="$PWD/{erlang_home}"
fi\
""".format(erlang_home = erlang_home)

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    ebin = ctx.actions.declare_directory(ctx.attr.dest)

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = ctx.files.ez_deps,
        expand_ezs = True,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    env = "\n".join([
        "export {}={}".format(k, v)
        for k, v in ctx.attr.env.items()
    ])

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    script = """set -euo pipefail

{maybe_install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS={erl_libs_path}
fi

{env}

{setup}
diagnostics=$(mktemp)
status=0
${{ABS_ELIXIR_HOME}}/bin/elixirc \\
    -o {out_dir} \\
    {elixirc_opts} \\
    {srcs} 2>"$diagnostics" || status=$?
cat "$diagnostics" >&2
# Released Elixir ignores --warnings-as-errors in elixirc and exits 0 on
# warnings. Fail here instead. Once elixirc fails by itself, status is
# not 0 and this check does nothing. The launcher's warning about a
# latin1 file name encoding is not a compiler warning, so it is skipped.
if [ "$status" = 0 ] && [ -n "{warnings_as_errors}" ] && awk '
    /^[[:space:]]*warning:/ && !/native name encoding of latin1/ {{ found = 1 }}
    END {{ exit !found }}
' "$diagnostics"; then
    echo "Compilation failed due to warnings while using the --warnings-as-errors option" >&2
    status=1
fi
rm -f "$diagnostics"
exit "$status"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        env = env,
        setup = ctx.attr.setup,
        out_dir = ebin.path,
        elixirc_opts = " ".join([shell.quote(opt) for opt in ctx.attr.elixirc_opts]),
        srcs = " ".join([f.path for f in ctx.files.srcs]),
        warnings_as_errors = "1" if "--warnings-as-errors" in ctx.attr.elixirc_opts else "",
    )

    inputs = depset(
        # ctx.files.data: Elixir modules routinely read files at COMPILE time --
        # @moduledoc File.read!("README.md") and @external_resource are both common in
        # Hex packages (crux and sourceror in the Ash closure alone). Without a way to
        # declare those, the file exists in the repository but never reaches the sandbox
        # and compilation fails on a missing file.
        direct = ctx.files.srcs + ctx.files.data + erl_libs_files,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ebin],
        command = script,
        mnemonic = "ELIXIRC",
    )

    return [
        DefaultInfo(
            files = depset([ebin]),
        )
    ]

elixir_bytecode = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".ex"],
        ),
        "data": attr.label_list(allow_files = True),
        "elixirc_opts": attr.string_list(),
        "env": attr.string_dict(),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "dest": attr.string(
            mandatory = True,
        ),
        "setup": attr.string(),
    },
    toolchains = ["//:toolchain_type"],
)

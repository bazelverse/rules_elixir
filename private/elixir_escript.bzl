"""Package an Elixir application and its dependency closure as a single-file escript.

rules_erlang's escript_archive cannot do this. It compiles `.erl` with `erlc` and takes
`.beam`; rules_erlang contains no Elixir compilation at all. It also has no attribute for the
entry module, so the emu_args a runnable escript needs have to be smuggled through its
`headers` string list.

The escript carries every application in the closure -- including elixir and its stdlib --
because it runs under `erl`, which knows nothing about Elixir unless it is in the archive.
"""

load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "erlang_preamble",
)

def _impl(ctx):
    archive = ctx.actions.declare_file(ctx.label.name + ".escript")
    launcher = ctx.actions.declare_file(ctx.label.name)

    erl_libs_dir = ctx.label.name + "_deps"
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = False,
        dir = erl_libs_dir,
        deps = flat_deps([ctx.attr.app] + ctx.attr.deps),
        ez_deps = [],
        expand_ezs = False,
    )

    # erl_libs_contents stages under bin_dir, not under a bare relative directory.
    erl_libs_path = path_join(
        ctx.bin_dir.path,
        ctx.label.workspace_root,
        ctx.label.package,
        erl_libs_dir,
    )

    (preamble, toolchain_runfiles) = _toolchain_preamble(ctx)

    # -escript main <Module>: the entry point. An Elixir module Foo.Bar is the Erlang atom
    # 'Elixir.Foo.Bar', which is why this is spelled out rather than derived.
    script = preamble + """
export HOME="$PWD"
"$ABS_ELIXIR_HOME"/bin/elixir -e '
  libs = Path.wildcard("{erl_libs}/*/ebin")
  entries =
    Enum.flat_map(libs, fn ebin ->
      Enum.map(Path.wildcard(ebin <> "/*.{{beam,app}}"), fn f ->
        {{String.to_charlist(Path.basename(f)), File.read!(f)}}
      end)
    end)

  :ok =
    :escript.create(
      ~c"{output}",
      [
        {{:shebang, ~c"/usr/bin/env escript"}},
        {{:emu_args, ~c"-escript main Elixir.{entry_module} -noshell"}},
        {{:archive, entries, []}}
      ]
    )
'
chmod +x {output}
""".format(
        erl_libs = erl_libs_path,
        entry_module = ctx.attr.entry_module,
        output = archive.path,
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = erl_libs_files,
            transitive = [rf.files for rf in toolchain_runfiles],
        ),
        outputs = [archive],
        command = script,
        mnemonic = "ElixirEscript",
        progress_message = "Assembling escript %s" % ctx.label.name,
    )

    # protoc and friends exec a plugin directly, with no PATH set up and no shell, so the
    # archive's `#!/usr/bin/env escript` shebang cannot resolve. This launcher finds OTP in
    # its own runfiles instead, which Bazel stages wherever the tool is used.
    (erlang_home, release_dir, _) = erlang_dirs(ctx, short_path = True)
    ctx.actions.write(
        output = launcher,
        content = """#!/usr/bin/env bash
set -eo pipefail
RUNFILES="${{RUNFILES_DIR:-$0.runfiles}}"
if [[ "{erlang_home}" == /* ]]; then
    ESCRIPT="{erlang_home}/bin/escript"
else
    ESCRIPT="$RUNFILES/{workspace}/{erlang_home}"
    ESCRIPT="${{ESCRIPT}}/bin/escript"
fi
exec "$ESCRIPT" "$RUNFILES/{workspace}/{archive}" "$@"
""".format(
            erlang_home = erlang_home,
            workspace = ctx.workspace_name,
            archive = archive.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [archive] + ([release_dir] if release_dir else []))
    for rf in toolchain_runfiles:
        runfiles = runfiles.merge(rf)

    return [DefaultInfo(
        executable = launcher,
        files = depset([launcher, archive]),
        runfiles = runfiles,
    )]

def _toolchain_preamble(ctx):
    erlang = erlang_preamble(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)
    (_, _, erlang_runfiles) = erlang_dirs(ctx)

    preamble = """\
{erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME="$PWD/{elixir_home}"
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"$ABS_ERLANG_HOME"/bin:${{PATH}}
""".format(erlang = erlang, elixir_home = elixir_home)

    return (preamble, [erlang_runfiles, elixir_runfiles])

elixir_escript = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "entry_module": attr.string(
            mandatory = True,
            doc = "Elixir module with main/1, without the Elixir. prefix.",
        ),
    },
    executable = True,
    toolchains = ["//:toolchain_type"],
)

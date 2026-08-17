"""Generate Bazel BUILD stubs for a Hex closure from mix.lock, and guard them against drift.

Three targets over ONE generation action:

    hex_stubs        the action: locks + config -> a directory of stubs + a manifest
    hex_stubs_test   compares that output against the checked-in files
    hex_stubs_write  copies that output into the source tree (tag it manual)

Both consumers read the same declared output, which is the point: when generation happened
separately inside the run target and inside the test, the two resolved their inputs
differently -- one against the working tree, one against runfiles -- and could disagree,
in the guard whose whole job is to make disagreement impossible.

The checked-in files are inputs to the TEST only. If they reach the generation action the
action's cache key becomes a function of its own previous output, and every regeneration
invalidates the action that produced it.

The generated `hex_packages.bzl` must stay checked in: a module extension loads it during
extension evaluation, before the analysis phase exists, so it can never be fed from a build
output. The copy this action produces exists to be diffed.
"""

load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "erlang_preamble",
)

_ATTRS = {
    "locks": attr.label_list(
        allow_files = True,
        mandatory = True,
        doc = "Every project's mix.lock. All of them: a Bazel repository name is global, so " +
              "the closure is resolved once across the workspace, not per project.",
    ),
    "repo_prefix": attr.string(
        default = "hex_",
        doc = "Spoke repository prefix. Must match hex_packages_extension's repo_prefix; " +
              "stubs address their siblings by these names and nothing else cross-checks it.",
    ),
    "app_target": attr.string(default = "erlang_app"),
    "skip": attr.string_dict(doc = "app -> reason, for packages Bazel does not build."),
    "drop_edges": attr.string_list_dict(
        doc = "parent -> deps to drop. A lock records no MIX_ENV and no `only:`, so a " +
              "test-only edge is indistinguishable from a runtime one and must be named here.",
    ),
    "path_deps": attr.string_dict(
        doc = "app -> label, for packages an override replaced so they never appear in a lock.",
    ),
    "extra_mix_loads": attr.string_list_dict(
        doc = "bzl label -> symbols, spliced into every Mix stub.",
    ),
    "extra_mix_attrs": attr.string_list(
        doc = "Attribute lines spliced into every generated mix_app call.",
    ),
    "mix_template": attr.label(
        allow_single_file = True,
        default = Label("//private/hex/templates:mix_app.stub.tmpl"),
    ),
    "erlang_template": attr.label(
        allow_single_file = True,
        default = Label("//private/hex/templates:erlang_app.stub.tmpl"),
    ),
    "_generator": attr.label(
        allow_single_file = True,
        default = Label("//private/hex:gen_hex_bazel.exs"),
    ),
}

def _toolchain_preamble(ctx, short_path):
    erlang = erlang_preamble(ctx, short_path = short_path)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = short_path)
    (_, _, erlang_runfiles) = erlang_dirs(ctx, short_path = short_path)

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

def _config(ctx):
    config = ctx.actions.declare_file(ctx.label.name + "_config.json")
    ctx.actions.write(
        output = config,
        content = json.encode({
            "repo_prefix": ctx.attr.repo_prefix,
            "app_target": ctx.attr.app_target,
            "generated_by": "//{}:{}".format(ctx.label.package, ctx.label.name),
            "skip": ctx.attr.skip,
            "drop_edges": ctx.attr.drop_edges,
            "path_deps": ctx.attr.path_deps,
            "extra_loads": [
                {"bzl": bzl, "symbols": syms}
                for bzl, syms in ctx.attr.extra_mix_loads.items()
            ],
            "extra_attrs": ctx.attr.extra_mix_attrs,
            "mix_template": ctx.file.mix_template.path,
            "erlang_template": ctx.file.erlang_template.path,
        }),
    )
    return config

def _hex_stubs_impl(ctx):
    stubs = ctx.actions.declare_directory(ctx.label.name)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    config = _config(ctx)

    (preamble, toolchain_runfiles) = _toolchain_preamble(ctx, short_path = False)

    ctx.actions.run_shell(
        inputs = depset(
            direct = ctx.files.locks + [
                ctx.file._generator,
                ctx.file.mix_template,
                ctx.file.erlang_template,
                config,
            ],
            transitive = [rf.files for rf in toolchain_runfiles],
        ),
        outputs = [stubs, manifest],
        # Erlang wants a writable home for its cookie; an action has no TEST_TMPDIR.
        command = preamble + """
export HOME="$PWD"
"$ABS_ELIXIR_HOME"/bin/elixir {generator} \\
    --config {config} \\
    --out-dir {out} \\
    --manifest {manifest} \\
    {locks}
""".format(
            generator = ctx.file._generator.path,
            config = config.path,
            out = stubs.path,
            manifest = manifest.path,
            locks = " ".join([f.path for f in ctx.files.locks]),
        ),
        mnemonic = "HexStubs",
        progress_message = "Generating Hex BUILD stubs",
    )

    return [
        DefaultInfo(files = depset([stubs, manifest])),
        OutputGroupInfo(manifest = depset([manifest])),
    ]

hex_stubs = rule(
    implementation = _hex_stubs_impl,
    attrs = _ATTRS,
    toolchains = ["//:toolchain_type"],
)

def _source_manifest(ctx):
    """The checked-in side, named by label rather than by walking the directory.

    The stub directory also holds BUILD.bazel, the extension, and any hand-written stub, so a
    recursive diff against it is wrong. An explicit list also makes each hand-written
    exemption visible in BUILD.bazel instead of implied by grepping files for a marker.
    """
    lines = [f.short_path + "\t" + f.basename for f in ctx.files.checked_in]
    out = ctx.actions.declare_file(ctx.label.name + "_source.manifest")
    ctx.actions.write(output = out, content = "\n".join(sorted(lines)) + "\n")
    return out

_COMPARE = """
generated="$1"
gen_manifest="$2"
src_manifest="$3"

status=0

cut -f1 "$gen_manifest" | sort > "$gen_names"
cut -f2 "$src_manifest" | sort > "$src_names"

# Name sets first, so a package entering or leaving the closure reads as such rather than as a
# diff against a file that does not exist.
while read -r name; do
    [ -z "$name" ] && continue
    if ! grep -qxF "$name" "$src_names"; then
        echo "added:   $name is generated but not checked in"
        status=1
    fi
done < "$gen_names"

while read -r name; do
    [ -z "$name" ] && continue
    if ! grep -qxF "$name" "$gen_names"; then
        echo "stale:   $name is checked in but no longer produced by any mix.lock"
        status=1
    fi
done < "$src_names"

while IFS="$(printf '\\t')" read -r path base; do
    [ -z "$path" ] && continue
    if grep -qxF "$base" "$gen_names"; then
        if ! diff -u "$path" "$generated/$base"; then
            status=1
        fi
    fi
done < "$src_manifest"
"""

def _hex_stubs_test_impl(ctx):
    stubs = ctx.attr.stubs[DefaultInfo].files.to_list()
    tree = [f for f in stubs if f.is_directory][0]
    gen_manifest = [f for f in stubs if not f.is_directory][0]
    src_manifest = _source_manifest(ctx)

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = """#!/usr/bin/env bash
set -eo pipefail

gen_names="$TEST_TMPDIR/gen_names"
src_names="$TEST_TMPDIR/src_names"
""" + _COMPARE.replace('"$1"', '"{tree}"').replace('"$2"', '"{gen}"').replace('"$3"', '"{src}"').format(
            tree = tree.short_path,
            gen = gen_manifest.short_path,
            src = src_manifest.short_path,
        ) + """
if [ "$status" -ne 0 ]; then
    echo ""
    echo "The checked-in Hex stubs are out of date with the mix.lock files."
    echo "Regenerate them with: bazel run {write}"
fi
exit "$status"
""".format(write = ctx.attr.write_target),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(
            files = [tree, gen_manifest, src_manifest] + ctx.files.checked_in,
        ),
    )]

hex_stubs_test = rule(
    implementation = _hex_stubs_test_impl,
    attrs = {
        "stubs": attr.label(mandatory = True, doc = "The hex_stubs target."),
        "checked_in": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "The checked-in generated files. Name them; do not glob the directory, " +
                  "which also holds BUILD.bazel, the extension and hand-written stubs.",
        ),
        "write_target": attr.string(mandatory = True, doc = "Label named in the failure hint."),
    },
    test = True,
)

def _hex_stubs_write_impl(ctx):
    stubs = ctx.attr.stubs[DefaultInfo].files.to_list()
    tree = [f for f in stubs if f.is_directory][0]

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        # install -m 644: action outputs are commonly non-writable and cp propagates mode, so
        # a plain copy makes the first run succeed and the second fail on every file.
        content = """#!/usr/bin/env bash
set -eo pipefail

if [ -z "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]; then
    echo "this target must be invoked with 'bazel run', not 'bazel build'" >&2
    exit 1
fi

dest="$BUILD_WORKSPACE_DIRECTORY/{package}"
mkdir -p "$dest"
for f in "{tree}"/*; do
    install -m 644 "$f" "$dest/$(basename "$f")"
done
echo "wrote $(ls "{tree}" | wc -l | tr -d ' ') files to {package}/"
""".format(tree = tree.short_path, package = ctx.attr.dest_package),
        is_executable = True,
    )

    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [tree]))]

hex_stubs_write = rule(
    implementation = _hex_stubs_write_impl,
    attrs = {
        "stubs": attr.label(mandatory = True),
        "dest_package": attr.string(
            mandatory = True,
            doc = "Workspace-relative directory to write into.",
        ),
    },
    executable = True,
)

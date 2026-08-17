"""Repository-wide inputs every mix_app compile needs.

These are labels only a consumer can name -- its Hex archive, its C++ runtime, its precompiled
NIF and OS-dep trees. They were once defaults on mix_app itself, written as bare `//...`
labels, which resolved against whichever module happened to hold the rule.

They are not per-target either: every mix_app in a repository wants the same set, and there
are a few hundred of them once a Hex closure is generated.

That makes them a toolchain -- implementation-specific inputs a rule resolves rather than
takes, declared once in the module graph:

    # //build/BUILD.bazel
    mix_payloads(name = "payloads", archives = ["@hex//:archive"], ...)
    toolchain(
        name = "mix_payloads",
        toolchain = ":payloads",
        toolchain_type = "@rules_elixir//:mix_payloads_toolchain_type",
    )

    # MODULE.bazel
    register_toolchains("//build:mix_payloads")

Not a flag in a .bazelrc. A flag is a knob meant to vary, and this never does; worse, a
.bazelrc is client configuration rather than the build graph, so an invocation that does not
read it would silently compile NIFs with no C++ runtime -- which links clean and fails at
dlopen. MODULE.bazel travels with the repository.

`elixir_make_nifs_target` is genuinely target-platform-specific, so toolchain resolution is
doing real work here and not merely carrying a constant.
"""

MixPayloadsInfo = provider(
    doc = "Inputs mix_app stages into every Mix compile.",
    fields = {
        "archives": "Mix archives to install, e.g. Hex.",
        "cxx_static_runtime": "C++ static runtime a NIF links when it compiles C++.",
        "elixir_make_nifs": "Prebuilt elixir_make NIFs for the exec platform.",
        "elixir_make_nifs_target": "Prebuilt elixir_make NIFs for the target platform.",
        "openssl_sysroot": "OpenSSL sysroot tar, or None.",
        "precompiled_nifs": "Prebuilt NIFs staged before compilation.",
        "precompiled_os_deps": "Prebuilt OS dependencies for Bundlex.",
    },
)

def _impl(ctx):
    return [platform_common.ToolchainInfo(payloads = MixPayloadsInfo(
        archives = ctx.files.archives,
        cxx_static_runtime = ctx.files.cxx_static_runtime,
        elixir_make_nifs = ctx.files.elixir_make_nifs,
        elixir_make_nifs_target = ctx.files.elixir_make_nifs_target,
        openssl_sysroot = ctx.file.openssl_sysroot,
        precompiled_nifs = ctx.files.precompiled_nifs,
        precompiled_os_deps = ctx.files.precompiled_os_deps,
    ))]

mix_payloads = rule(
    implementation = _impl,
    attrs = {
        "archives": attr.label_list(allow_files = True),
        "cxx_static_runtime": attr.label(allow_files = True),
        "elixir_make_nifs": attr.label_list(allow_files = True),
        "elixir_make_nifs_target": attr.label_list(allow_files = True),
        "openssl_sysroot": attr.label(allow_single_file = True),
        "precompiled_nifs": attr.label_list(allow_files = True),
        "precompiled_os_deps": attr.label_list(allow_files = True),
    },
)

# What a rule sees when no toolchain is registered.
EMPTY_PAYLOADS = MixPayloadsInfo(
    archives = [],
    cxx_static_runtime = [],
    elixir_make_nifs = [],
    elixir_make_nifs_target = [],
    openssl_sysroot = None,
    precompiled_nifs = [],
    precompiled_os_deps = [],
)

"""Repository-wide inputs every mix_app compile needs.

These are labels only a consumer can name -- its Hex archive, its C++ runtime, its precompiled
NIF and OS-dep trees. They were once defaults on mix_app itself, written as bare `//...`
labels, which resolved against whichever module happened to hold the rule.

They are not per-target either: every mix_app in a repository wants the same set, and there
are a few hundred of them once a Hex closure is generated.

So they are one target, selected by a flag:

    # //build/BUILD.bazel
    mix_payloads(name = "mix_payloads", archives = ["@hex//:archive"], ...)

    # .bazelrc
    build --@rules_elixir//:mix_payloads=//build:mix_payloads

The default is an empty instance, so a repository with no NIFs and no Hex archive needs none
of this.
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
    return [MixPayloadsInfo(
        archives = ctx.files.archives,
        cxx_static_runtime = ctx.files.cxx_static_runtime,
        elixir_make_nifs = ctx.files.elixir_make_nifs,
        elixir_make_nifs_target = ctx.files.elixir_make_nifs_target,
        openssl_sysroot = ctx.file.openssl_sysroot,
        precompiled_nifs = ctx.files.precompiled_nifs,
        precompiled_os_deps = ctx.files.precompiled_os_deps,
    )]

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
    provides = [MixPayloadsInfo],
)

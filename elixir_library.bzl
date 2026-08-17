load("@rules_erlang//:app_file2.bzl", "app_file")
load("@rules_erlang//:erlang_app_info.bzl", "erlang_app_info")
load("//private:elixir_bytecode.bzl", "elixir_bytecode")
load("//private:elixir_ebin_dir.bzl", "elixir_ebin_dir")
load("//private:erlang_app_filter_module_conflicts.bzl", "erlang_app_filter_module_conflicts")

def elixir_library(
        name,
        app_name = None,
        srcs = None,
        hdrs = None,
        priv = None,
        extra_apps = [],
        data = [],
        elixirc_opts = [],
        ez_deps = [],
        deps = [],
        visibility = None,
        **kwargs):
    """Compile Elixir sources into an ErlangAppInfo, once per name.

    `elixir_app` names its intermediate targets after what they are, so a package can hold
    exactly one. Codegen routinely needs two in one package -- generated modules plus the
    hand-written ones that use them -- so every target here is derived from `name`.

    `srcs` accepts a directory as well as files: a generated tree is expanded when the
    compile action runs, since its contents are unknown at analysis time.

    Args:
      name: target name. The ErlangAppInfo is `:<name>`.
      app_name: OTP application name. Defaults to `name`.
      srcs: .ex files, or a target producing a directory of them.
      hdrs: Erlang headers. Defaults to "include/**/*.hrl".
      priv: runtime files. Defaults to "priv/**/*"; NIFs arrive as priv/native/*.so.
      extra_apps: additional apps (elixir is always included) for the .app file.
      data: files read at COMPILE time -- @external_resource and friends.
      elixirc_opts: elixirc options.
      ez_deps: .ez dependencies.
      deps: ErlangAppInfo labels.
      visibility: target visibility.
      **kwargs: passed to app_file, e.g. app_description.
    """
    app_name = app_name or name
    if srcs == None:
        srcs = native.glob(["lib/**/*.ex"])
    if hdrs == None:
        hdrs = native.glob(["include/**/*.hrl"], allow_empty = True)
    if priv == None:
        priv = native.glob(["priv/**/*"], allow_empty = True)

    elixir_bytecode(
        name = name + "_beam_files",
        srcs = srcs,
        data = data,
        dest = name + "_beam_files",
        elixirc_opts = elixirc_opts,
        ez_deps = ez_deps,
        deps = deps,
    )

    app_file(
        name = name + "_app_file",
        out = "%s.app" % app_name,
        app_name = app_name,
        extra_apps = ["elixir"] + extra_apps,
        modules = [":" + name + "_beam_files"],
        **kwargs
    )

    elixir_ebin_dir(
        name = name + "_ebin",
        beam_files_dir = ":" + name + "_beam_files",
        app_file = ":" + name + "_app_file",
        dest = name + "_ebin",
    )

    erlang_app_filter_module_conflicts(
        name = name + "_elixir_without_app_overlap",
        dest = name + "_unconsolidated",
        src = Label("//elixir:elixir"),
        without = [":" + name + "_ebin"],
    )

    erlang_app_info(
        name = name,
        srcs = srcs,
        hdrs = hdrs,
        app_name = app_name,
        beam = [":" + name + "_ebin"],
        extra_apps = extra_apps,
        # allow_empty: plenty of Hex packages ship no LICENSE file (ash among them), and with
        # --incompatible_disallow_empty_glob on -- the default since Bazel 7 -- an empty glob
        # is a hard error, so those packages could not be built at all.
        license_files = native.glob(["LICENSE*"], allow_empty = True),
        priv = priv,
        visibility = visibility,
        deps = [":" + name + "_elixir_without_app_overlap"] + deps,
    )

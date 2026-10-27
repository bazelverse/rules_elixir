load("@rules_erlang//:app_file2.bzl", "app_file")
load("@rules_erlang//:erlang_app_info.bzl", "erlang_app_info")
load("//private:elixir_bytecode.bzl", "elixir_bytecode")
load("//private:elixir_ebin_dir.bzl", "elixir_ebin_dir")
load("//private:erlang_app_filter_module_conflicts.bzl", "erlang_app_filter_module_conflicts")

def _prefixed(name, suffix, sep):
    # The default name keeps the internal names and output dirs that
    # elixir_app has always used, so existing users see no change.
    if name == "erlang_app":
        return suffix
    return name + sep + suffix

def elixir_app(
        name = "erlang_app",
        app_name = None,
        extra_apps = [],
        srcs = None,
        data = [],
        elixirc_opts = [],
        ez_deps = [],
        deps = [],
        target_compatible_with = None,
        testonly = False,
        tags = None,
        **kwargs):
    """compiles elixir sources in a manner compatible with @rules_erlang

    Args:
      name: Name of the final ErlangAppInfo target. With the default
          "erlang_app", the internal targets are named beam_files,
          app_file, ebin and elixir_without_app_overlap. With any other
          name they are prefixed with "<name>_", and their output dirs
          with "<name>/", so several apps can share a package.
      app_name: Name of the application
      extra_apps: additional apps (elixir is always included) injected into
          the .app file
      srcs: Sources. Defaults to "lib/**/*.ex"
      elixirc_opts: elixirc options
      ez_deps: Dependencies that are .ez files
      deps: ErlangAppInfo labels
      target_compatible_with: Passed to every generated target
      testonly: Passed to every generated target
      tags: Passed to every generated target
      **kwargs: Additional args passed to the underlying app_file rule, such
          as app_description

    Returns:
      Nothing
    """
    if srcs == None:
        srcs = native.glob([
            "lib/**/*.ex",
        ])

    beam_files = _prefixed(name, "beam_files", "_")
    app_file_name = _prefixed(name, "app_file", "_")
    ebin = _prefixed(name, "ebin", "_")
    without_overlap = _prefixed(name, "elixir_without_app_overlap", "_")
    common = dict(
        target_compatible_with = target_compatible_with,
        testonly = testonly,
        tags = tags,
    )

    elixir_bytecode(
        name = beam_files,
        srcs = srcs,
        data = data,
        dest = _prefixed(name, "beam_files", "/"),
        elixirc_opts = elixirc_opts,
        ez_deps = ez_deps,
        deps = deps,
        **common
    )

    app_file(
        name = app_file_name,
        out = "%s.app" % app_name,
        app_name = app_name,
        extra_apps = ["elixir"] + extra_apps,
        modules = [":" + beam_files],
        **(common | kwargs)
    )

    elixir_ebin_dir(
        name = ebin,
        beam_files_dir = ":" + beam_files,
        app_file = ":" + app_file_name,
        dest = _prefixed(name, "ebin", "/"),
        **common
    )

    erlang_app_filter_module_conflicts(
        name = without_overlap,
        dest = _prefixed(name, "unconsolidated", "/"),
        src = Label("@rules_elixir//elixir:elixir"),
        without = [":" + ebin],
        **common
    )

    erlang_app_info(
        name = name,
        srcs = srcs,
        hdrs = [],
        app_name = app_name,
        beam = [":" + ebin],
        extra_apps = extra_apps,
        # allow_empty: plenty of Hex packages ship no LICENSE file (ash among them), and
        # with --incompatible_disallow_empty_glob on -- the default since Bazel 7 -- an
        # empty glob is a hard error, so those packages could not be built at all.
        license_files = native.glob(["LICENSE*"], allow_empty = True),
        priv = [],
        visibility = ["//visibility:public"],
        deps = [
            ":" + without_overlap,
        ] + deps,
        **common
    )

# rules_elixir

Bazel rules for building Elixir applications. Compile an app, run its ExUnit
suites, build a Mix archive, and evaluate code with `iex`.

Built on [rules_erlang](https://github.com/bazelverse/rules_erlang), and requires
it. Elixir applications are OTP applications, so the Erlang toolchain, the app
metadata and the `ERL_LIBS` staging all come from there.

Requires Bazel 7 or newer, and `rules_erlang` 3.18.0 or newer.

## Status

This repository continues rabbitmq's `rules_elixir`, which is unmaintained.
`v1.1.0` was its last release.

**1.2.0 is a drop-in replacement for 1.1.0.** Nothing in the rules breaks; every
commit between the two tags is one documented fix or addition. See
[CHANGELOG.md](./CHANGELOG.md).

## Installation

In `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_elixir", version = "1.2.0")

elixir_config = use_extension(
    "@rules_elixir//bzlmod:extensions.bzl",
    "elixir_config",
)
use_repo(elixir_config, "elixir_config")

register_toolchains("@elixir_config//external:toolchain")
```

That uses the Elixir already on the machine. To have Bazel fetch and build a
pinned Elixir instead:

```starlark
elixir_config.internal_elixir_from_github_release(
    version = "1.17.3",
    sha256 = "...",
)
```

Set `RULES_ELIXIR_SKIP_SYSTEM=1` to stop the extension probing the host for an
Elixir install at all. That is what you want when every toolchain is hermetic:

```
build --repo_env=RULES_ELIXIR_SKIP_SYSTEM=1
build --repo_env=RULES_ERLANG_SKIP_SYSTEM=1
```

## Rules

| Rule | What it does |
| --- | --- |
| `elixir_app` | Compile an Elixir application into an OTP app |
| `elixir_external` | Wrap an Elixir installation outside the build |
| `ex_unit_test` | Run an ExUnit suite as a Bazel test |
| `mix_archive_build` | Build a `.ez` Mix archive |
| `iex_eval` | Evaluate Elixir code with `iex` |
| `elixir_build` | Build Elixir itself from source |
| `elixir_toolchain` | Declare an Elixir toolchain |

### Compiling an application

```starlark
load("@rules_elixir//:elixir_app.bzl", "elixir_app")

elixir_app(
    name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    app_name = "my_app",
    app_version = "0.1.0",
)
```

Declare anything read at compile time, whether reached through `File.read!/1` or
`@external_resource`. Undeclared files do not exist in the sandbox.

### Running tests

```starlark
load("@rules_elixir//:ex_unit_test.bzl", "ex_unit_test")

ex_unit_test(
    name = "my_app_test",
    srcs = glob(["test/**/*_test.exs"]),
    deps = [":my_app"],
)
```

Test inputs keep their package-relative layout, so a test resolving a path off
`__DIR__` finds what it expects.

## Hex

Mix will not resolve a project at all unless Hex is installed as an archive. Any
dependency entry in a `mix.exs` aborts with *"Could not find an SCM for
dependency"*, even a dev-only one that would never be compiled, and even in a
build that supplies every dependency from Bazel and passes `--no-deps-check`.

The `hex` extension builds Hex from source and exports it as `@hex//:archive`:

```starlark
hex = use_extension("@rules_elixir//bzlmod:extensions.bzl", "hex")
use_repo(hex, "hex")
```

Pin a different version with the `from_github_release` tag:

```starlark
hex.from_github_release(
    version = "2.5.1",
    sha256 = "...",
)
```

Hex has no dependencies of its own, so it bootstraps through
`mix_archive_build` with an empty dependency graph. That is why this can live
here rather than in every consuming module.

Fetching Hex *packages* is a different job from installing Hex the tool. For a
handful of packages see `rules_erlang`'s `erlang_package` extension; for a whole
application closure, its `hex_packages_extension`.

## Examples

See the `examples` directory.

## License

Dual licensed under the Apache License Version 2.0 and the Mozilla Public
License Version 2.0.

You may consider this library to be licensed under **any of the licenses in that
list**. For example, you may choose the Apache License 2.0 and include this
library in a commercial product.

See [LICENSE](./LICENSE) for details. Copyright, including the notice for the
original upstream work, is covered separately in [COPYRIGHT.md](./COPYRIGHT.md).

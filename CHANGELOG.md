# Changelog

## 1.2.0

First release from <https://github.com/bazelverse/rules_elixir>.

Continues from the **v1.1.0** tag of the unmaintained upstream, carrying the
fixes that were being kept downstream as a vendored copy. Requires
`rules_erlang` **3.18.0**.

Every change is a separate commit, so `git diff v1.1.0..1.2.0` is exactly this
list and nothing else.

### Fixed

- **Skip system Elixir** (`repositories/elixir_config.bzl`). Honour
  `RULES_ELIXIR_SKIP_SYSTEM=1`, so a build can use a hermetic toolchain instead
  of probing the host for an Elixir install.

- **Portable tarball extraction** (`private/elixir_build.bzl`). The same GNU-tar
  assumption fixed in rules_erlang 3.18.0. `--transform` does not exist in the
  bsdtar that macOS ships, so every Elixir target failed on macOS before
  compiling anything.

- **Allow an empty `LICENSE` glob** (`elixir_app.bzl`). `elixir_app` hard-failed
  on any package without a `LICENSE` file.

- **Compile-time data** (`elixir_app.bzl`, `private/elixir_bytecode.bzl`).
  `elixir_bytecode` could not declare compile-time file inputs, so a package
  reading a file during compilation, or declaring `@external_resource`, failed in
  the sandbox.

- **ExUnit test headers** (`private/ex_unit_test.bzl`). `ex_unit_test` staged its
  dependencies without their `include/` directories, so a test using
  `Record.extract(from_lib: ...)` died before running a case. Compilation rules
  stage headers; tests now do too.

- **ExUnit workspace layout** (`private/ex_unit_test.bzl`). `ex_unit_test`
  flattened `srcs` and `data` by stripping the package prefix, which breaks any
  test resolving a repository-relative path off `__DIR__`.

- **Stage test inputs into `TEST_TMPDIR`** (`private/ex_unit_test.bzl`).
  `ex_unit_test` copied every `srcs` and `data` file into
  `TEST_UNDECLARED_OUTPUTS_DIR` and ran there. Bazel treats that directory as
  artifacts the test *produced*, so it stats and mime-types every entry to build
  the manifest, then uploads them. Each target shipped a few thousand of its own
  inputs to the CAS per run. On a remote executor carrying no `file(1)` it also
  emitted roughly 2,150 "command not found" lines per test. Nothing was ever
  collected from there on purpose.

- **Migrate off the deprecated Windows condition** (`ex_unit_test.bzl`).
  `@bazel_tools//src/conditions:host_windows` is deprecated and warned on every
  `ex_unit_test` target; it is now the `@platforms//os:windows` constraint. This
  is also a semantic correction. The old key matched the *host*, while the flag
  decides whether the generated runner is a batch file or a shell script, a
  property of the platform the test *executes* on. For a test rule that is the
  target platform.

### Added

- **`mix_archive_build`** (`mix_archive_build.bzl`,
  `private/mix_archive_build.bzl`): build a `.ez` Mix archive. The rules could
  already compile an Elixir app but could not produce an archive, and
  `mix archive.install` is the only way to give Mix something it needs *before*
  it can resolve a project. Adapted from rabbitmq-server's
  `bazel/elixir/mix_archive_build.bzl` (MPL-2.0), the same lineage as this
  ruleset.

- **`hex` module extension** (`bzlmod/extensions.bzl`): builds Hex itself from
  source as a Mix archive, exported as `@hex//:archive`.

  Every consumer needs this and cannot discover it. Mix aborts with "Could not
  find an SCM for dependency" on any dependency entry in a `mix.exs` unless Hex
  is installed as an archive, including in a build that supplies all
  dependencies from Bazel and passes `--no-deps-check`. Hex has no dependencies
  of its own, so it bootstraps with an empty dependency graph. The version
  defaults to `DEFAULT_HEX_VERSION` and is overridable with the
  `from_github_release` tag, mirroring `internal_elixir_from_github_release`.

### Compatibility

Nothing in the rules breaks. The `rules_erlang` dependency moves from 3.16.0 to
3.18.0, which is itself a drop-in replacement.

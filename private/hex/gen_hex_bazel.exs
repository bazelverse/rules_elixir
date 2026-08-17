#!/usr/bin/env elixir
#
# Generate Bazel BUILD stubs and a package closure from a set of mix.lock files.
#
# Invoked by //private/hex:hex_stubs.bzl, never by hand:
#
#   elixir gen_hex_bazel.exs --config <config.json> --out-dir <dir> --manifest <file> <lock>...
#
# Pass EVERY project's lock. A Bazel repository name is global -- @hex_ecto can only be one
# version -- so the closure has to be resolved once across the whole workspace.
#
# Writes, into --out-dir:
#   <app>.BUILD       one per Hex package
#   hex_packages.bzl  the closure as data, for the caller's module extension to load
#
# and, to --manifest, one sorted `name<TAB>sha256` line per file written. The manifest is what
# makes the output diffable: a TreeArtifact cannot be enumerated at analysis time, so the
# drift test compares name sets from the manifest before comparing any content.
#
# mix.lock is valid Elixir term syntax and already carries everything Bazel needs -- version,
# outer checksum, build tools, and the resolved graph including which deps are optional -- so
# this reads it with Code.eval_file rather than a regex.

defmodule GenHexBazel do
  @moduledoc false

  # Everything repository-specific arrives through the config. The generator knows how to read
  # a lock and render a template; it knows nothing about any particular dependency graph.
  defstruct [
    :out_dir,
    :manifest,
    # Prefix for spoke repository names. Must match the `repo_prefix` given to
    # hex_packages_extension: generated stubs address their siblings by these names, and
    # nothing else cross-checks the two.
    repo_prefix: "hex_",
    # Target name a package exposes, as declared by the templates.
    app_target: "erlang_app",
    generated_by: "the stub generator",
    # app_name => reason. Packages Bazel does not build; edges to them are dropped too.
    skip: %{},
    # parent => [dep]. Edges the lock resolves but that must not be carried. A lock records
    # what the resolver saw and nothing about WHY: there is no MIX_ENV and no `only:`, so a
    # test-only dependency is indistinguishable from a runtime one here.
    drop_edges: %{},
    # dep => label. Packages an override replaced, so they never appear as lock entries.
    # Without this the edge is silently dropped and the dependent fails with "module X is not
    # loaded", which reads as a missing dependency rather than a shadowed one.
    path_deps: %{},
    # Extra `load()` lines and extra attribute lines spliced into every Mix stub. This is how a
    # repository injects `extra_config = HEX_COMPILE_ENV_CONFIG`: the compile_env invariant is
    # general, but which keys matter is not.
    extra_loads: [],
    extra_attrs: [],
    mix_template: nil,
    erlang_template: nil
  ]

  def main(argv) do
    {opts, lock_paths} =
      OptionParser.parse!(argv, strict: [config: :string, out_dir: :string, manifest: :string])

    if lock_paths == [], do: die("no mix.lock files given")

    config = %{
      load_config(Keyword.fetch!(opts, :config))
      | out_dir: Keyword.fetch!(opts, :out_dir),
        manifest: Keyword.fetch!(opts, :manifest)
    }

    run(config, lock_paths)
  end

  defp load_config(path) do
    raw = path |> File.read!() |> JSON.decode!()

    %__MODULE__{
      repo_prefix: Map.get(raw, "repo_prefix", "hex_"),
      app_target: Map.get(raw, "app_target", "erlang_app"),
      generated_by: Map.get(raw, "generated_by", "the stub generator"),
      skip: Map.get(raw, "skip", %{}),
      drop_edges: Map.get(raw, "drop_edges", %{}),
      path_deps: Map.get(raw, "path_deps", %{}),
      extra_loads: Map.get(raw, "extra_loads", []),
      extra_attrs: Map.get(raw, "extra_attrs", []),
      mix_template: read_template(raw, "mix_template"),
      erlang_template: read_template(raw, "erlang_template")
    }
  end

  defp read_template(raw, key) do
    case Map.get(raw, key) do
      nil -> nil
      path -> File.read!(path)
    end
  end

  def run(config, lock_paths) do
    lock = merge_locks(lock_paths)

    entries =
      lock
      |> Enum.map(&parse(config, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.name)

    non_hex =
      lock
      |> Enum.reject(fn {_, t} -> elem(t, 0) == :hex end)
      |> Enum.map(fn {n, t} -> "#{n} (#{elem(t, 0)})" end)

    if non_hex != [], do: warn("non-hex lock entries, declare by hand: #{Enum.join(non_hex, ", ")}")

    in_lock = MapSet.new(entries, & &1.name)

    File.mkdir_p!(config.out_dir)

    written =
      entries
      |> Enum.map(&write_build(config, &1, in_lock))
      |> then(&[write_packages_bzl(config, entries) | &1])
      |> Enum.sort()

    write_manifest(config, written)

    IO.puts("\ngenerated #{length(entries)} packages: #{inspect(Enum.frequencies_by(entries, &tool/1))}")
  end

  # Merge every project's lock, resolving disagreements to the highest version.
  #
  # A Bazel repository name is global, so when projects disagree something has to choose.
  # Highest-wins is the rule Mix itself applies to a diamond, so the Bazel closure lands on a
  # version at least one project has resolved against rather than an arbitrary older one.
  #
  # Every resolution is reported, because a disagreement is still a lockfile bug: the losing
  # project compiles against one version under Mix and another under Bazel.
  defp merge_locks(paths) do
    merged =
      paths
      |> Enum.reduce(%{}, fn path, acc ->
        {lock, _} = Code.eval_file(path)

        Enum.reduce(lock, acc, fn {name, tuple}, acc ->
          Map.update(acc, name, [{path, tuple}], &[{path, tuple} | &1])
        end)
      end)
      |> Map.new(fn {name, candidates} -> {name, Enum.reverse(candidates)} end)

    for {name, candidates} <- Enum.sort(merged),
        distinct = candidates |> Enum.map(&describe_version(elem(&1, 1))) |> Enum.uniq(),
        length(distinct) > 1 do
      warn(
        "#{name} disagrees across locks, taking the highest:\n" <>
          Enum.map_join(candidates, "\n", fn {p, t} -> "    #{describe_version(t)}  #{p}" end)
      )
    end

    Map.new(merged, fn {name, candidates} -> {name, highest(candidates)} end)
  end

  # A git pin has no comparable version; sort it below everything so a real Hex version always
  # wins, and it survives only as the sole candidate.
  @unversioned Version.parse!("0.0.0")

  defp highest(candidates) do
    candidates
    |> Enum.map(&elem(&1, 1))
    |> Enum.max_by(&comparable_version/1, Version)
  end

  defp comparable_version(tuple) do
    case version_of(tuple) do
      version when is_binary(version) ->
        case Version.parse(version) do
          {:ok, parsed} -> parsed
          :error -> @unversioned
        end

      _ ->
        @unversioned
    end
  end

  defp version_of({:hex, _pkg, version, _inner, _tools, _deps, _repo, _outer}), do: version
  defp version_of(_other), do: nil

  defp describe_version(tuple) do
    case version_of(tuple) do
      nil -> "#{elem(tuple, 0)} pin"
      version -> version
    end
  end

  # {:hex, :pkg, version, inner_checksum, build_tools, deps, "hexpm", outer_checksum}
  defp parse(config, {name, {:hex, pkg, version, _inner, tools, deps, _repo, outer}}) do
    name = to_string(name)

    if Map.has_key?(config.skip, name) do
      nil
    else
      %{
        name: name,
        pkg: to_string(pkg),
        version: version,
        sha256: outer,
        tools: tools,
        deps:
          Enum.map(deps, fn {dep, _req, opts} ->
            {to_string(dep), Keyword.get(opts, :optional, false)}
          end)
      }
    end
  end

  defp parse(_config, _other), do: nil

  # A package is built by Mix when :mix is among its build tools. Hex sometimes records an
  # empty tool list for Mix packages (phoenix 1.8.11, ex_sdp 1.2.0); those still ship mix.exs
  # and cannot be compiled as a bare erlang_app. Rebar/erlang.mk packages always say so.
  defp tool(%{tools: tools}) do
    cond do
      :mix in tools -> :mix
      tools == [] -> :mix
      true -> :erlang
    end
  end

  # An optional dep never resolved into the lock is not a real edge -- except where a path
  # override is the reason it is missing.
  defp resolved_deps(config, %{name: name, deps: deps}, in_lock) do
    dropped = Map.get(config.drop_edges, name, [])

    deps
    |> Enum.filter(fn {dep, _optional} ->
      (MapSet.member?(in_lock, dep) or Map.has_key?(config.path_deps, dep)) and
        not Map.has_key?(config.skip, dep) and
        dep not in dropped
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp dep_label(config, dep) do
    Map.get(config.path_deps, dep, "@#{config.repo_prefix}#{dep}//:#{config.app_target}")
  end

  defp dep_labels(config, deps, indent) do
    Enum.map_join(deps, "", fn d -> "\n#{indent}\"#{dep_label(config, d)}\"," end)
  end

  defp write_build(config, entry, in_lock) do
    deps = resolved_deps(config, entry, in_lock)

    template =
      case tool(entry) do
        :mix -> config.mix_template || die("a Mix package (#{entry.name}) needs mix_template")
        :erlang -> config.erlang_template || die("#{entry.name} needs erlang_template")
      end

    deps_lines = dep_labels(config, deps, "        ")
    deps_attr = if deps == [], do: "", else: "\n    deps = [#{deps_lines}\n    ],"

    body =
      template
      |> String.replace("{app_name}", entry.name)
      |> String.replace("{app_target}", config.app_target)
      |> String.replace("{generated_by}", config.generated_by)
      |> String.replace("{tools}", inspect(entry.tools))
      |> String.replace("{extra_loads}", render_extra_loads(config))
      |> String.replace("{extra_attrs}", render_extra_attrs(config))
      |> String.replace("{deps_attr}", deps_attr)
      |> String.replace("{deps}", deps_lines)

    write(config, "#{entry.name}.BUILD", body)
  end

  defp render_extra_loads(%{extra_loads: []}), do: ""

  defp render_extra_loads(%{extra_loads: loads}) do
    Enum.map_join(loads, "", fn %{"bzl" => bzl, "symbols" => symbols} ->
      ~s|load("#{bzl}", #{Enum.map_join(symbols, ", ", &~s|"#{&1}"|)})\n|
    end)
  end

  defp render_extra_attrs(%{extra_attrs: []}), do: ""

  defp render_extra_attrs(%{extra_attrs: attrs}) do
    Enum.map_join(attrs, "", fn line -> "\n    #{line}" end)
  end

  # The closure as data, for the caller's module extension to hand to hex_packages_extension.
  # A tuple per package keeps this one line per package; the extension names the fields.
  defp write_packages_bzl(config, entries) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        ~s|    ("#{e.name}", "#{e.pkg}", "#{e.version}", "#{e.sha256}"),|
      end)

    body = """
    \"\"\"The resolved Hex closure. Generated by #{config.generated_by} -- do not edit by hand.

    Each row is (app_name, hex_package_name, version, sha256). The two names differ where a
    package ships under another name on hex.pm -- chatterbox is published as ts_chatterbox.
    sha256 is the OUTER tarball checksum, the last field of a mix.lock entry, because that is
    what hex_archive downloads.
    \"\"\"

    HEX_PACKAGES = [
    #{rows}
    ]
    """

    write(config, "hex_packages.bzl", body)
  end

  defp write(config, name, body) do
    File.write!(Path.join(config.out_dir, name), body)
    {name, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
  end

  # One sorted `name<TAB>sha256` line per file. The drift test diffs name sets from this before
  # comparing content, so a package entering or leaving the closure is reported as such rather
  # than as a failed diff against a file that does not exist.
  defp write_manifest(config, written) do
    File.write!(config.manifest, Enum.map_join(written, "", fn {n, sha} -> "#{n}\t#{sha}\n" end))
  end

  defp warn(msg), do: IO.puts(:stderr, "WARNING: #{msg}")

  defp die(msg) do
    IO.puts(:stderr, "ERROR: #{msg}")
    System.halt(1)
  end
end

GenHexBazel.main(System.argv())

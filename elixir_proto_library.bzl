load(
    "//private:elixir_proto_library.bzl",
    _elixir_proto_library = "elixir_proto_library",
    _elixir_proto_toolchain = "elixir_proto_toolchain",
)

def elixir_proto_library(**kwargs):
    return _elixir_proto_library(**kwargs)

def elixir_proto_toolchain(**kwargs):
    return _elixir_proto_toolchain(**kwargs)

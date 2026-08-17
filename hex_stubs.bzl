load(
    "//private/hex:hex_stubs.bzl",
    _hex_stubs = "hex_stubs",
    _hex_stubs_test = "hex_stubs_test",
    _hex_stubs_write = "hex_stubs_write",
)

def hex_stubs(**kwargs):
    return _hex_stubs(**kwargs)

def hex_stubs_test(**kwargs):
    return _hex_stubs_test(**kwargs)

def hex_stubs_write(**kwargs):
    return _hex_stubs_write(**kwargs)

load(
    "//private:ex_unit_test.bzl",
    _ex_unit_test = "ex_unit_test",
)

# Label() rather than the bare string "@platforms//os:windows". A select() key
# written as a string is resolved against the repo mapping of the package that
# *instantiates* the macro, so a bare string would oblige every consumer to
# declare bazel_dep(name = "platforms") of their own, and fail with "No
# repository visible as '@platforms'" if they did not. Label() resolves against
# this module's repo mapping instead, where the dependency is declared.
#
# This did not arise while the key was @bazel_tools//src/conditions:host_windows,
# because bazel_tools is an implicit dependency of every module and is therefore
# visible from everywhere.
_IS_WINDOWS = select({
    Label("@platforms//os:windows"): True,
    "//conditions:default": False,
})

def ex_unit_test(**kwargs):
    _ex_unit_test(
        is_windows = _IS_WINDOWS,
        **kwargs
    )

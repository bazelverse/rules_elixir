defmodule Warnings.IoWarn do
  # A warning printed by code that runs at compile time. Unlike the
  # compiler's own warnings, it is not indented.
  IO.warn("a warning from IO.warn at compile time")

  def f, do: :ok
end

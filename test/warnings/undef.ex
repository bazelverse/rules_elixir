defmodule Warnings.Undef do
  def f, do: NoSuchModule.nope()
end

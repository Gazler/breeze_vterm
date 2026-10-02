defmodule Breeze.VTerm do
  @moduledoc """
  Utilities for embedded virtual terminal surfaces.

  This namespace is intentionally transport agnostic. It models terminal output
  and input bytes, but leaves PTY, SSH, and process ownership to applications.
  Pass `:on_reply` to `new/1` to forward terminal query replies to your transport.
  """

  alias Breeze.VTerm.Surface

  @doc "Creates a terminal surface. See `Breeze.VTerm.Surface.new/1` for options."
  defdelegate new(opts \\ []), to: Surface
  defdelegate write(surface, bytes), to: Surface
  defdelegate resize(surface, cols, rows), to: Surface
  defdelegate input(event), to: Surface
  defdelegate virtual_text(surface), to: Surface
end

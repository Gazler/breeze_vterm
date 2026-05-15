defmodule Breeze.VTerm do
  @moduledoc """
  Utilities for embedded virtual terminal surfaces.

  This namespace is intentionally transport agnostic. It models terminal output
  and input bytes, but leaves PTY, SSH, and process ownership to applications.
  """

  alias Breeze.VTerm.Surface

  defdelegate new(opts \\ []), to: Surface
  defdelegate write(surface, bytes), to: Surface
  defdelegate resize(surface, cols, rows), to: Surface
  defdelegate input(event), to: Surface
  defdelegate virtual_text(surface), to: Surface
end

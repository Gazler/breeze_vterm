defmodule Breeze.VTerm do
  @moduledoc """
  Utilities for embedded virtual terminal surfaces.

  This namespace is intentionally transport agnostic. It models terminal output
  and input bytes, but leaves PTY, SSH, and process ownership to applications.
  Pass `:on_reply` to `new/1` to forward terminal query replies to your transport.
  """

  alias Breeze.VTerm.{Implicit, Surface}

  @doc "Creates a terminal surface. See `Breeze.VTerm.Surface.new/1` for options."
  defdelegate new(opts \\ []), to: Surface
  defdelegate write(surface, bytes), to: Surface
  defdelegate resize(surface, cols, rows), to: Surface
  defdelegate input(event), to: Surface
  defdelegate input(surface, event), to: Surface
  defdelegate virtual_text(surface), to: Surface

  @doc """
  Handles selection scrolling timers in the owning Breeze view.

  Enable `selection_autoscroll={true}` on the terminal and forward its messages
  from the view's existing callback:

      def handle_info({Breeze.VTerm, :edge_scroll, _, _} = message, term),
        do: Breeze.VTerm.handle_info(message, term)

  Updates only the matching terminal's implicit state. Removed terminals and
  stale ticks do not request a render. Ordinary mouse-driven selection needs
  no message forwarding.
  """
  def handle_info({__MODULE__, :edge_scroll, id, token}, term) do
    next_term =
      Breeze.View.update_implicit(term, id, fn
        {Implicit, state} -> Implicit.scroll_tick(token, state)
        {_mod, state} -> state
      end)

    {:noreply, next_term, invalidate: next_term != term}
  end
end

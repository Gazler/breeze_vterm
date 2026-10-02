defmodule Breeze.VTerm.Components do
  @moduledoc """
  Breeze components for rendering `Breeze.VTerm` surfaces.
  """

  use Breeze.View

  import Breeze.Blocks, only: [merge_class: 2]

  attr(:id, :string, required: true)
  attr(:surface, :any, required: true)

  attr(:"cursor-blink", :boolean,
    default: true,
    doc: "Set false for a static cursor without blink ticks"
  )

  attr(:capture_breeze_shortcuts, :boolean, default: true)
  attr(:capture_control_keys, :boolean, default: true)
  attr(:capture_focus_keys, :boolean, default: true)
  attr(:class, :string, default: nil)
  attr(:style, :any, default: nil)
  attr(:rest, :global)

  def terminal(assigns) do
    surface = Map.get(assigns, :surface)
    cursor = cursor_info(surface)
    scrollback_rows = Breeze.VTerm.Surface.scrollback_rows(surface)
    line_count = Breeze.VTerm.Surface.line_count(surface)
    virtual_text = Breeze.VTerm.Surface.virtual_text(surface)

    assigns =
      assigns
      |> assign(surface: surface)
      |> assign(cursor: cursor)
      |> assign(scrollback_rows: scrollback_rows)
      |> assign(line_count: line_count)
      |> assign(virtual_text: virtual_text)
      |> assign(
        capture_breeze_shortcuts: boolean_attr(Map.get(assigns, :capture_breeze_shortcuts, true)),
        capture_control_keys: boolean_attr(Map.get(assigns, :capture_control_keys, true)),
        capture_focus_keys: boolean_attr(Map.get(assigns, :capture_focus_keys, true))
      )
      |> assign(
        class:
          merge_class(
            "width-full height-full overflow-scroll scrollbar-arrows bg",
            Map.get(assigns, :class)
          )
      )

    ~H"""
    <box
      id={@id}
      focusable
      implicit={Breeze.VTerm.Implicit}
      class={@class}
      style={Breeze.Blocks.inline_style(assigns)}
      cursor-blink={boolean_attr(Map.get(assigns, :"cursor-blink", true))}
      terminal-cols={@surface.cols}
      terminal-rows={@surface.rows}
      terminal-content-height={@line_count}
      terminal-scrollback-rows={@scrollback_rows}
      terminal-cursor-row={@cursor.row}
      terminal-cursor-col={@cursor.col}
      terminal-cursor-char={@cursor.char}
      terminal-capture-breeze-shortcuts={@capture_breeze_shortcuts}
      terminal-capture-control-keys={@capture_control_keys}
      terminal-capture-focus-keys={@capture_focus_keys}
      {@rest}
    >
      {@virtual_text}
    </box>
    """
  end

  defp cursor_info(%{cols: cols, rows: rows, cursor: %{row: row, col: col}, screen: screen}) do
    row = clamp(row, 0, rows - 1)
    col = clamp(col, 0, cols - 1)

    %{
      row: row,
      col: col,
      char: screen |> Enum.at(row, []) |> Enum.at(col, %{text: " "}) |> Map.get(:text, " ")
    }
  end

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)

  defp boolean_attr(value) when value in [false, "false"], do: "false"
  defp boolean_attr(_value), do: "true"
end

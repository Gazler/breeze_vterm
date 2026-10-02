defmodule Breeze.VTerm.Implicit do
  @moduledoc false

  alias Breeze.Implicit.Common
  alias Breeze.Theme
  alias Breeze.Viewport
  alias Breeze.VTerm.Surface

  def init(_children, root_attrs, last_state) do
    state =
      last_state
      |> Map.put(
        :cursor_blink?,
        Map.get(root_attrs, :"cursor-blink", true) not in [false, "false"]
      )
      |> Map.put(:cols, Map.get(root_attrs, :"terminal-cols"))
      |> Map.put(:rows, Map.get(root_attrs, :"terminal-rows"))
      |> Map.put(:content_height, int_attr(root_attrs, :"terminal-content-height", 0))
      |> Map.put(:scrollback_rows, int_attr(root_attrs, :"terminal-scrollback-rows", 0))
      |> Map.put(:offset_y, Map.get(last_state, :offset_y, 0))
      |> Map.put(:pinned_bottom, Map.get(last_state, :pinned_bottom, true))
      |> Map.put(:cursor, %{
        row: int_attr(root_attrs, :"terminal-cursor-row", 0),
        col: int_attr(root_attrs, :"terminal-cursor-col", 0),
        char: cursor_char(Map.get(root_attrs, :"terminal-cursor-char"))
      })

    meta =
      [
        active_when_focused: true,
        rerender_every: if(state.cursor_blink?, do: 500, else: :change),
        state_change_requires_rerender: false
      ]
      |> maybe_require_layout_rerender(last_state, state)

    meta =
      if truthy_attr?(Map.get(root_attrs, :"terminal-capture-breeze-shortcuts", true)) do
        meta
        |> Keyword.merge(captures_printable_keys: true, captures_keys: ["PageUp", "PageDown"])
        |> maybe_capture_control_keys(root_attrs)
        |> maybe_capture_focus_keys(root_attrs)
      else
        meta
      end

    {:ok, state, meta}
  end

  def handle_event(_, %{"key" => "PageUp", "element" => element}, state) do
    {:noreply, scroll_page(state, element, -1)}
  end

  def handle_event(_, %{"key" => "PageDown", "element" => element}, state) do
    {:noreply, scroll_page(state, element, 1)}
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "wheel_down"} = mouse, "element" => element},
        state
      ) do
    viewport = Viewport.from_dimensions(element)

    offset_y =
      effective_offset_y(state, viewport) + wheel_step(viewport) * Common.wheel_repeat(mouse)

    {:noreply, put_offset(state, offset_y, viewport)}
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "wheel_up"} = mouse, "element" => element},
        state
      ) do
    viewport = Viewport.from_dimensions(element)

    offset_y =
      effective_offset_y(state, viewport) - wheel_step(viewport) * Common.wheel_repeat(mouse)

    {:noreply, put_offset(state, offset_y, viewport)}
  end

  def handle_event(_, event, state) do
    case Surface.input(event) do
      bytes when is_binary(bytes) ->
        {{:change, %{input: bytes, event: event}}, pin_bottom(state, event)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_modifiers(:root, flags, state),
    do: [scroll_y: effective_offset_y(state, viewport_from_flags(flags))]

  def handle_modifiers(:child, _flags, _state), do: []

  defp maybe_require_layout_rerender(meta, last_state, state) do
    if layout_affecting_state_changed?(last_state, state) do
      Keyword.put(meta, :requires_layout_rerender, true)
    else
      meta
    end
  end

  defp layout_affecting_state_changed?(last_state, state) do
    Enum.any?([:cols, :rows, :content_height, :scrollback_rows, :offset_y], fn key ->
      Map.get(last_state, key) != Map.get(state, key)
    end)
  end

  def animate(:root, box, _flags, state, %{layout: layout} = ctx) when is_map(layout) do
    {:ok, box,
     overlays: [
       cursor_overlay(box, state, ctx, Map.get(layout, :left, 0), Map.get(layout, :top, 0))
     ]}
  end

  def animate(:root, box, _flags, state, ctx) do
    {:ok, box, overlays: [cursor_overlay(box, state, ctx, 0, 0)]}
  end

  def animate(:child, box, _flags, _state, _ctx), do: box

  defp viewport_from_flags(flags) do
    case Keyword.get(flags, :layout_element) do
      nil -> nil
      element -> Viewport.from_dimensions(element)
    end
  end

  defp cursor_overlay(box, state, ctx, left, top) do
    theme = Map.get(ctx, :theme)
    defaults = Theme.default_style(theme)
    cursor = Map.get(state, :cursor, default_cursor())
    viewport = Viewport.from_dimensions(Map.get(ctx, :layout))
    offset_y = effective_offset_y(state, viewport)
    row = Map.get(cursor, :row, 0)
    col = Map.get(cursor, :col, 0)
    char = Map.get(cursor, :char, " ")
    visible_row = Map.get(state, :scrollback_rows, 0) + row - offset_y
    cursor_visible? = visible_row >= 0 and visible_row < viewport.viewport_height
    overlay_row = max(visible_row, 0)

    %{
      x: left + content_left_offset(box) + col,
      y: top + content_top_offset(box) + overlay_row,
      char: char,
      foreground_color: Map.get(defaults, :background_color),
      background_color: Theme.color(theme, :cursor) || Theme.color(theme, :accent),
      visible?:
        cursor_visible? and
          (not Map.get(state, :cursor_blink?, true) or
             Breeze.TerminalOverlay.visible?(
               Map.get(ctx, :now, 0),
               Map.get(ctx, :last_interaction_at)
             ))
    }
  end

  defp default_cursor, do: %{row: 0, col: 0, char: " "}

  defp scroll_page(state, element, direction) do
    viewport = Viewport.from_dimensions(element)
    offset_y = effective_offset_y(state, viewport) + direction * page_step(viewport)

    state
    |> put_offset(offset_y, viewport)
    |> Map.update(:scroll_generation, 1, &(&1 + 1))
  end

  defp page_step(%Viewport{viewport_height: height}), do: max(height - 1, 1)

  defp wheel_step(_viewport), do: 3

  defp effective_offset_y(state, nil), do: Map.get(state, :offset_y, 0)

  defp effective_offset_y(state, %Viewport{} = viewport) do
    if Map.get(state, :pinned_bottom, true) do
      Viewport.max_scroll_y(viewport)
    else
      Viewport.clamp_scroll_y(Map.get(state, :offset_y, 0), viewport)
    end
  end

  defp put_offset(state, offset_y, viewport) do
    offset_y = Viewport.clamp_scroll_y(offset_y, viewport)
    max_offset_y = Viewport.max_scroll_y(viewport)

    state
    |> Map.put(:offset_y, offset_y)
    |> Map.put(:pinned_bottom, offset_y >= max_offset_y)
  end

  defp pin_bottom(state, %{"element" => element}) do
    viewport = Viewport.from_dimensions(element)

    state
    |> Map.put(:pinned_bottom, true)
    |> Map.put(:offset_y, Viewport.max_scroll_y(viewport))
  end

  defp pin_bottom(state, _event), do: Map.put(state, :pinned_bottom, true)

  defp int_attr(attrs, key, default) do
    case Map.get(attrs, key) do
      value when is_integer(value) -> max(value, 0)
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> max(int, 0)
      _ -> default
    end
  end

  defp truthy_attr?(value), do: value in [true, "true", nil]

  defp maybe_capture_control_keys(meta, attrs) do
    if truthy_attr?(Map.get(attrs, :"terminal-capture-control-keys", true)) do
      Keyword.put(meta, :captures_control_keys, true)
    else
      meta
    end
  end

  defp maybe_capture_focus_keys(meta, attrs) do
    if truthy_attr?(Map.get(attrs, :"terminal-capture-focus-keys", true)) do
      Keyword.put(meta, :captures_focus_keys, true)
    else
      meta
    end
  end

  defp cursor_char(value) when is_binary(value) and value != "", do: value
  defp cursor_char(_value), do: " "

  defp content_left_offset(%{style: style} = box) do
    border_left_offset(box) + style_value(style, :padding_left)
  end

  defp content_top_offset(%{style: style} = box) do
    border_top_offset(box) + style_value(style, :padding_top)
  end

  defp border_left_offset(%{style: %{border: border}}), do: if(border.left, do: 1, else: 0)
  defp border_left_offset(_box), do: 0
  defp border_top_offset(%{style: %{border: border}}), do: if(border.top, do: 1, else: 0)
  defp border_top_offset(_box), do: 0
  defp style_value(style, key), do: Map.get(style, key) || 0
end

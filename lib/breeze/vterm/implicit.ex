defmodule Breeze.VTerm.Implicit do
  @moduledoc false

  alias Breeze.Implicit.Common
  alias Breeze.Theme
  alias Breeze.Viewport
  alias Breeze.VTerm.{Selection, SelectionOverlay, Surface}

  @edge_scroll_interval 50

  def init(_children, root_attrs, last_state) do
    surface = Map.get(root_attrs, :"terminal-surface")
    selectable? = truthy_attr?(Map.get(root_attrs, :"terminal-selectable", false))

    selection_autoscroll? =
      Map.get(root_attrs, :"terminal-selection-autoscroll", false) not in [false, "false"]

    state =
      last_state
      |> restore_selection(surface, selectable?, selection_autoscroll?)
      |> Map.put(:id, Map.get(root_attrs, :id))
      |> Map.put(:selection_autoscroll?, selection_autoscroll?)
      |> Map.put(:copy_notice, Map.get(root_attrs, :"terminal-copy-notice"))
      |> Map.put(:surface, surface)
      |> Map.put(:selectable?, selectable?)
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

  def clear_selection(state), do: state |> stop_edge_scroll() |> Map.put(:selection, nil)

  defp restore_selection(state, surface, selectable?, autoscroll?) do
    if selectable? and not is_nil(state[:selection]) and
         surface == state[:surface] do
      if autoscroll?,
        do: Map.put_new(state, :edge_scroll, nil),
        else: stop_edge_scroll(state)
    else
      clear_selection(state)
    end
  end

  def blur(state) do
    state = stop_edge_scroll(state)
    if state.selection, do: put_in(state.selection.dragging?, false), else: state
  end

  # Called by the owning view through Breeze.VTerm.handle_info/2. Blur,
  # release and selection invalidation cancel the timer in this same state.
  def scroll_tick(token, %{edge_scroll: %{token: token} = edge} = state) do
    viewport = Viewport.from_dimensions(state[:__element__])

    if state.selection_autoscroll? and match?(%{dragging?: true}, state.selection) and
         edge.geometry == {viewport.viewport_width, viewport.viewport_height} do
      old_offset = effective_offset_y(state, viewport)
      elapsed = max(System.monotonic_time(:millisecond) - edge.started_at, 0)
      step = min(1 + div(elapsed, 400), 3)
      state = put_offset(state, old_offset + edge.direction * step, viewport)

      point =
        selection_point(state, %{"element" => viewport, "row" => edge.row, "col" => edge.col})

      state = put_in(state.selection.head, point)
      state = put_in(state.selection.moved?, true)

      if effective_offset_y(state, viewport) != old_offset and
           scrollable?(state, viewport, edge.direction) do
        schedule_edge_scroll(state)
      else
        stop_edge_scroll(state)
      end
    else
      stop_edge_scroll(state)
    end
  end

  def scroll_tick(_token, state), do: state

  # Keep the editable surface in the view process; the compositor only needs
  # visible selection runs and cursor flags.
  def animation_state(%{surface: %Surface{} = surface} = state, layout) do
    viewport = Viewport.from_dimensions(layout)

    state
    |> Map.put(:selection_highlights, selection_highlights(state, viewport))
    |> Map.put(:surface, %{cols: surface.cols, cursor_visible?: surface.cursor_visible?})
  end

  def animation_state(state, _layout), do: state

  def handle_event(
        _,
        %{"mouse" => %{"button" => "right", "action" => "press"}},
        %{selection: %{moved?: true, dragging?: false} = selection} = state
      ) do
    {{:change,
      %{copy: Selection.text(state.surface, selection.anchor, selection.head, selection.width)}},
     state}
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "left", "action" => "press"}} = event,
        %{selectable?: true, surface: %Surface{}} = state
      ) do
    point = selection_point(state, event)
    state = stop_edge_scroll(state)

    {{:change, %{selection: :start}},
     Map.put(state, :selection, %{
       anchor: point,
       head: point,
       dragging?: true,
       moved?: false,
       width: selection_width(state, event)
     }), capture_mouse: true}
  end

  def handle_event(
        _,
        %{"mouse" => %{"action" => action}} = event,
        %{selection: %{dragging?: true} = selection} = state
      )
      when action in ["move", "release"] do
    state =
      if action == "release", do: stop_edge_scroll(state), else: scroll_selection(state, event)

    point = selection_point(state, event)

    selection = %{
      selection
      | head: point,
        moved?: selection.moved? or point != selection.anchor,
        dragging?: action != "release"
    }

    state = %{state | selection: selection}

    if action == "release" and selection.moved? do
      {:noreply, state, capture_mouse: false}
    else
      if action == "release",
        do: {{:change, %{selection: :clear}}, clear_selection(state), capture_mouse: false},
        else: {:noreply, state, consumed: true}
    end
  end

  def handle_event(_, %{"key" => key}, %{selection: selection} = state)
      when key in ["Escape", "\e"] and not is_nil(selection) do
    {{:change, %{selection: :clear}}, clear_selection(state), capture_mouse: false}
  end

  def handle_event(_, %{"key" => "PageUp", "element" => element}, state) do
    {:noreply, scroll_page(stop_edge_scroll(state), element, -1)}
  end

  def handle_event(_, %{"key" => "PageDown", "element" => element}, state) do
    {:noreply, scroll_page(stop_edge_scroll(state), element, 1)}
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "wheel_down"} = mouse, "element" => element},
        state
      ) do
    viewport = Viewport.from_dimensions(element)

    offset_y =
      effective_offset_y(state, viewport) + wheel_step(viewport) * Common.wheel_repeat(mouse)

    {:noreply, put_offset(stop_edge_scroll(state), offset_y, viewport)}
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "wheel_up"} = mouse, "element" => element},
        state
      ) do
    viewport = Viewport.from_dimensions(element)

    offset_y =
      effective_offset_y(state, viewport) - wheel_step(viewport) * Common.wheel_repeat(mouse)

    {:noreply, put_offset(stop_edge_scroll(state), offset_y, viewport)}
  end

  def handle_event(_, event, state) do
    case Surface.input(Map.get(state, :surface), event) do
      bytes when is_binary(bytes) ->
        {{:change, %{input: bytes, event: event}}, pin_bottom(clear_selection(state), event),
         capture_mouse: false}

      _ ->
        if match?(%{selection: %{dragging?: true}}, state),
          do: {:noreply, state},
          else: {:noreply, state, capture_mouse: false}
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
     overlays:
       [
         cursor_overlay(box, state, ctx, Map.get(layout, :left, 0), Map.get(layout, :top, 0))
       ] ++ selection_overlays(box, state, ctx) ++ copy_notice_overlays(box, state, ctx)}
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

    cursor_visible? =
      visible_row >= 0 and visible_row < viewport.viewport_height and
        Map.get(Map.get(state, :surface) || %{}, :cursor_visible?, true)

    overlay_row = max(visible_row, 0)

    %{
      x: left + content_left_offset(box) + col,
      y: top + content_top_offset(box) + overlay_row,
      char: char,
      foreground_color: Map.get(defaults, :background_color),
      background_color: Theme.color(theme, :cursor) || Theme.color(theme, :accent),
      visible?:
        cursor_visible? and not match?(%{moved?: true}, Map.get(state, :selection)) and
          (not Map.get(state, :cursor_blink?, true) or
             Breeze.TerminalOverlay.visible?(
               Map.get(ctx, :now, 0),
               Map.get(ctx, :last_interaction_at)
             ))
    }
  end

  defp selection_overlays(
         box,
         %{selection: %{moved?: true}} = state,
         ctx
       ) do
    viewport = Viewport.from_dimensions(ctx[:layout])
    offset = effective_offset_y(state, viewport)
    defaults = Theme.default_style(Map.get(ctx, :theme))

    origin =
      {viewport.left + content_left_offset(box), viewport.top + content_top_offset(box) - offset}

    state
    |> Map.get_lazy(:selection_highlights, fn -> selection_highlights(state, viewport) end)
    |> SelectionOverlay.render(defaults, origin)
  end

  defp selection_overlays(_, _, _), do: []

  defp selection_highlights(
         %{selection: %{moved?: true} = selection, surface: surface} = state,
         viewport
       ) do
    Selection.highlights(
      surface,
      selection.anchor,
      selection.head,
      effective_offset_y(state, viewport),
      viewport.viewport_height,
      min(selection.width, viewport.viewport_width || surface.cols)
    )
  end

  defp selection_highlights(_, _), do: []

  defp copy_notice_overlays(box, %{copy_notice: count} = state, ctx) when not is_nil(count) do
    viewport = Viewport.from_dimensions(ctx[:layout])
    width = min(viewport.viewport_width || 0, state.cols || viewport.viewport_width || 0)
    height = min(viewport.viewport_height, state.rows || viewport.viewport_height)
    defaults = Theme.default_style(Map.get(ctx, :theme))
    origin = {viewport.left + content_left_offset(box), viewport.top + content_top_offset(box)}

    SelectionOverlay.copy_notice(count, defaults, origin, {width, height})
  end

  defp copy_notice_overlays(_, _, _), do: []

  defp selection_width(state, event) do
    viewport = Viewport.from_dimensions(event["element"])
    min(viewport.viewport_width || state.surface.cols, state.surface.cols)
  end

  defp scroll_selection(state, %{"mouse" => %{"action" => "move"}, "row" => row} = event)
       when is_integer(row) do
    viewport = Viewport.from_dimensions(event["element"])
    height = visible_buffer_height(state, viewport)

    direction =
      cond do
        height <= 0 -> 0
        row <= 0 -> -1
        row >= height - 1 -> 1
        true -> 0
      end

    automatic? =
      Map.get(state, :selection_autoscroll?, false) and is_binary(state[:id])

    cond do
      direction == 0 ->
        stop_edge_scroll(state)

      not automatic? ->
        put_offset(
          stop_edge_scroll(state),
          effective_offset_y(state, viewport) + direction,
          viewport
        )

      match?(%{direction: ^direction}, state.edge_scroll) ->
        %{state | edge_scroll: %{state.edge_scroll | row: row, col: event["col"] || 0}}

      true ->
        state =
          state
          |> stop_edge_scroll()
          |> put_offset(effective_offset_y(state, viewport) + direction, viewport)

        if scrollable?(state, viewport, direction) do
          edge = %{
            token: make_ref(),
            timer: nil,
            direction: direction,
            row: row,
            col: event["col"] || 0,
            geometry: {viewport.viewport_width, viewport.viewport_height},
            started_at: System.monotonic_time(:millisecond)
          }

          schedule_edge_scroll(%{state | edge_scroll: edge})
        else
          state
        end
    end
  end

  defp scroll_selection(state, _event), do: state

  defp scrollable?(state, viewport, -1), do: effective_offset_y(state, viewport) > 0

  defp scrollable?(state, viewport, 1),
    do: effective_offset_y(state, viewport) < Viewport.max_scroll_y(viewport)

  defp schedule_edge_scroll(state) do
    timer =
      Process.send_after(
        self(),
        {Breeze.VTerm, :edge_scroll, state.id, state.edge_scroll.token},
        @edge_scroll_interval
      )

    put_in(state.edge_scroll.timer, timer)
  end

  defp stop_edge_scroll(state) do
    if timer = get_in(state, [:edge_scroll, :timer]), do: Process.cancel_timer(timer)
    Map.put(state, :edge_scroll, nil)
  end

  defp selection_point(state, event) do
    viewport = Viewport.from_dimensions(event["element"])

    row =
      (event["row"] || 0)
      |> max(0)
      |> min(max(visible_buffer_height(state, viewport) - 1, 0))

    col =
      (event["col"] || 0)
      |> max(0)
      |> min(max(min(viewport.viewport_width || state.surface.cols, state.surface.cols) - 1, 0))

    {row + effective_offset_y(state, viewport), col}
  end

  defp visible_buffer_height(state, viewport) do
    remaining_rows = Surface.line_count(state.surface) - effective_offset_y(state, viewport)
    max(min(viewport.viewport_height, remaining_rows), 0)
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

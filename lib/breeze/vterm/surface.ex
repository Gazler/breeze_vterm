defmodule Breeze.VTerm.Surface do
  @moduledoc """
  A small terminal screen model for embedding terminal-like byte streams in Breeze.

  The surface is transport agnostic: callers feed output bytes with `write/2`,
  forward encoded input bytes from `input/1` to their backend, and render the
  current screen with `virtual_text/1`.
  """

  alias BackBreeze.Ucwidth
  alias BackBreeze.VirtualText

  defstruct cols: 80,
            rows: 24,
            cursor: %{row: 0, col: 0},
            style: %{},
            screen: [],
            scrollback: [],
            buffer: "",
            saved_cursor: nil,
            saved_screen_cursor: nil,
            saved_screen: nil,
            saved_scrollback: nil,
            saved_style: nil,
            alt_screen?: false,
            version: 0

  @type color :: 0..255 | {0..255, 0..255, 0..255}
  @type style :: %{
          optional(:foreground_color) => color(),
          optional(:background_color) => color(),
          optional(:bold) => boolean(),
          optional(:italic) => boolean(),
          optional(:reverse) => boolean()
        }
  @type cell :: %{text: String.t(), style: style()}
  @type t :: %__MODULE__{
          cols: pos_integer(),
          rows: pos_integer(),
          cursor: %{row: non_neg_integer(), col: non_neg_integer()},
          style: style(),
          screen: [[cell()]],
          scrollback: [[cell()]],
          buffer: binary(),
          saved_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen: [[cell()]] | nil,
          saved_scrollback: [[cell()]] | nil,
          saved_style: style() | nil,
          alt_screen?: boolean(),
          version: non_neg_integer()
        }

  @ansi_8_color_count 8

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    cols = positive_int(Keyword.get(opts, :cols, Keyword.get(opts, :columns, 80)), 80)
    rows = positive_int(Keyword.get(opts, :rows, 24), 24)

    %__MODULE__{
      cols: cols,
      rows: rows,
      screen: blank_screen(cols, rows),
      cursor: %{row: 0, col: 0}
    }
  end

  @spec write(t(), binary()) :: t()
  def write(%__MODULE__{} = surface, bytes) when is_binary(bytes) do
    {surface, buffer} = consume(%{surface | buffer: ""}, surface.buffer <> bytes)
    %{surface | buffer: buffer, version: surface.version + 1}
  end

  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = surface, cols, rows) do
    cols = positive_int(cols, surface.cols)
    rows = positive_int(rows, surface.rows)

    screen =
      surface.screen
      |> Enum.take(rows)
      |> Enum.map(&resize_row(&1, cols))
      |> pad_rows(rows, cols)

    saved_screen =
      case surface.saved_screen do
        nil ->
          nil

        saved_screen ->
          saved_screen
          |> Enum.take(rows)
          |> Enum.map(&resize_row(&1, cols))
          |> pad_rows(rows, cols)
      end

    %{
      surface
      | cols: cols,
        rows: rows,
        screen: screen,
        cursor: %{
          row: min(surface.cursor.row, rows - 1),
          col: min(surface.cursor.col, cols - 1)
        },
        saved_screen: saved_screen,
        saved_cursor: resize_saved_cursor(surface.saved_cursor, cols, rows),
        saved_screen_cursor: resize_saved_cursor(surface.saved_screen_cursor, cols, rows),
        version: surface.version + 1
    }
  end

  @spec input(map() | binary()) :: binary() | nil
  def input(%{"__batched_printable__" => true, "key" => key}) when is_binary(key), do: key
  def input(%{"key" => key}) when key in ["Backspace", "\x7f", "\b"], do: "\x7f"
  def input(%{"ctrlKey" => true, "key" => key}) when is_binary(key), do: ctrl_input(key)

  def input(%{"altKey" => true, "key" => key}) when is_binary(key) do
    case input(%{"key" => key}) do
      bytes when is_binary(bytes) -> "\e" <> bytes
      nil -> nil
    end
  end

  def input(%{"key" => key}) when is_binary(key), do: input(key)
  def input("Enter"), do: "\r"
  def input("Tab"), do: "\t"
  def input("\t"), do: "\t"
  def input("ShiftTab"), do: "\e[Z"
  def input("Escape"), do: "\e"
  def input("Backspace"), do: "\x7f"
  def input("\x7f"), do: "\x7f"
  def input("\b"), do: "\x7f"
  def input("Delete"), do: "\e[3~"
  def input("ArrowUp"), do: "\e[A"
  def input("ArrowDown"), do: "\e[B"
  def input("ArrowRight"), do: "\e[C"
  def input("ArrowLeft"), do: "\e[D"
  def input("Home"), do: "\e[H"
  def input("End"), do: "\e[F"
  def input("PageUp"), do: "\e[5~"
  def input("PageDown"), do: "\e[6~"

  def input(key) when is_binary(key) do
    if printable_input?(key), do: key
  end

  def input(_event), do: nil

  @spec virtual_text(t()) :: VirtualText.t()
  def virtual_text(%__MODULE__{} = surface) do
    VirtualText.lazy(
      cache_key:
        {:breeze_terminal_surface, surface.version, surface.cols, surface.rows,
         :erlang.phash2(surface.scrollback), :erlang.phash2(surface.screen)},
      intrinsic_width: surface.cols,
      line_count_fn: fn _width -> line_count(surface) end,
      slice_fn: fn start_line, count, width ->
        content_slice(surface, start_line, count, width)
      end
    )
  end

  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{} = surface), do: scrollback_rows(surface) + surface.rows

  @spec scrollback_rows(t()) :: non_neg_integer()
  def scrollback_rows(%__MODULE__{} = surface), do: length(surface.scrollback)

  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: [list({String.t(), style()})]
  def slice(%__MODULE__{} = surface, start_line, count) do
    surface.screen
    |> Enum.slice(start_line, count)
    |> Enum.map(&row_segments/1)
  end

  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{} = surface) do
    Enum.map(surface.screen, fn row ->
      row
      |> Enum.map(& &1.text)
      |> IO.iodata_to_binary()
    end)
  end

  defp content_slice(surface, start_line, count, width) do
    width = clamp(width || surface.cols, 0, surface.cols)

    surface.scrollback
    |> Kernel.++(surface.screen)
    |> Enum.slice(start_line, count)
    |> Enum.map(&Enum.take(&1, width))
    |> Enum.map(&row_segments/1)
  end

  defp consume(surface, ""), do: {surface, ""}

  defp consume(surface, <<?\e, ?[, rest::binary>>) do
    case take_csi(rest) do
      {:ok, params, final, rest} ->
        surface
        |> apply_csi(params, final)
        |> consume(rest)

      :incomplete ->
        {surface, <<?\e, ?[, rest::binary>>}
    end
  end

  defp consume(surface, <<?\e, ?], rest::binary>>) do
    case take_osc(rest) do
      {:ok, rest} -> consume(surface, rest)
      :incomplete -> {surface, <<?\e, ?], rest::binary>>}
    end
  end

  defp consume(surface, <<?\e, ?(, _charset, rest::binary>>), do: consume(surface, rest)
  defp consume(surface, <<?\e, ?), _charset, rest::binary>>), do: consume(surface, rest)
  defp consume(surface, <<?\e, ?7, rest::binary>>), do: surface |> save_cursor() |> consume(rest)

  defp consume(surface, <<?\e, ?8, rest::binary>>),
    do: surface |> restore_cursor() |> consume(rest)

  defp consume(surface, <<?\e>>), do: {surface, <<?\e>>}

  defp consume(surface, <<?\e, _ignored, rest::binary>>) do
    consume(surface, rest)
  end

  defp consume(surface, <<?\r, rest::binary>>) do
    surface
    |> put_cursor_col(0)
    |> consume(rest)
  end

  defp consume(surface, <<?\n, rest::binary>>) do
    surface
    |> linefeed()
    |> consume(rest)
  end

  defp consume(surface, <<?\b, rest::binary>>) do
    surface
    |> put_cursor_col(max(surface.cursor.col - 1, 0))
    |> consume(rest)
  end

  defp consume(surface, <<?\t, rest::binary>>) do
    spaces = 8 - rem(surface.cursor.col, 8)

    surface =
      Enum.reduce(1..spaces, surface, fn _index, acc ->
        put_grapheme(acc, " ")
      end)

    consume(surface, rest)
  end

  defp consume(surface, bytes) do
    case next_grapheme(bytes) do
      {:ok, grapheme, rest} ->
        surface
        |> put_grapheme(grapheme)
        |> consume(rest)

      :incomplete ->
        {surface, bytes}

      {:drop, rest} ->
        consume(surface, rest)
    end
  end

  defp take_csi(bytes), do: do_take_csi(bytes, [])

  defp take_osc(bytes), do: do_take_osc(bytes)

  defp do_take_osc(""), do: :incomplete
  defp do_take_osc(<<?\a, rest::binary>>), do: {:ok, rest}
  defp do_take_osc(<<?\e, ?\\, rest::binary>>), do: {:ok, rest}
  defp do_take_osc(<<_char, rest::binary>>), do: do_take_osc(rest)

  defp do_take_csi("", _acc), do: :incomplete

  defp do_take_csi(<<final, rest::binary>>, acc) when final in 0x40..0x7E do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), <<final>>, rest}
  end

  defp do_take_csi(<<char, rest::binary>>, acc), do: do_take_csi(rest, [<<char>> | acc])

  defp apply_csi(surface, params, "m"), do: apply_sgr(surface, sgr_params(params))
  defp apply_csi(surface, params, "h"), do: apply_private_mode(surface, params, true)
  defp apply_csi(surface, params, "l"), do: apply_private_mode(surface, params, false)
  defp apply_csi(surface, _params, "s"), do: save_cursor(surface)
  defp apply_csi(surface, _params, "u"), do: restore_cursor(surface)

  defp apply_csi(surface, params, final) when final in ["H", "f"] do
    values = csi_params(params)
    row = max(csi_param(values, 0, 1) - 1, 0)
    col = max(csi_param(values, 1, 1) - 1, 0)
    put_cursor(surface, row, col)
  end

  defp apply_csi(surface, params, "A") do
    put_cursor_row(surface, surface.cursor.row - csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "B") do
    put_cursor_row(surface, surface.cursor.row + csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "C") do
    put_cursor_col(surface, surface.cursor.col + csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "D") do
    put_cursor_col(surface, surface.cursor.col - csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "G") do
    col = max(csi_param(csi_params(params), 0, 1) - 1, 0)
    put_cursor_col(surface, col)
  end

  defp apply_csi(surface, params, "d") do
    row = max(csi_param(csi_params(params), 0, 1) - 1, 0)
    put_cursor_row(surface, row)
  end

  defp apply_csi(surface, params, "J") do
    case csi_param(csi_params(params), 0, 0) do
      1 -> clear_to_cursor(surface)
      2 -> %{surface | screen: blank_screen(surface.cols, surface.rows)}
      3 -> %{surface | scrollback: []}
      _ -> clear_from_cursor(surface)
    end
  end

  defp apply_csi(surface, params, "K") do
    case csi_param(csi_params(params), 0, 0) do
      1 -> clear_line_to_cursor(surface)
      2 -> put_row(surface, surface.cursor.row, blank_row(surface.cols))
      _ -> clear_line_from_cursor(surface)
    end
  end

  defp apply_csi(surface, params, "S") do
    scroll_up(surface, csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "T") do
    scroll_down(surface, csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, _params, _final), do: surface

  defp sgr_params(""), do: [0]

  defp sgr_params(params) do
    params
    |> String.split(";", trim: false)
    |> Enum.map(fn
      "" -> 0
      value -> parse_int(value, 0)
    end)
  end

  defp csi_params(""), do: []

  defp csi_params(params) do
    params
    |> String.trim_leading("?")
    |> String.split(";", trim: false)
    |> Enum.map(fn
      "" -> nil
      value -> parse_int(value, nil)
    end)
  end

  defp csi_param(values, index, default) do
    case Enum.at(values, index) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp apply_private_mode(surface, "?" <> params, enabled?) do
    params
    |> csi_params()
    |> Enum.reduce(surface, fn
      mode, acc when mode in [47, 1047, 1049] and enabled? -> enter_alt_screen(acc)
      mode, acc when mode in [47, 1047, 1049] -> leave_alt_screen(acc)
      1048, acc when enabled? -> save_cursor(acc)
      1048, acc -> restore_cursor(acc)
      _mode, acc -> acc
    end)
  end

  defp apply_private_mode(surface, _params, _enabled?), do: surface

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp apply_sgr(surface, params), do: %{surface | style: apply_sgr_params(surface.style, params)}

  defp apply_sgr_params(style, []), do: style
  defp apply_sgr_params(_style, [0 | rest]), do: apply_sgr_params(%{}, rest)

  defp apply_sgr_params(style, [1 | rest]),
    do: apply_sgr_params(Map.put(style, :bold, true), rest)

  defp apply_sgr_params(style, [3 | rest]),
    do: apply_sgr_params(Map.put(style, :italic, true), rest)

  defp apply_sgr_params(style, [7 | rest]),
    do: apply_sgr_params(Map.put(style, :reverse, true), rest)

  defp apply_sgr_params(style, [22 | rest]), do: apply_sgr_params(Map.delete(style, :bold), rest)

  defp apply_sgr_params(style, [23 | rest]),
    do: apply_sgr_params(Map.delete(style, :italic), rest)

  defp apply_sgr_params(style, [27 | rest]),
    do: apply_sgr_params(Map.delete(style, :reverse), rest)

  defp apply_sgr_params(style, [39 | rest]),
    do: apply_sgr_params(Map.delete(style, :foreground_color), rest)

  defp apply_sgr_params(style, [49 | rest]),
    do: apply_sgr_params(Map.delete(style, :background_color), rest)

  defp apply_sgr_params(style, [fg | rest]) when fg in 30..37 do
    apply_sgr_params(Map.put(style, :foreground_color, fg - 30), rest)
  end

  defp apply_sgr_params(style, [fg | rest]) when fg in 90..97 do
    apply_sgr_params(Map.put(style, :foreground_color, fg - 90 + @ansi_8_color_count), rest)
  end

  defp apply_sgr_params(style, [bg | rest]) when bg in 40..47 do
    apply_sgr_params(Map.put(style, :background_color, bg - 40), rest)
  end

  defp apply_sgr_params(style, [bg | rest]) when bg in 100..107 do
    apply_sgr_params(Map.put(style, :background_color, bg - 100 + @ansi_8_color_count), rest)
  end

  defp apply_sgr_params(style, [38, 5, color | rest]) when is_integer(color) do
    apply_sgr_params(Map.put(style, :foreground_color, clamp_color_index(color)), rest)
  end

  defp apply_sgr_params(style, [48, 5, color | rest]) when is_integer(color) do
    apply_sgr_params(Map.put(style, :background_color, clamp_color_index(color)), rest)
  end

  defp apply_sgr_params(style, [38, 2, red, green, blue | rest]) do
    color = {clamp_rgb(red), clamp_rgb(green), clamp_rgb(blue)}
    apply_sgr_params(Map.put(style, :foreground_color, color), rest)
  end

  defp apply_sgr_params(style, [48, 2, red, green, blue | rest]) do
    color = {clamp_rgb(red), clamp_rgb(green), clamp_rgb(blue)}
    apply_sgr_params(Map.put(style, :background_color, color), rest)
  end

  defp apply_sgr_params(style, [_unknown | rest]), do: apply_sgr_params(style, rest)

  defp enter_alt_screen(%{alt_screen?: true} = surface), do: surface

  defp enter_alt_screen(surface) do
    %{
      surface
      | alt_screen?: true,
        saved_screen_cursor: surface.cursor,
        saved_screen: surface.screen,
        saved_scrollback: surface.scrollback,
        saved_style: surface.style,
        cursor: %{row: 0, col: 0},
        screen: blank_screen(surface.cols, surface.rows),
        scrollback: []
    }
  end

  defp leave_alt_screen(%{alt_screen?: false} = surface), do: surface

  defp leave_alt_screen(surface) do
    %{
      surface
      | alt_screen?: false,
        cursor: surface.saved_screen_cursor || %{row: 0, col: 0},
        screen: surface.saved_screen || blank_screen(surface.cols, surface.rows),
        scrollback: surface.saved_scrollback || [],
        style: surface.saved_style || %{},
        saved_screen_cursor: nil,
        saved_screen: nil,
        saved_scrollback: nil,
        saved_style: nil
    }
  end

  defp save_cursor(surface), do: %{surface | saved_cursor: surface.cursor}

  defp restore_cursor(%{saved_cursor: %{row: row, col: col}} = surface),
    do: put_cursor(surface, row, col)

  defp restore_cursor(surface), do: surface

  defp put_grapheme(surface, grapheme) do
    width = grapheme_width(grapheme)

    surface =
      if surface.cursor.col + width > surface.cols do
        surface |> put_cursor_col(0) |> linefeed()
      else
        surface
      end

    cell = %{text: grapheme, style: surface.style}

    surface =
      surface
      |> put_cell(surface.cursor.row, surface.cursor.col, cell)
      |> fill_wide_continuation(width)

    put_cursor_col(surface, surface.cursor.col + width)
  end

  defp fill_wide_continuation(surface, width) when width <= 1, do: surface

  defp fill_wide_continuation(surface, width) do
    Enum.reduce(1..(width - 1), surface, fn offset, acc ->
      col = surface.cursor.col + offset

      if col < surface.cols do
        put_cell(acc, surface.cursor.row, col, wide_continuation_cell(surface.style))
      else
        acc
      end
    end)
  end

  defp put_cell(surface, row, col, cell) do
    current_row = Enum.at(surface.screen, row, blank_row(surface.cols))
    put_row(surface, row, List.replace_at(current_row, col, cell))
  end

  defp put_row(surface, row, cells) do
    %{surface | screen: List.replace_at(surface.screen, row, cells)}
  end

  defp linefeed(surface) do
    next_row = surface.cursor.row + 1

    if next_row >= surface.rows do
      [dropped | rest] = surface.screen

      %{
        surface
        | cursor: %{surface.cursor | row: surface.rows - 1},
          screen: rest ++ [blank_row(surface.cols)],
          scrollback: surface.scrollback ++ [dropped]
      }
    else
      put_cursor_row(surface, next_row)
    end
  end

  defp scroll_up(surface, count) do
    count = clamp(count, 0, surface.rows)
    {dropped, rest} = Enum.split(surface.screen, count)

    %{
      surface
      | screen: rest ++ repeat(count, fn -> blank_row(surface.cols) end),
        scrollback: surface.scrollback ++ dropped
    }
  end

  defp scroll_down(surface, count) do
    count = clamp(count, 0, surface.rows)
    keep = max(surface.rows - count, 0)

    %{
      surface
      | screen:
          repeat(count, fn -> blank_row(surface.cols) end) ++
            Enum.take(surface.screen, keep)
    }
  end

  defp clear_from_cursor(surface) do
    Enum.reduce(surface.cursor.row..(surface.rows - 1), surface, fn row, acc ->
      first_col = if row == surface.cursor.row, do: surface.cursor.col, else: 0
      cells = Enum.at(acc.screen, row, blank_row(acc.cols))

      cleared =
        cells
        |> Enum.with_index()
        |> Enum.map(fn
          {_cell, col} when col >= first_col -> blank_cell()
          {cell, _col} -> cell
        end)

      put_row(acc, row, cleared)
    end)
  end

  defp clear_to_cursor(surface) do
    Enum.reduce(0..surface.cursor.row, surface, fn row, acc ->
      last_col = if row == surface.cursor.row, do: surface.cursor.col, else: surface.cols - 1
      cells = Enum.at(acc.screen, row, blank_row(acc.cols))

      cleared =
        cells
        |> Enum.with_index()
        |> Enum.map(fn
          {_cell, col} when col <= last_col -> blank_cell()
          {cell, _col} -> cell
        end)

      put_row(acc, row, cleared)
    end)
  end

  defp clear_line_from_cursor(surface) do
    cells = Enum.at(surface.screen, surface.cursor.row, blank_row(surface.cols))

    cleared =
      cells
      |> Enum.with_index()
      |> Enum.map(fn
        {_cell, col} when col >= surface.cursor.col -> blank_cell()
        {cell, _col} -> cell
      end)

    put_row(surface, surface.cursor.row, cleared)
  end

  defp clear_line_to_cursor(surface) do
    cells = Enum.at(surface.screen, surface.cursor.row, blank_row(surface.cols))

    cleared =
      cells
      |> Enum.with_index()
      |> Enum.map(fn
        {_cell, col} when col <= surface.cursor.col -> blank_cell()
        {cell, _col} -> cell
      end)

    put_row(surface, surface.cursor.row, cleared)
  end

  defp row_segments(row) do
    row
    |> Enum.reduce([], fn %{text: text, style: style}, acc ->
      if text == "" do
        acc
      else
        append_segment(acc, text, style)
      end
    end)
    |> Enum.reverse()
  end

  defp append_segment([{text, style} | rest], next_text, style),
    do: [{text <> next_text, style} | rest]

  defp append_segment(acc, text, style), do: [{text, style} | acc]

  defp put_cursor(surface, row, col) do
    surface
    |> put_cursor_row(row)
    |> put_cursor_col(col)
  end

  defp put_cursor_row(surface, row) do
    %{surface | cursor: %{surface.cursor | row: clamp(row, 0, surface.rows - 1)}}
  end

  defp put_cursor_col(surface, col) do
    %{surface | cursor: %{surface.cursor | col: clamp(col, 0, surface.cols)}}
  end

  defp next_grapheme(bytes) do
    case String.next_grapheme(bytes) do
      {grapheme, rest} -> {:ok, grapheme, rest}
      nil -> :incomplete
    end
  rescue
    ArgumentError ->
      <<_byte, rest::binary>> = bytes
      {:drop, rest}
  end

  defp printable_input?(key) do
    key != "" and String.printable?(key) and not String.match?(key, ~r/[\x00-\x1F\x7F]/u)
  end

  defp ctrl_input(key) when byte_size(key) == 1 do
    key =
      key
      |> String.downcase()
      |> :binary.first()

    cond do
      key in ?a..?z -> <<key - ?a + 1>>
      key == ?[ -> "\e"
      key == ?] -> <<29>>
      true -> nil
    end
  end

  defp ctrl_input("Backspace"), do: "\x17"
  defp ctrl_input(_key), do: nil

  defp blank_screen(cols, rows), do: repeat(rows, fn -> blank_row(cols) end)
  defp blank_row(cols), do: repeat(cols, &blank_cell/0)
  defp blank_cell, do: %{text: " ", style: %{}}
  defp wide_continuation_cell(style), do: %{text: "", style: style}

  defp resize_saved_cursor(nil, _cols, _rows), do: nil

  defp resize_saved_cursor(%{row: row, col: col}, cols, rows) do
    %{row: min(row, rows - 1), col: min(col, cols - 1)}
  end

  defp resize_row(row, cols) do
    row
    |> Enum.take(cols)
    |> then(fn row -> row ++ repeat(max(cols - length(row), 0), &blank_cell/0) end)
  end

  defp pad_rows(screen, rows, cols) do
    screen ++ repeat(max(rows - length(screen), 0), fn -> blank_row(cols) end)
  end

  defp repeat(count, fun) when count <= 0 and is_function(fun, 0), do: []
  defp repeat(count, fun) when is_function(fun, 0), do: Enum.map(1..count, fn _ -> fun.() end)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp grapheme_width(grapheme), do: max(Ucwidth.width(grapheme), 1)
  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
  defp clamp_color_index(value), do: clamp(value, 0, 255)
  defp clamp_rgb(value), do: clamp(value || 0, 0, 255)
end

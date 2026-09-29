defmodule Breeze.VTerm.Surface do
  @moduledoc """
  A small terminal screen model for embedding terminal-like byte streams in Breeze.

  The surface is transport agnostic: callers feed output bytes with `write/2`,
  forward encoded input bytes from `input/1` to their backend, and render the
  current screen with `virtual_text/1`.
  """

  alias BackBreeze.Ucwidth
  alias BackBreeze.VirtualText

  defstruct id: nil,
            cols: 80,
            rows: 24,
            scrollback_limit: 10_000,
            cursor: %{row: 0, col: 0},
            style: %{},
            screen: [],
            scrollback: {[], []},
            scrollback_count: 0,
            buffer: "",
            parser_state: :ground,
            saved_cursor: nil,
            saved_screen_cursor: nil,
            saved_screen: nil,
            saved_scrollback: nil,
            saved_scrollback_count: 0,
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
  @type row :: [cell()]
  @type t :: %__MODULE__{
          id: reference(),
          cols: pos_integer(),
          rows: pos_integer(),
          scrollback_limit: non_neg_integer() | :infinity,
          cursor: %{row: non_neg_integer(), col: non_neg_integer()},
          style: style(),
          screen: [row()],
          scrollback: :queue.queue(row()),
          scrollback_count: non_neg_integer(),
          buffer: binary(),
          parser_state:
            :ground | :osc | :osc_escape | :discard_csi | {:csi, [byte()], non_neg_integer()},
          saved_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen: [row()] | nil,
          saved_scrollback: :queue.queue(row()) | nil,
          saved_scrollback_count: non_neg_integer(),
          saved_style: style() | nil,
          alt_screen?: boolean(),
          version: non_neg_integer()
        }

  @ansi_8_color_count 8
  @default_scrollback_limit 10_000
  @max_csi_bytes 256

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    cols = positive_int(Keyword.get(opts, :cols, Keyword.get(opts, :columns, 80)), 80)
    rows = positive_int(Keyword.get(opts, :rows, 24), 24)

    scrollback_limit =
      scrollback_limit(
        Keyword.get(
          opts,
          :scrollback_limit,
          Keyword.get(opts, :max_scrollback_rows, @default_scrollback_limit)
        )
      )

    %__MODULE__{
      id: make_ref(),
      cols: cols,
      rows: rows,
      scrollback_limit: scrollback_limit,
      screen: blank_screen(cols, rows),
      scrollback: :queue.new(),
      scrollback_count: 0,
      cursor: %{row: 0, col: 0}
    }
  end

  @spec write(t(), binary()) :: t()
  def write(%__MODULE__{} = surface, bytes) when is_binary(bytes) do
    {surface, buffer} = consume(%{surface | buffer: ""}, surface.buffer <> bytes)
    %{surface | buffer: :binary.copy(buffer), version: surface.version + 1}
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
        {:breeze_terminal_surface, surface.id, surface.version, surface.cols, surface.rows},
      cache?: false,
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
  def scrollback_rows(%__MODULE__{} = surface), do: surface.scrollback_count

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

    surface
    |> rows_slice(start_line, count)
    |> Enum.map(&Enum.take(&1, width))
    |> Enum.map(&row_segments/1)
  end

  defp rows_slice(_surface, _start_line, count) when count <= 0, do: []

  defp rows_slice(surface, start_line, count) do
    start_line = max(start_line, 0)
    scrollback_count = surface.scrollback_count

    cond do
      start_line >= scrollback_count ->
        Enum.slice(surface.screen, start_line - scrollback_count, count)

      start_line + count <= scrollback_count ->
        queue_slice(surface.scrollback, start_line, count)

      true ->
        scrollback_rows =
          queue_slice(surface.scrollback, start_line, scrollback_count - start_line)

        screen_rows = Enum.slice(surface.screen, 0, count - length(scrollback_rows))
        scrollback_rows ++ screen_rows
    end
  end

  defp queue_slice(_queue, start, count) when count <= 0 or start < 0, do: []

  defp queue_slice(queue, start, count) do
    {_before, rest} = :queue.split(start, queue)
    {slice, _after} = :queue.split(count, rest)
    :queue.to_list(slice)
  end

  defp consume(%{parser_state: :osc} = surface, bytes), do: consume_osc(surface, bytes)

  defp consume(%{parser_state: :osc_escape} = surface, ""), do: {surface, ""}

  defp consume(%{parser_state: :osc_escape} = surface, <<?\\, rest::binary>>),
    do: consume(%{surface | parser_state: :ground}, rest)

  defp consume(%{parser_state: :osc_escape} = surface, bytes),
    do: consume_osc(%{surface | parser_state: :osc}, bytes)

  defp consume(%{parser_state: {:csi, params, count}} = surface, bytes),
    do: consume_csi(surface, bytes, params, count)

  defp consume(%{parser_state: :discard_csi} = surface, bytes),
    do: consume_csi(surface, bytes, [], @max_csi_bytes + 1)

  defp consume(surface, ""), do: {surface, ""}

  defp consume(surface, <<?\e, ?[, rest::binary>>),
    do: consume_csi(surface, rest, [], 0)

  defp consume(surface, <<?\e, ?], rest::binary>>),
    do: consume_osc(surface, rest)

  defp consume(surface, <<?\e, charset>>) when charset in [?(, ?)],
    do: {surface, <<?\e, charset>>}

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

  # Controls such as the shell's backspace bell must never reach rendered text.
  defp consume(surface, <<char, rest::binary>>) when char < 0x20 or char == 0x7F,
    do: consume(surface, rest)

  defp consume(surface, <<char, _rest::binary>> = bytes) when char in 0x20..0x7E do
    {run, rest} = take_printable_ascii(bytes)

    surface
    |> put_ascii_run(run)
    |> consume(rest)
  end

  # UTF-8 encoded C1 controls are not printable text either.
  defp consume(surface, <<0xC2, char, rest::binary>>) when char in 0x80..0x9F,
    do: consume(surface, rest)

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

  defp take_printable_ascii(bytes), do: do_take_printable_ascii(bytes, bytes, 0)

  defp do_take_printable_ascii(original, <<char, rest::binary>>, count)
       when char in 0x20..0x7E,
       do: do_take_printable_ascii(original, rest, count + 1)

  defp do_take_printable_ascii(_original, rest, 0), do: {"", rest}

  defp do_take_printable_ascii(original, rest, count) do
    run = binary_part(original, 0, count)
    {run, rest}
  end

  # OSC payloads are unsupported: discard as they arrive, retaining only whether
  # an ESC might be the first half of a split string terminator.
  defp consume_osc(surface, ""), do: {%{surface | parser_state: :osc}, ""}

  defp consume_osc(surface, <<char, rest::binary>>) when char in [7, 24, 26],
    do: consume(%{surface | parser_state: :ground}, rest)

  defp consume_osc(surface, <<?\e, rest::binary>>),
    do: consume(%{surface | parser_state: :osc_escape}, rest)

  defp consume_osc(surface, <<_char, rest::binary>>), do: consume_osc(surface, rest)

  defp consume_csi(surface, "", _params, count) when count > @max_csi_bytes,
    do: {%{surface | parser_state: :discard_csi}, ""}

  defp consume_csi(surface, "", params, count),
    do: {%{surface | parser_state: {:csi, params, count}}, ""}

  defp consume_csi(surface, <<?\e, _::binary>> = bytes, _params, _count),
    do: consume(%{surface | parser_state: :ground}, bytes)

  defp consume_csi(surface, <<char, rest::binary>>, _params, _count) when char in [24, 26],
    do: consume(%{surface | parser_state: :ground}, rest)

  defp consume_csi(surface, <<final, rest::binary>>, params, count) when final in 0x40..0x7E do
    surface = %{surface | parser_state: :ground}

    surface =
      if count <= @max_csi_bytes do
        apply_csi(surface, params |> Enum.reverse() |> :erlang.list_to_binary(), <<final>>)
      else
        surface
      end

    consume(surface, rest)
  end

  defp consume_csi(surface, <<char, rest::binary>>, params, count)
       when char in 0x20..0x3F and count < @max_csi_bytes,
       do: consume_csi(surface, rest, [char | params], count + 1)

  # Overlong or malformed CSI sequences remain discarded through their final byte.
  defp consume_csi(surface, <<_char, rest::binary>>, _params, _count),
    do: consume_csi(surface, rest, [], @max_csi_bytes + 1)

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
      3 -> %{surface | scrollback: :queue.new(), scrollback_count: 0}
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
        saved_scrollback_count: surface.scrollback_count,
        saved_style: surface.style,
        cursor: %{row: 0, col: 0},
        screen: blank_screen(surface.cols, surface.rows),
        scrollback: :queue.new(),
        scrollback_count: 0
    }
  end

  defp leave_alt_screen(%{alt_screen?: false} = surface), do: surface

  defp leave_alt_screen(surface) do
    %{
      surface
      | alt_screen?: false,
        cursor: surface.saved_screen_cursor || %{row: 0, col: 0},
        screen: surface.saved_screen || blank_screen(surface.cols, surface.rows),
        scrollback: surface.saved_scrollback || :queue.new(),
        scrollback_count: surface.saved_scrollback_count || 0,
        style: surface.saved_style || %{},
        saved_screen_cursor: nil,
        saved_screen: nil,
        saved_scrollback: nil,
        saved_scrollback_count: 0,
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

  defp put_ascii_run(surface, ""), do: surface

  defp put_ascii_run(surface, bytes) do
    cond do
      surface.cursor.col >= surface.cols ->
        surface
        |> put_cursor_col(0)
        |> linefeed()
        |> put_ascii_run(bytes)

      true ->
        available = surface.cols - surface.cursor.col
        take = min(byte_size(bytes), available)
        chunk = binary_part(bytes, 0, take)
        rest = binary_part(bytes, take, byte_size(bytes) - take)
        cells = ascii_cells(chunk, surface.style)

        surface =
          surface
          |> put_cells(surface.cursor.row, surface.cursor.col, cells, take)
          |> put_cursor_col(surface.cursor.col + take)

        if rest == "" do
          surface
        else
          surface
          |> put_cursor_col(0)
          |> linefeed()
          |> put_ascii_run(rest)
        end
    end
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
    update_row(surface, row, &List.replace_at(&1, col, cell))
  end

  defp put_cells(surface, row, col, cells, count) do
    update_row(surface, row, fn current_row ->
      {prefix, rest} = Enum.split(current_row, col)
      prefix ++ cells ++ Enum.drop(rest, count)
    end)
  end

  defp update_row(surface, row, fun) do
    %{surface | screen: List.update_at(surface.screen, row, fun)}
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
          screen: rest ++ [blank_row(surface.cols)]
      }
      |> push_scrollback(dropped)
    else
      put_cursor_row(surface, next_row)
    end
  end

  defp scroll_up(surface, count) do
    count = clamp(count, 0, surface.rows)
    {dropped, rest} = Enum.split(surface.screen, count)

    %{
      surface
      | screen: rest ++ repeat(count, fn -> blank_row(surface.cols) end)
    }
    |> append_scrollback(dropped)
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
      cells = Enum.at(acc.screen, row)

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
      cells = Enum.at(acc.screen, row)

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
    cells = Enum.at(surface.screen, surface.cursor.row)

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
    cells = Enum.at(surface.screen, surface.cursor.row)

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
    |> Enum.reduce({[], :none, []}, fn
      %{text: "", style: _style}, acc ->
        acc

      %{text: text, style: style}, {segments, style, parts} ->
        {segments, style, [text | parts]}

      %{text: text, style: style}, {segments, :none, []} ->
        {segments, style, [text]}

      %{text: text, style: style}, {segments, current_style, parts} ->
        {[{parts_to_binary(parts), current_style} | segments], style, [text]}
    end)
    |> finish_row_segments()
  end

  defp finish_row_segments({segments, :none, []}), do: Enum.reverse(segments)

  defp finish_row_segments({segments, style, parts}),
    do: Enum.reverse([{parts_to_binary(parts), style} | segments])

  defp parts_to_binary(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

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

  defp next_grapheme(<<_codepoint::utf8, _rest::binary>> = bytes) do
    {grapheme, rest} = String.next_grapheme(bytes)
    {:ok, grapheme, rest}
  end

  defp next_grapheme(bytes) do
    # Only a valid, unfinished UTF-8 prefix is buffered (at most three bytes).
    # Invalid leading bytes are dropped without passing them to the width renderer.
    case :unicode.characters_to_binary(binary_part(bytes, 0, min(byte_size(bytes), 4))) do
      {:incomplete, "", _prefix} ->
        :incomplete

      _ ->
        <<_byte, rest::binary>> = bytes
        {:drop, rest}
    end
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

  defp blank_screen(cols, rows), do: List.duplicate(blank_row(cols), rows)
  defp blank_row(cols), do: List.duplicate(blank_cell(), cols)
  defp blank_cell, do: %{text: " ", style: %{}}
  defp wide_continuation_cell(style), do: %{text: "", style: style}

  defp ascii_cells(bytes, style), do: for(<<char <- bytes>>, do: %{text: <<char>>, style: style})

  defp append_scrollback(surface, rows), do: Enum.reduce(rows, surface, &push_scrollback(&2, &1))

  defp push_scrollback(%{scrollback_limit: 0} = surface, _row),
    do: %{surface | scrollback: :queue.new(), scrollback_count: 0}

  defp push_scrollback(surface, row) do
    %{
      surface
      | scrollback: :queue.in(row, surface.scrollback),
        scrollback_count: surface.scrollback_count + 1
    }
    |> trim_scrollback()
  end

  defp trim_scrollback(%{scrollback_limit: :infinity} = surface), do: surface

  defp trim_scrollback(%{scrollback_count: count, scrollback_limit: limit} = surface)
       when count <= limit,
       do: surface

  defp trim_scrollback(surface) do
    {{:value, _dropped}, scrollback} = :queue.out(surface.scrollback)

    %{surface | scrollback: scrollback, scrollback_count: surface.scrollback_count - 1}
    |> trim_scrollback()
  end

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

  defp scrollback_limit(:infinity), do: :infinity
  defp scrollback_limit(value) when is_integer(value) and value >= 0, do: value
  defp scrollback_limit(_value), do: @default_scrollback_limit

  defp grapheme_width(grapheme), do: max(Ucwidth.width(grapheme), 1)
  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
  defp clamp_color_index(value), do: clamp(value, 0, 255)
  defp clamp_rgb(value), do: clamp(value || 0, 0, 255)
end

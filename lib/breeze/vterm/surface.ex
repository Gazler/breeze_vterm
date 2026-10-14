defmodule Breeze.VTerm.Surface do
  @moduledoc """
  A small terminal screen model for embedding terminal-like byte streams in Breeze.

  The surface is transport agnostic: callers feed output bytes with `write/2`,
  forward encoded input bytes from `input/2` to their backend, and render the
  current screen with `virtual_text/1`.
  """

  alias BackBreeze.Ucwidth
  alias BackBreeze.VirtualText
  alias Breeze.VTerm.Parser

  # Terminal semantics adapted from libvterm 0.3.3 src/state.c and src/screen.c.
  # See THIRD_PARTY_NOTICES for attribution and the MIT license.

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
            saved_cursor_style: %{},
            saved_cursor_visible?: true,
            tabstops: MapSet.new(),
            origin_mode?: false,
            autowrap?: true,
            wrap_pending?: false,
            newline_mode?: false,
            cursor_visible?: true,
            application_cursor?: false,
            saved_screen_cursor: nil,
            saved_screen: nil,
            saved_scrollback: nil,
            saved_scrollback_count: 0,
            saved_style: nil,
            scroll_region: nil,
            insert_mode?: false,
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
          parser_state: atom() | tuple(),
          tabstops: MapSet.t(non_neg_integer()),
          origin_mode?: boolean(),
          autowrap?: boolean(),
          wrap_pending?: boolean(),
          newline_mode?: boolean(),
          cursor_visible?: boolean(),
          application_cursor?: boolean(),
          saved_cursor_style: style(),
          saved_cursor_visible?: boolean(),
          saved_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen_cursor: %{row: non_neg_integer(), col: non_neg_integer()} | nil,
          saved_screen: [row()] | nil,
          saved_scrollback: :queue.queue(row()) | nil,
          saved_scrollback_count: non_neg_integer(),
          saved_style: style() | nil,
          scroll_region: {non_neg_integer(), non_neg_integer()} | nil,
          insert_mode?: boolean(),
          alt_screen?: boolean(),
          version: non_neg_integer()
        }

  @ansi_8_color_count 8
  @default_scrollback_limit 10_000

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
      tabstops: default_tabstops(cols),
      scrollback: :queue.new(),
      scrollback_count: 0,
      cursor: %{row: 0, col: 0}
    }
  end

  @spec write(t(), binary()) :: t()
  def write(%__MODULE__{} = surface, bytes) when is_binary(bytes) do
    {state, surface} = Parser.feed(surface.parser_state, bytes, surface, &apply_event/2)
    %{surface | parser_state: state, version: surface.version + 1}
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
        wrap_pending?: false,
        tabstops: resize_tabstops(surface, cols),
        cursor: %{
          row: min(surface.cursor.row, rows - 1),
          col: min(surface.cursor.col, cols - 1)
        },
        saved_screen: saved_screen,
        saved_cursor: resize_saved_cursor(surface.saved_cursor, cols, rows),
        saved_screen_cursor: resize_saved_cursor(surface.saved_screen_cursor, cols, rows),
        version: surface.version + 1
    }
    |> Map.put(:scroll_region, nil)
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

  @doc "Encodes a key using the terminal's current cursor-key mode."
  @spec input(t() | nil, map() | binary()) :: binary() | nil
  def input(%{application_cursor?: true}, event) do
    key = if is_map(event), do: Map.get(event, "key"), else: event
    modified? = is_map(event) and (event["ctrlKey"] == true or event["altKey"] == true)

    if not modified? and key in ["ArrowUp", "ArrowDown", "ArrowRight", "ArrowLeft", "Home", "End"] do
      "\e[" <> suffix = input(key)
      "\eO" <> suffix
    else
      input(event)
    end
  end

  def input(_surface, event), do: input(event)

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
    |> Enum.map(&clipped_row_segments(&1, width, {[], :none, []}))
  end

  @doc "Returns terminal cells from scrollback followed by the active screen."
  def rows_slice(_surface, _start_line, count) when count <= 0, do: []

  def rows_slice(surface, start_line, count) do
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

  defp apply_event({:text, bytes}, surface) do
    consume_text(%{surface | buffer: ""}, surface.buffer <> bytes)
  end

  defp apply_event(event, surface) do
    # A control interrupts an unfinished UTF-8 character.
    apply_terminal_event(event, %{surface | buffer: ""})
  end

  defp apply_terminal_event({:control, 8}, surface),
    do: put_cursor_col(surface, surface.cursor.col - 1)

  defp apply_terminal_event({:control, 9}, surface), do: tab(surface, 1, :forward)

  defp apply_terminal_event({:control, c}, surface) when c in [10, 11, 12] do
    surface = linefeed(surface)
    if surface.newline_mode?, do: put_cursor_col(surface, 0), else: surface
  end

  defp apply_terminal_event({:control, 13}, surface), do: put_cursor_col(surface, 0)
  defp apply_terminal_event({:control, 0x84}, surface), do: linefeed(surface)

  defp apply_terminal_event({:control, 0x85}, surface),
    do: surface |> linefeed() |> put_cursor_col(0)

  defp apply_terminal_event({:control, 0x88}, surface),
    do: %{surface | tabstops: MapSet.put(surface.tabstops, surface.cursor.col)}

  defp apply_terminal_event({:control, 0x8D}, surface), do: reverse_index(surface)
  defp apply_terminal_event({:escape, "7"}, surface), do: save_cursor(surface)
  defp apply_terminal_event({:escape, "8"}, surface), do: restore_cursor(surface)

  defp apply_terminal_event({:escape, "c"}, surface) do
    fresh =
      new(cols: surface.cols, rows: surface.rows, scrollback_limit: surface.scrollback_limit)

    %{fresh | id: surface.id, version: surface.version}
  end

  # Dispatch on the complete command, not just its final byte. For example,
  # DECCARA ($r) must never be mistaken for scrolling margins (r).
  defp apply_terminal_event({:csi, "", params, "", final}, surface) do
    if final == "m" or not String.contains?(params, ":"),
      do: apply_csi(surface, params, final),
      else: surface
  end

  defp apply_terminal_event({:csi, "?", params, "", final}, surface) when final in ["h", "l"],
    do: apply_private_mode(surface, "?" <> params, final == "h")

  defp apply_terminal_event(_event, surface), do: surface

  defp consume_text(surface, ""), do: surface

  defp consume_text(surface, <<char, _::binary>> = bytes) when char in 0x20..0x7E do
    {run, rest} = take_printable_ascii(bytes)
    surface |> put_ascii_run(run) |> consume_text(rest)
  end

  defp consume_text(surface, <<0xC2, char, rest::binary>>) when char in 0x80..0x9F,
    do: consume_text(surface, rest)

  defp consume_text(surface, bytes) do
    case next_grapheme(bytes) do
      {:ok, grapheme, rest} -> surface |> put_grapheme(grapheme) |> consume_text(rest)
      :incomplete -> %{surface | buffer: :binary.copy(bytes)}
      {:drop, rest} -> consume_text(surface, rest)
    end
  end

  defp take_printable_ascii(bytes), do: do_take_printable_ascii(bytes, bytes, 0)

  defp do_take_printable_ascii(original, <<char, rest::binary>>, count)
       when char in 0x20..0x7E,
       do: do_take_printable_ascii(original, rest, count + 1)

  defp do_take_printable_ascii(original, rest, count),
    do: {binary_part(original, 0, count), rest}

  defp apply_csi(surface, params, "m"), do: apply_sgr(surface, sgr_params(params))
  defp apply_csi(surface, params, "h"), do: apply_private_mode(surface, params, true)
  defp apply_csi(surface, params, "l"), do: apply_private_mode(surface, params, false)
  defp apply_csi(surface, _params, "s"), do: save_cursor(surface)
  defp apply_csi(surface, _params, "u"), do: restore_cursor(surface)

  defp apply_csi(surface, params, final) when final in ["H", "f"] do
    values = csi_params(params)
    row = max(csi_param(values, 0, 1) - 1, 0)
    col = max(csi_param(values, 1, 1) - 1, 0)
    put_cursor(surface, absolute_row(surface, row), col)
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
    put_cursor_row(surface, absolute_row(surface, row))
  end

  defp apply_csi(surface, params, "J") do
    case csi_param(csi_params(params), 0, 0) do
      1 -> clear_to_cursor(surface)
      2 -> erase_rows(surface, 0, surface.rows - 1, 0, surface.cols - 1)
      3 -> %{surface | scrollback: :queue.new(), scrollback_count: 0}
      0 -> clear_from_cursor(surface)
      _ -> surface
    end
  end

  defp apply_csi(surface, params, "K") do
    case csi_param(csi_params(params), 0, 0) do
      1 -> clear_line_to_cursor(surface)
      2 -> erase_rows(surface, surface.cursor.row, surface.cursor.row, 0, surface.cols - 1)
      0 -> clear_line_from_cursor(surface)
      _ -> surface
    end
  end

  defp apply_csi(surface, params, "@"),
    do: insert_cells(surface, csi_param(csi_params(params), 0, 1))

  defp apply_csi(surface, params, "P"),
    do: delete_cells(surface, csi_param(csi_params(params), 0, 1))

  defp apply_csi(surface, params, "S") do
    scroll_up(surface, csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "T") do
    scroll_down(surface, csi_param(csi_params(params), 0, 1))
  end

  defp apply_csi(surface, params, "r") do
    # Private-mode restores and rectangular attribute changes are not DECSTBM.
    if Regex.match?(~r/^[0-9;]*$/, params) do
      values = csi_params(params)
      top = csi_param(values, 0, 1) - 1
      bottom = csi_param(values, 1, surface.rows) - 1

      if top < bottom and bottom < surface.rows do
        surface |> Map.put(:scroll_region, {top, bottom}) |> home_cursor()
      else
        surface
      end
    else
      surface
    end
  end

  defp apply_csi(surface, params, "L"),
    do: edit_lines(surface, csi_param(csi_params(params), 0, 1), :down)

  defp apply_csi(surface, params, "M"),
    do: edit_lines(surface, csi_param(csi_params(params), 0, 1), :up)

  defp apply_csi(surface, params, "E"),
    do:
      surface
      |> put_cursor_row(surface.cursor.row + csi_param(csi_params(params), 0, 1))
      |> put_cursor_col(0)

  defp apply_csi(surface, params, "F"),
    do:
      surface
      |> put_cursor_row(surface.cursor.row - csi_param(csi_params(params), 0, 1))
      |> put_cursor_col(0)

  defp apply_csi(surface, params, "I"),
    do: tab(surface, csi_param(csi_params(params), 0, 1), :forward)

  defp apply_csi(surface, params, "Z"),
    do: tab(surface, csi_param(csi_params(params), 0, 1), :backward)

  defp apply_csi(surface, params, "g") do
    case csi_param(csi_params(params), 0, 0) do
      0 -> %{surface | tabstops: MapSet.delete(surface.tabstops, surface.cursor.col)}
      n when n in [3, 5] -> %{surface | tabstops: MapSet.new()}
      _ -> surface
    end
  end

  defp apply_csi(surface, params, "X") do
    last = min(surface.cols - 1, surface.cursor.col + csi_param(csi_params(params), 0, 1) - 1)
    erase_rows(surface, surface.cursor.row, surface.cursor.row, surface.cursor.col, last)
  end

  defp apply_csi(surface, params, "`"), do: apply_csi(surface, params, "G")
  defp apply_csi(surface, params, "a"), do: apply_csi(surface, params, "C")
  defp apply_csi(surface, params, "e"), do: apply_csi(surface, params, "B")
  defp apply_csi(surface, _params, _final), do: surface

  defp sgr_params(""), do: [0]

  defp sgr_params(params) do
    params
    |> String.split(";", trim: false)
    |> Enum.flat_map(fn
      "" ->
        [0]

      value ->
        case String.split(value, ":") do
          [single] ->
            case parse_int(single, nil) do
              nil -> []
              n -> [n]
            end

          [color, "5", index] when color in ["38", "48"] ->
            color_params([color, "5", index])

          [color, "2", r, g, b] when color in ["38", "48"] ->
            color_params([color, "2", r, g, b])

          [color, "2", "", r, g, b] when color in ["38", "48"] ->
            color_params([color, "2", r, g, b])

          _ ->
            []
        end
    end)
  end

  defp color_params(values) do
    values = Enum.map(values, &parse_int(&1, nil))
    if Enum.any?(values, &is_nil/1), do: [], else: values
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
      1, acc -> %{acc | application_cursor?: enabled?}
      6, acc -> acc |> Map.put(:origin_mode?, enabled?) |> home_cursor()
      7, acc -> %{acc | autowrap?: enabled?}
      25, acc -> %{acc | cursor_visible?: enabled?}
      1048, acc when enabled? -> save_cursor(acc)
      1048, acc -> restore_cursor(acc)
      _mode, acc -> acc
    end)
  end

  defp apply_private_mode(surface, params, enabled?) do
    Enum.reduce(csi_params(params), surface, fn
      4, acc -> %{acc | insert_mode?: enabled?}
      20, acc -> %{acc | newline_mode?: enabled?}
      _, acc -> acc
    end)
  end

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
        wrap_pending?: false,
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
        wrap_pending?: false,
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

  defp save_cursor(surface),
    do: %{
      surface
      | saved_cursor: surface.cursor,
        saved_cursor_style: surface.style,
        saved_cursor_visible?: surface.cursor_visible?
    }

  defp restore_cursor(%{saved_cursor: %{row: row, col: col}} = surface) do
    surface = %{
      surface
      | style: surface.saved_cursor_style,
        cursor_visible?: surface.saved_cursor_visible?
    }

    put_cursor(surface, row, col)
  end

  defp restore_cursor(surface), do: surface

  defp put_grapheme(surface, grapheme) do
    width = min(grapheme_width(grapheme), surface.cols)
    surface = prepare_write(surface, width)
    row = surface.cursor.row
    col = surface.cursor.col
    cell = %{text: grapheme, style: surface.style}

    surface
    |> maybe_insert_cells(width)
    |> put_cell(row, col, cell)
    |> fill_wide_continuation(width)
    |> advance_after_write(col, width)
  end

  defp prepare_write(surface, width) do
    if surface.wrap_pending? or surface.cursor.col + width > surface.cols,
      do: surface |> linefeed() |> put_cursor_col(0),
      else: surface
  end

  defp advance_after_write(surface, col, width) do
    if col + width >= surface.cols do
      %{surface | cursor: %{surface.cursor | col: col}, wrap_pending?: surface.autowrap?}
    else
      %{surface | cursor: %{surface.cursor | col: col + width}, wrap_pending?: false}
    end
  end

  defp put_ascii_run(surface, ""), do: surface

  defp put_ascii_run(surface, bytes) do
    surface = prepare_write(surface, 1)
    col = surface.cursor.col
    count = min(byte_size(bytes), surface.cols - col)
    chunk = binary_part(bytes, 0, count)
    rest = binary_part(bytes, count, byte_size(bytes) - count)

    surface =
      surface
      |> maybe_insert_cells(count)
      |> put_cells(surface.cursor.row, col, ascii_cells(chunk, surface.style), count)
      |> advance_after_write(col + count - 1, 1)

    # With DECAWM disabled, all excess characters replace the rightmost cell.
    rest =
      if not surface.autowrap? and byte_size(rest) > 1,
        do: binary_part(rest, byte_size(rest) - 1, 1),
        else: rest

    put_ascii_run(surface, rest)
  end

  defp maybe_insert_cells(surface, count) do
    if Map.get(surface, :insert_mode?, false), do: insert_cells(surface, count), else: surface
  end

  defp insert_cells(surface, count) do
    col = min(surface.cursor.col, surface.cols)
    count = min(count, surface.cols - col)
    row = Enum.at(surface.screen, surface.cursor.row)
    {before, rest} = Enum.split(row, col)
    blanks = List.duplicate(erase_cell(surface), count)

    put_row(
      surface,
      surface.cursor.row,
      normalize_edited_row(before ++ blanks ++ Enum.take(rest, length(rest) - count))
    )
  end

  defp delete_cells(surface, count) do
    col = min(surface.cursor.col, surface.cols)
    count = min(count, surface.cols - col)
    row = Enum.at(surface.screen, surface.cursor.row)
    {before, rest} = Enum.split(row, col)
    blanks = List.duplicate(erase_cell(surface), count)

    put_row(
      surface,
      surface.cursor.row,
      normalize_edited_row(before ++ Enum.drop(rest, count) ++ blanks)
    )
  end

  # Character editing uses cell counts. Do not leave half a wide glyph at
  # an insertion/deletion boundary or at the clipped right edge.
  defp normalize_edited_row([]), do: []

  defp normalize_edited_row([%{text: ""} = cell | rest]),
    do: [%{cell | text: " "} | normalize_edited_row(rest)]

  defp normalize_edited_row([cell | rest]) do
    width = grapheme_width(cell.text)
    {continuations, tail} = Enum.split(rest, width - 1)

    if length(continuations) == width - 1 and Enum.all?(continuations, &(&1.text == "")) do
      [cell | continuations] ++ normalize_edited_row(tail)
    else
      [%{cell | text: " "} | normalize_edited_row(rest)]
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

  defp scroll_region(surface), do: Map.get(surface, :scroll_region) || {0, surface.rows - 1}

  defp linefeed(surface) do
    {_top, bottom} = scroll_region(surface)

    if surface.cursor.row == bottom,
      do: scroll_up(surface, 1),
      else: put_cursor_row(surface, surface.cursor.row + 1)
  end

  defp reverse_index(surface) do
    {top, _bottom} = scroll_region(surface)

    if surface.cursor.row == top,
      do: scroll_down(surface, 1),
      else: put_cursor_row(surface, surface.cursor.row - 1)
  end

  defp scroll_up(surface, count) do
    {top, bottom} = scroll_region(surface)
    shift_rows(surface, top, bottom, count, :up, top == 0 and bottom == surface.rows - 1)
  end

  defp scroll_down(surface, count) do
    {top, bottom} = scroll_region(surface)
    shift_rows(surface, top, bottom, count, :down, false)
  end

  defp edit_lines(surface, count, direction) do
    {top, bottom} = scroll_region(surface)
    row = surface.cursor.row

    if row >= top and row <= bottom do
      shift_rows(surface, row, bottom, count, direction, false)
    else
      surface
    end
  end

  defp shift_rows(surface, top, bottom, count, direction, history?) do
    height = bottom - top + 1
    count = clamp(count, 0, height)
    {before, rest} = Enum.split(surface.screen, top)
    {region, after_region} = Enum.split(rest, height)

    blanks =
      repeat(count, fn -> List.duplicate(erase_cell(surface), surface.cols) end)

    {shifted, dropped} =
      case direction do
        :up ->
          {dropped, kept} = Enum.split(region, count)
          {kept ++ blanks, dropped}

        :down ->
          {blanks ++ Enum.take(region, height - count), []}
      end

    surface = %{surface | screen: before ++ shifted ++ after_region}
    if history?, do: append_scrollback(surface, dropped), else: surface
  end

  defp clear_from_cursor(surface) do
    Enum.reduce(surface.cursor.row..(surface.rows - 1), surface, fn row, acc ->
      first = if row == surface.cursor.row, do: surface.cursor.col, else: 0
      erase_rows(acc, row, row, first, surface.cols - 1)
    end)
  end

  defp clear_to_cursor(surface) do
    Enum.reduce(0..surface.cursor.row, surface, fn row, acc ->
      last = if row == surface.cursor.row, do: surface.cursor.col, else: surface.cols - 1
      erase_rows(acc, row, row, 0, last)
    end)
  end

  defp clear_line_from_cursor(surface),
    do:
      erase_rows(
        surface,
        surface.cursor.row,
        surface.cursor.row,
        surface.cursor.col,
        surface.cols - 1
      )

  defp clear_line_to_cursor(surface),
    do: erase_rows(surface, surface.cursor.row, surface.cursor.row, 0, surface.cursor.col)

  defp erase_rows(surface, top, bottom, left, right) do
    blank = erase_cell(surface)

    if left == 0 and right == surface.cols - 1 do
      # Fully erased rows can share one immutable row without inspecting cells.
      cells = List.duplicate(blank, surface.cols)
      Enum.reduce(top..bottom, surface, &put_row(&2, &1, cells))
    else
      Enum.reduce(top..bottom, surface, fn row, acc ->
        update_row(acc, row, fn cells ->
          cells
          |> Enum.with_index()
          |> Enum.map(fn {cell, col} ->
            if col >= left and col <= right, do: blank, else: cell
          end)
          |> normalize_edited_row()
        end)
      end)
    end
  end

  # libvterm's screen erase retains colors, but resets character attributes.
  defp erase_cell(surface),
    do: %{text: " ", style: Map.take(surface.style, [:foreground_color, :background_color])}

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

  # Clip in cell coordinates while grouping styles, including wide-glyph
  # continuation cells in the limit but not in the rendered text.
  defp clipped_row_segments(_, 0, acc), do: finish_row_segments(acc)
  defp clipped_row_segments([], _, acc), do: finish_row_segments(acc)

  defp clipped_row_segments([%{text: ""} | rest], remaining, acc),
    do: clipped_row_segments(rest, remaining - 1, acc)

  defp clipped_row_segments(
         [%{text: text, style: style} | rest],
         remaining,
         {segments, style, parts}
       ),
       do: clipped_row_segments(rest, remaining - 1, {segments, style, [text | parts]})

  defp clipped_row_segments(
         [%{text: text, style: style} | rest],
         remaining,
         {segments, :none, []}
       ),
       do: clipped_row_segments(rest, remaining - 1, {segments, style, [text]})

  defp clipped_row_segments(
         [%{text: text, style: style} | rest],
         remaining,
         {segments, previous, parts}
       ),
       do:
         clipped_row_segments(
           rest,
           remaining - 1,
           {[{parts_to_binary(parts), previous} | segments], style, [text]}
         )

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
    {top, bottom} =
      if surface.origin_mode?, do: scroll_region(surface), else: {0, surface.rows - 1}

    %{surface | cursor: %{surface.cursor | row: clamp(row, top, bottom)}, wrap_pending?: false}
  end

  defp put_cursor_col(surface, col) do
    %{
      surface
      | cursor: %{surface.cursor | col: clamp(col, 0, surface.cols - 1)},
        wrap_pending?: false
    }
  end

  defp default_tabstops(cols), do: MapSet.new(for col <- 0..(cols - 1), rem(col, 8) == 0, do: col)

  defp resize_tabstops(surface, cols) do
    kept = MapSet.filter(surface.tabstops, &(&1 < cols))
    added = MapSet.filter(default_tabstops(cols), &(&1 >= surface.cols))
    MapSet.union(kept, added)
  end

  defp tab(surface, count, direction) do
    col = surface.cursor.col
    stops = surface.tabstops |> Enum.sort()

    {stops, fallback} =
      case direction do
        :forward -> {Enum.filter(stops, &(&1 > col)), surface.cols - 1}
        :backward -> {stops |> Enum.filter(&(&1 < col)) |> Enum.reverse(), 0}
      end

    target = Enum.at(stops, min(count, surface.cols) - 1, fallback)
    if target == col, do: surface, else: put_cursor_col(surface, target)
  end

  defp absolute_row(%{origin_mode?: true} = surface, row),
    do: elem(scroll_region(surface), 0) + row

  defp absolute_row(_surface, row), do: row
  defp home_cursor(surface), do: put_cursor(surface, absolute_row(surface, 0), 0)

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

  defp push_scrollback(%{alt_screen?: true} = surface, _row), do: surface

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

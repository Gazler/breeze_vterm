defmodule Breeze.VTerm.Frame do
  @moduledoc """
  Experimental cell-diff renderer for complete Breeze frames.

  Composes base rows and overlays before comparing them, so selection and cursor
  changes repaint only changed spans. Its interface matches
  `Breeze.Server.Frame.build_payload/5`. All optimization happens on the server,
  before the terminal adapter writes to an SSH channel or local terminal.

  Recognizes short vertical shifts of base rows and considers a DECSTBM plus
  index/reverse-index update. Existing text and highlights move together; cell
  diffs repair exposed rows, selection edges and any displaced surrounding UI.
  The shortest supported payload wins. The optional sixth argument accepts
  `scroll: false` for comparisons with the cell-only renderer.

  Like Breeze's frame writer, this assumes ownership of the complete terminal
  with normal origin mode and full-screen scrolling margins between frames.

  Nonempty frames are enclosed in synchronized-output markers (DEC mode 2026).
  Supporting terminals display the scroll and its repairs together, even when
  transport chunks arrive separately. This adds 16 bytes per frame; idle frames
  remain empty. Initial paints and fallback redraws use the same markers.

  Initial paints and unsupported content use Breeze's existing frame writer.
  Supported rows contain printable single codepoints and SGR styling, ending in
  the default style. Wide glyphs are kept intact. Control strings, other cursor
  commands, complex graphemes, clipped overlays and overlays that split a wide
  glyph fall back. This is a frame renderer, not an arbitrary byte-stream filter.
  """

  alias Breeze.Server.Frame, as: Legacy
  alias BackBreeze.Ucwidth

  @reset "\e[0m"
  @blank {" ", "", 1}
  @max_scroll 8

  def build_payload(previous, lines, previous_overlays, overlays, width, opts \\ [])

  def build_payload(lines, lines, overlays, overlays, _width, _opts) when is_list(lines), do: ""

  def build_payload(previous, lines, previous_overlays, overlays, width, opts) do
    original = Legacy.build_payload(previous, lines, previous_overlays, overlays, width)

    payload =
      if is_list(previous) and length(previous) == length(lines) and original != "" do
        case diff(previous, lines, previous_overlays, overlays, width, original, opts) do
          {:ok, candidate} when byte_size(candidate) < byte_size(original) -> candidate
          _ -> original
        end
      else
        original
      end

    synchronize(payload)
  end

  defp synchronize(""), do: ""

  # Enclose the completed payload in one adapter write. A terminal may paint
  # between the scroll command and its repairs even when sent in one write.
  defp synchronize(payload), do: "\e[?2026h" <> payload <> "\e[?2026l"

  defp diff(previous, lines, previous_overlays, overlays, width, original, opts) do
    with {:ok, old_overlays} <- group_overlays(previous_overlays, width, length(lines)),
         {:ok, new_overlays} <- group_overlays(overlays, width, length(lines)),
         {:ok, cursor} <- final_cursor(original, width),
         {:ok, rows} <- compose_rows(previous, lines, old_overlays, new_overlays, width) do
      # Match the original writer's physical cursor, including delayed wrap at
      # the right margin. Breeze also uses this renderer when the cursor is shown.
      with {:ok, restore} <- restore_cursor(cursor, lines, new_overlays, width) do
        candidate = IO.iodata_to_binary([encode_rows(rows), restore])

        candidates =
          if Keyword.get(opts, :scroll, true), do: scroll_candidates(previous, lines), else: []

        result =
          Enum.reduce(candidates, candidate, fn region, best ->
            {shifted, shifted_overlays} = shift_rows(previous, old_overlays, region)

            case compose_rows(shifted, lines, shifted_overlays, new_overlays, width) do
              {:ok, repairs} ->
                output =
                  IO.iodata_to_binary([scroll_commands(region), encode_rows(repairs), restore])

                if byte_size(output) < byte_size(best), do: output, else: best

              :error ->
                best
            end
          end)

        {:ok, result}
      end
    end
  end

  defp encode_rows(rows) do
    Enum.map(rows, fn {y, spans} ->
      Enum.map(spans, fn {x, background, text} ->
        cursor = position(y, x)
        [if(background, do: [cursor, background], else: []), cursor, text]
      end)
    end)
  end

  defp scroll_candidates(lines, lines), do: []

  defp scroll_candidates(previous, lines) do
    old = List.to_tuple(previous)
    new = List.to_tuple(lines)
    height = tuple_size(old)
    limit = min(@max_scroll, height - 1)

    # Detection uses base rows, so changing selection edges don't obscure a
    # scroll. It is only a heuristic: every affected cell is checked afterwards.
    # Bound both the search distance and the number of candidates to compose.
    for delta <- -limit..limit, delta != 0, reduce: [] do
      candidates ->
        matches =
          lines
          |> Enum.with_index()
          |> Enum.flat_map(fn {line, y} ->
            source = y + delta

            if source >= 0 and source < height and line != elem(old, y) and
                 line == elem(old, source),
               do: [y],
               else: []
          end)

        case matches do
          [first, _ | _] ->
            top = min(first, first + delta)
            last = List.last(matches)
            bottom = max(last, last + delta)
            [{length(matches), {top, bottom, delta}} | candidates]

          _ ->
            candidates
        end
    end
    |> Enum.sort_by(fn {count, {_, _, delta}} -> {-count, abs(delta)} end)
    |> Enum.take(2)
    |> Enum.flat_map(fn {_, {top, bottom, delta} = region} ->
      # A scrollbar arrow or changing edge overlay can hide the first/last
      # matching row. Try including adjacent changed rows, without forcing an
      # unchanged header/footer to move. Price both regions after exact repair.
      expanded = {expand_edge(old, new, top, -1), expand_edge(old, new, bottom, 1), delta}
      Enum.uniq([region, expanded])
    end)
  end

  defp expand_edge(old, new, edge, step) do
    next = edge + step

    if next >= 0 and next < tuple_size(old) and elem(old, next) != elem(new, next),
      do: expand_edge(old, new, next, step),
      else: edge
  end

  defp shift_rows(lines, overlays, {top, bottom, delta}) do
    old = List.to_tuple(lines)

    lines =
      for {line, y} <- Enum.with_index(lines) do
        source = y + delta

        cond do
          y < top or y > bottom -> line
          source < top or source > bottom -> ""
          true -> elem(old, source)
        end
      end

    overlays =
      for {y, row} <- overlays,
          target = if(y >= top and y <= bottom, do: y - delta, else: y),
          y < top or y > bottom or (target >= top and target <= bottom),
          into: %{},
          do: {target, row}

    {lines, overlays}
  end

  defp scroll_commands({top, bottom, delta}) do
    {edge, command} = if delta > 0, do: {bottom, "\eD"}, else: {top, "\eM"}

    # Reset before scrolling so inserted blank rows have known default styling.
    # Restore full margins before the repairs and final cursor restoration.
    [
      @reset,
      "\e[#{top + 1};#{bottom + 1}r",
      position(edge, 0),
      String.duplicate(command, abs(delta)),
      "\e[r"
    ]
  end

  defp compose_rows(previous, lines, old_overlays, new_overlays, width) do
    previous
    |> Enum.zip(lines)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{old_line, line}, y}, {:ok, rows} ->
      old = Map.get(old_overlays, y, [])
      new = Map.get(new_overlays, y, [])

      if old_line == line and old == new do
        if safe_row?(line, width), do: {:cont, {:ok, rows}}, else: {:halt, :error}
      else
        with {:ok, spans} <- diff_row(old_line, line, old, new, width) do
          {:cont, {:ok, [{y, spans} | rows]}}
        else
          _ -> {:halt, :error}
        end
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      :error -> :error
    end
  end

  defp diff_row(old_line, line, old, new, width) do
    # Cache row-local output, not absolute cursor positions. Repeated rows and
    # selection styles share work without retaining per-session screen state.
    BackBreeze.RenderCache.fetch_stable(
      {__MODULE__, :diff_row, old_line, line, old, new, width},
      fn ->
        with {:ok, old_base} <- parse_row(old_line, width),
             {:ok, base} <- parse_row(line, width),
             {:ok, old_cells} <- compose(old_base, old),
             {:ok, cells} <- compose(base, new) do
          {:ok, spans(old_cells, cells, 0, [])}
        end
      end
    )
  end

  defp safe_row?(line, width) do
    BackBreeze.RenderCache.fetch_stable({__MODULE__, :safe_row, line, width}, fn ->
      match?({:ok, _}, parse_row(line, width))
    end)
  end

  defp parse_row(line, width) do
    BackBreeze.RenderCache.fetch_stable({__MODULE__, :row, line, width}, fn ->
      with {:ok, cells} <- parse_text(line),
           true <- length(cells) <= width do
        {:ok, List.to_tuple(cells ++ List.duplicate(@blank, width - length(cells)))}
      else
        _ -> :error
      end
    end)
  end

  defp parse_text(text), do: parse_text(text, "", [])
  defp parse_text("", "", cells), do: {:ok, Enum.reverse(cells)}
  defp parse_text("", _style, _cells), do: :error

  defp parse_text("\e[" <> rest, style, cells) do
    case :binary.match(rest, "m") do
      {n, 1} ->
        <<params::binary-size(^n), "m", tail::binary>> = rest

        if valid_sgr?(params) do
          # Retain SGR verbatim, including attributes absent from Surface's
          # smaller terminal model (underline, faint, strikethrough, etc.).
          style = if params in ["", "0"], do: "", else: style <> "\e[" <> params <> "m"
          parse_text(tail, style, cells)
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_text(<<cp, rest::binary>>, style, cells) when cp in 32..126 do
    # A following combining codepoint is rejected on the next iteration.
    parse_text(rest, style, [{<<cp>>, style, 1} | cells])
  end

  defp parse_text(text, style, cells) do
    case String.next_grapheme(text) do
      {<<cp::utf8>> = char, rest} when cp >= 160 ->
        case Ucwidth.width_codepoint(cp) do
          1 -> parse_text(rest, style, [{char, style, 1} | cells])
          2 -> parse_text(rest, style, [:continuation, {char, style, 2} | cells])
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp valid_sgr?(""), do: true

  defp valid_sgr?(<<c, rest::binary>>) when c in ?0..?9 or c in [?;, ?:],
    do: valid_sgr?(rest)

  defp valid_sgr?(_), do: false

  defp group_overlays(overlays, width, height) do
    Enum.reduce_while(overlays, {:ok, %{}}, fn
      nil, acc ->
        {:cont, acc}

      %{visible?: false}, acc ->
        {:cont, acc}

      %{x: x, y: y} = overlay, {:ok, rows}
      when is_integer(x) and x >= 0 and x < width and is_integer(y) and y >= 0 and y < height ->
        if Map.get(overlay, :clear_line, false) or Map.get(overlay, :no_wrap, false) or
             Map.get(overlay, :height, 1) != 1 or Map.get(overlay, :patch_only, false) do
          {:halt, :error}
        else
          text = overlay_text(overlay)

          size =
            BackBreeze.RenderCache.fetch_stable({__MODULE__, :text_width, text}, fn ->
              case parse_text(text) do
                {:ok, cells} -> length(cells)
                _ -> :error
              end
            end)

          case size do
            size when is_integer(size) and x + size <= width ->
              {:cont, {:ok, Map.update(rows, y, [{x, text}], &[{x, text} | &1])}}

            _ ->
              {:halt, :error}
          end
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp overlay_text(%{content: text}), do: text

  defp overlay_text(%{x: x, y: y} = overlay) do
    position = position(y, x)

    overlay
    |> Breeze.TerminalOverlay.render_overlay()
    |> String.replace_prefix(position, "")
    |> String.replace_suffix(position, "")
  end

  defp compose(base, []), do: {:ok, base}

  defp compose(base, overlays) do
    # Overlay lists were accumulated backwards. Preserve their paint order,
    # then materialize the tuple once instead of copying it for every cell.
    result =
      Enum.reduce_while(Enum.reverse(overlays), {:ok, %{}}, fn {x, text}, {:ok, changes} ->
        {:ok, cells} =
          BackBreeze.RenderCache.fetch_stable({__MODULE__, :text, text}, fn ->
            parse_text(text)
          end)

        right = x + length(cells)
        left_cell = if x < tuple_size(base), do: Map.get(changes, x, elem(base, x))
        right_cell = if right < tuple_size(base), do: Map.get(changes, right, elem(base, right))

        if left_cell == :continuation or right_cell == :continuation do
          {:halt, :error}
        else
          changes =
            cells
            |> Enum.with_index(x)
            |> Enum.reduce(changes, fn {cell, col}, changes ->
              Map.put(changes, col, cell)
            end)

          {:cont, {:ok, changes}}
        end
      end)

    with {:ok, changes} <- result do
      {:ok,
       for(x <- 0..(tuple_size(base) - 1), do: Map.get(changes, x, elem(base, x)))
       |> List.to_tuple()}
    end
  end

  defp continuation?(row, col),
    do: col < tuple_size(row) and elem(row, col) == :continuation

  defp spans(old, _new, x, acc) when x == tuple_size(old),
    do: Enum.reverse(acc)

  defp spans(old, new, x, acc) do
    if elem(old, x) == elem(new, x) do
      spans(old, new, x + 1, acc)
    else
      left = if continuation?(old, x) or continuation?(new, x), do: x - 1, else: x
      right = span_end(old, new, x + 1)
      cells = for col <- left..(right - 1), do: elem(new, col)

      wide? =
        Enum.any?(left..(right - 1), fn col ->
          match?({_, _, 2}, elem(old, col)) or match?({_, _, 2}, elem(new, col))
        end)

      background = if wide?, do: IO.iodata_to_binary(encode(cells, true))
      text = IO.iodata_to_binary(encode(cells, false))
      spans(old, new, right, [{left, background, text} | acc])
    end
  end

  defp span_end(old, _new, x) when x == tuple_size(old), do: x

  defp span_end(old, new, x) do
    if elem(old, x) != elem(new, x) or continuation?(old, x) or continuation?(new, x),
      do: span_end(old, new, x + 1),
      else: x
  end

  defp paint(cells, y, x, wide?) do
    position = position(y, x)
    background = if wide?, do: [position, encode(cells, true)], else: []
    [background, position, encode(cells, false)]
  end

  defp encode(cells, spaces?) do
    {output, _style} =
      Enum.reduce(cells, {[@reset], ""}, fn
        :continuation, acc ->
          acc

        {text, style, width}, {output, last_style} ->
          prefix = if style == last_style, do: [], else: [@reset, style]
          text = if spaces?, do: String.duplicate(" ", width), else: text
          {[[prefix, text] | output], style}
      end)

    [Enum.reverse(output), @reset]
  end

  # Legacy row writes and overlays always position with CUP. Inspect only the
  # tail following its last CUP; don't emulate setup, clipboard or query bytes.
  defp final_cursor(payload, width) do
    case Regex.scan(~r/\e\[([0-9]+);([0-9]+)H/, payload, return: :index) |> List.last() do
      [{offset, size}, {row_at, row_len}, {col_at, col_len}] ->
        row = payload |> binary_part(row_at, row_len) |> String.to_integer() |> Kernel.-(1)
        col = payload |> binary_part(col_at, col_len) |> String.to_integer() |> Kernel.-(1)
        tail = binary_part(payload, offset + size, byte_size(payload) - offset - size)
        tail = String.replace_suffix(tail, "\e[K", "")

        with {:ok, cells} <- parse_text(tail),
             true <- col + length(cells) <= width do
          {:ok, {row, min(col + length(cells), width - 1), col + length(cells) == width}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp restore_cursor({y, x, false}, _lines, _overlays, _width),
    do: {:ok, position(y, x)}

  defp restore_cursor({y, x, true}, lines, overlays, width) do
    with {:ok, base} <- parse_row(Enum.at(lines, y), width),
         {:ok, row} <- compose(base, Map.get(overlays, y, [])) do
      x = if continuation?(row, x), do: x - 1, else: x
      {:ok, paint([elem(row, x)], y, x, false)}
    end
  end

  defp position(row, col), do: "\e[#{row + 1};#{col + 1}H"
end

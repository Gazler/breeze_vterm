defmodule Breeze.VTerm.Selection do
  @moduledoc "Selection of terminal cells, including scrollback and wide characters."
  alias Breeze.VTerm.Surface

  def text(surface, anchor, head, width \\ nil) do
    segments(surface, anchor, head, 0, nil, width)
    |> Enum.map_join("\n", fn {_row, _col, text} -> String.trim_trailing(text, " ") end)
  end

  def segments(surface, anchor, head, first_row \\ 0, count \\ nil, width \\ nil) do
    selected_rows(surface, anchor, head, first_row, count, width, &copy_row/5)
  end

  def highlights(surface, anchor, head, first_row, count, width) do
    selected_rows(surface, anchor, head, first_row, count, width, &highlight_row/5)
  end

  defp copy_row(row, cells, left, right, width) do
    case selected_cells(cells, left, right, width, false) do
      {left, [_ | _] = selected} -> [{row, left, Enum.map_join(selected, & &1.text)}]
      _ -> []
    end
  end

  defp highlight_row(row, cells, left, right, width) do
    # Reuse unchanged rows when scrolling or when Breeze requests the same
    # decorations during layout and painting. Key by content, not surface
    # id/version: independently edited branches can share those identifiers.
    BackBreeze.RenderCache.fetch_stable({__MODULE__, cells, left, right, width}, fn ->
      {left, selected} = selected_cells(cells, left, right, width, true)
      highlight_runs(selected, left, [])
    end)
    |> Enum.map(fn {col, text, style} -> {row, col, text, style} end)
  end

  defp highlight_runs([], _col, runs) do
    runs
    |> Enum.reverse()
    |> Enum.map(fn {col, chunks, style, _} ->
      {col, chunks |> Enum.reverse() |> IO.iodata_to_binary(), style}
    end)
  end

  defp highlight_runs([%{text: ""} | cells], col, runs),
    do: highlight_runs(cells, col + 1, runs)

  defp highlight_runs([cell | cells], col, runs) do
    end_col = col + cell_width(cell.text)

    runs =
      case runs do
        [{start, chunks, style, ^col} | rest] when style == cell.style ->
          [{start, [cell.text | chunks], style, end_col} | rest]

        _ ->
          [{col, [cell.text], cell.style, end_col} | runs]
      end

    highlight_runs(cells, col + 1, runs)
  end

  defp selected_rows(surface, anchor, head, first_row, count, width, fun) do
    width = min(width || surface.cols, surface.cols)

    {{start_row, start_col}, {end_row, end_col}} =
      Enum.min_max([clamp(surface, anchor), clamp(surface, head)])

    first = max(start_row, first_row)
    last = min(end_row, first_row + (count || Surface.line_count(surface)) - 1)

    if first > last or width <= 0 do
      []
    else
      surface
      |> Surface.rows_slice(first, last - first + 1)
      |> Enum.with_index(first)
      |> Enum.flat_map(fn {cells, row} ->
        left = if row == start_row, do: start_col, else: 0
        right = min(if(row == end_row, do: end_col, else: surface.cols - 1), width - 1)
        fun.(row, cells, left, right, width)
      end)
    end
  end

  defp selected_cells(cells, left, right, width, trim_padding?) do
    right = if trim_padding?, do: min(right, text_end(cells, 0, -1)), else: right
    left = if left > 0 and match?(%{text: ""}, Enum.at(cells, left)), do: left - 1, else: left

    selected =
      if left > right do
        []
      else
        cells
        |> Enum.slice(left, right - left + 1)
        |> clip_cells(left, width)
      end

    {left, selected}
  end

  defp clip_cells([], _, _), do: []

  defp clip_cells([cell | cells], col, width) do
    clipped = if col + cell_width(cell.text) > width, do: %{cell | text: " "}, else: cell
    [clipped | clip_cells(cells, col + 1, width)]
  end

  defp text_end([], _, last), do: last

  defp text_end([cell | cells], col, last),
    do: text_end(cells, col + 1, if(blank?(cell.text), do: last, else: col))

  defp blank?(text) when text in ["", " "], do: true
  defp blank?(<<char>>) when char > 32 and char < 127, do: false
  defp blank?(text), do: String.trim(text) == ""

  defp cell_width(<<char>>) when char >= 32 and char < 127, do: 1
  defp cell_width(""), do: 0
  defp cell_width(text), do: BackBreeze.Ucwidth.width(text)

  defp clamp(surface, {row, col}) do
    {row |> max(0) |> min(Surface.line_count(surface) - 1),
     col |> max(0) |> min(surface.cols - 1)}
  end
end

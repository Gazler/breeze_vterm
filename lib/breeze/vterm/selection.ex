defmodule Breeze.VTerm.Selection do
  @moduledoc false
  alias Breeze.VTerm.Surface

  # Endpoints are inclusive, zero-based {buffer_row, cell_column} coordinates.
  # Rows include scrollback; out-of-range endpoints are clamped to the surface.
  @type point :: {integer(), integer()}
  @type segment :: {non_neg_integer(), non_neg_integer(), String.t()}
  @type highlight :: {non_neg_integer(), non_neg_integer(), String.t(), Surface.style()}

  # Copy plain text, joining selected rows with newlines and trimming row padding.
  @spec text(Surface.t(), point(), point(), non_neg_integer() | nil) :: String.t()
  def text(surface, anchor, head, width \\ nil) do
    segments(surface, anchor, head, 0, nil, width)
    |> Enum.map_join("\n", fn {_row, _col, text} -> String.trim_trailing(text, " ") end)
  end

  # Width clips columns; first_row/count restrict rows. Returned coordinates
  # remain absolute, and the right endpoint includes a whole wide character.
  @spec segments(
          Surface.t(),
          point(),
          point(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: [segment()]
  def segments(surface, anchor, head, first_row \\ 0, count \\ nil, width \\ nil) do
    cell_segments(surface, anchor, head, first_row, count, width)
    |> Enum.map(fn {row, col, cells} -> {row, col, Enum.map_join(cells, & &1.text)} end)
  end

  # Styled runs use the same coordinates and omit trailing blank cells.
  @spec highlights(
          Surface.t(),
          point(),
          point(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [highlight()]
  def highlights(surface, anchor, head, first_row, count, width) do
    cell_segments(surface, anchor, head, first_row, count, width, true)
    |> Enum.flat_map(fn {row, left, cells} ->
      cells
      |> Enum.with_index(left)
      |> Enum.reduce([], fn {cell, col}, acc ->
        if cell.text == "" do
          acc
        else
          end_col = col + BackBreeze.Ucwidth.width(cell.text)

          case acc do
            [{^row, start, text, style, ^col} | rest] when style == cell.style ->
              [{row, start, text <> cell.text, style, end_col} | rest]

            _ ->
              [{row, col, cell.text, cell.style, end_col} | acc]
          end
        end
      end)
      |> Enum.reverse()
      |> Enum.map(fn {row, col, text, style, _} -> {row, col, text, style} end)
    end)
  end

  defp cell_segments(surface, anchor, head, first_row, count, width, trim_padding? \\ false) do
    width = min(width || surface.cols, surface.cols)
    {start, finish} = Enum.min_max([clamp(surface, anchor), clamp(surface, head)])
    {start_row, start_col} = start
    {end_row, end_col} = finish
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
        right = if trim_padding?, do: min(right, text_end(cells)), else: right
        left = if left > 0 and match?(%{text: ""}, Enum.at(cells, left)), do: left - 1, else: left

        if left > right do
          []
        else
          selected_cells =
            cells
            |> Enum.slice(left, right - left + 1)
            |> Enum.with_index(left)
            |> Enum.map(fn {cell, col} ->
              if col + BackBreeze.Ucwidth.width(cell.text) > width,
                do: %{cell | text: " "},
                else: cell
            end)

          [{row, left, selected_cells}]
        end
      end)
    end
  end

  defp text_end(cells) do
    cells
    |> Enum.with_index()
    |> Enum.reduce(-1, fn {cell, col}, last ->
      if String.trim(cell.text) == "", do: last, else: col
    end)
  end

  defp clamp(surface, {row, col}) do
    {row |> max(0) |> min(Surface.line_count(surface) - 1),
     col |> max(0) |> min(surface.cols - 1)}
  end
end

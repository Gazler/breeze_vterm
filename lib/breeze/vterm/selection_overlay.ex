defmodule Breeze.VTerm.SelectionOverlay do
  @moduledoc false

  alias Breeze.VTerm.Selection

  @typep origin :: {integer(), integer()}
  @typep overlay :: %{x: integer(), y: integer(), content: binary(), visible?: true}

  # Highlights use absolute buffer coordinates. The origin includes the pane's
  # content inset and negative scroll offset to place them on the terminal.
  @spec render([Selection.highlight()], map(), origin()) :: [overlay()]
  def render(highlights, defaults, {left, top}) do
    {runs, _codes} =
      Enum.map_reduce(highlights, %{}, fn {row, col, text, style}, codes ->
        open = Map.get_lazy(codes, style, fn -> inverse_open(Map.merge(defaults, style)) end)
        run = {row, col, open <> text <> Termite.Style.reset_code(), text}
        {run, Map.put(codes, style, open)}
      end)

    runs
    |> Enum.chunk_while([], &collect_run/2, fn runs ->
      {:cont, Enum.reverse(runs), []}
    end)
    |> Enum.flat_map(&coalesce_row/1)
    |> Enum.map(fn {row, col, content} ->
      %{x: left + col, y: top + row, content: content, visible?: true}
    end)
  end

  @spec copy_notice(integer(), map(), origin(), {non_neg_integer(), non_neg_integer()}) ::
          [overlay()]
  def copy_notice(count, defaults, {left, top}, {width, height}) when width > 0 and height > 0 do
    text = String.slice(" Copied #{count} chars ", 0, width)

    [
      %{
        x: left + width - String.length(text),
        y: top + height - 1,
        content: inverse_open(defaults) <> text <> Termite.Style.reset_code(),
        visible?: true
      }
    ]
  end

  def copy_notice(_count, _defaults, _origin, _size), do: []

  # One overlay per style run can exhaust the renderer's bounded cache. Join
  # adjacent runs, retaining the last run's origin: TerminalOverlay restores the
  # cursor there after painting, and the frame writer preserves that position.
  defp collect_run({row, col, _, _} = run, [{row, previous, _, text} | _] = runs) do
    case run_width(text, 0) do
      width when is_integer(width) and previous + width == col -> {:cont, [run | runs]}
      _ -> {:cont, Enum.reverse(runs), [run]}
    end
  end

  defp collect_run(run, []), do: {:cont, [run]}
  defp collect_run(run, runs), do: {:cont, Enum.reverse(runs), [run]}

  # Preserve explicit positioning around complex graphemes, whose terminal
  # width can differ from the surface's first-codepoint width estimate.
  defp run_width("", width), do: width

  defp run_width(<<char, rest::binary>>, width) when char in 32..126,
    do: run_width(rest, width + 1)

  defp run_width(text, width) do
    case String.next_grapheme(text) do
      {<<codepoint::utf8>>, rest} ->
        case BackBreeze.Ucwidth.width_codepoint(codepoint) do
          cells when cells in [1, 2] -> run_width(rest, width + cells)
          _ -> :complex
        end

      _ ->
        :complex
    end
  end

  defp coalesce_row([]), do: []
  defp coalesce_row([{row, col, content, _}]), do: [{row, col, content}]

  defp coalesce_row(runs) do
    {prefix, [{last_row, last_col, last_content, _}]} = Enum.split(runs, length(runs) - 1)
    {row, col, _, _} = hd(prefix)
    content = prefix |> Enum.map(&elem(&1, 2)) |> IO.iodata_to_binary()
    [{row, col, content}, {last_row, last_col, last_content}]
  end

  defp inverse_open(style) do
    ansi =
      Enum.reduce(style, Termite.Style.ansi256(), fn
        {:foreground_color, color}, acc when not is_nil(color) ->
          Termite.Style.foreground(acc, color)

        {:background_color, color}, acc when not is_nil(color) ->
          Termite.Style.background(acc, color)

        {:bold, true}, acc ->
          Termite.Style.bold(acc)

        {:italic, true}, acc ->
          Termite.Style.italic(acc)

        _, acc ->
          acc
      end)

    ansi = if Map.get(style, :reverse, false), do: ansi, else: Termite.Style.reverse(ansi)

    Termite.Style.reset_code() <> Termite.Style.open_code(ansi)
  end
end

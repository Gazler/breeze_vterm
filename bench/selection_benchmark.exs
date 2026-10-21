# Run with: mix run bench/selection_benchmark.exs
# Measures the ANSI payload built by the same Frame function used by Breeze.Server.
# No PTY, transport compression, mouse scheduling, or clipboard copy is involved.

defmodule BreezeVTerm.SelectionBenchmark.View do
  use Breeze.View
  import Breeze.VTerm.Components

  def mount(opts, term), do: {:ok, assign(term, surface: opts[:surface])}

  def render(assigns) do
    ~H"""
    <box class="width-full height-full">
      <.terminal id="terminal" surface={@surface} selectable cursor-blink={false}/>
    </box>
    """
  end
end

defmodule BreezeVTerm.SelectionBenchmark do
  alias Breeze.Server.Frame
  alias Breeze.VTerm.{Implicit, Surface}

  def run do
    iterations = System.get_env("ITERATIONS", "10") |> String.to_integer()
    if iterations < 1, do: raise(ArgumentError, "ITERATIONS must be positive")

    sizes =
      System.get_env("SIZES", "80x24,160x50,270x100,400x120")
      |> String.split(",")
      |> Enum.map(fn size ->
        [cols, rows] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
        if cols < 4 or rows < 4, do: raise(ArgumentError, "sizes must be at least 4x4")
        {cols, rows}
      end)

    IO.puts("Selection ANSI bytes, Breeze #{Application.spec(:breeze, :vsn)}; gruvbox theme")
    IO.puts("Steady viewport; no scrolling/output; full-width terminal pane.")
    IO.puts("Timings: next selection overlays + frame payload, median of #{iterations} runs.")
    IO.puts("All sizes are bytes before transport framing/compression; KiB = 1024 bytes.\n")
    IO.puts("A one-cell move can send 0 bytes in trailing padding or inside a wide glyph.\n")

    IO.puts(
      "size,fixture,select_all_B,extend_cell_B,shrink_cell_B,extend_row_B,clear_B,idle_B," <>
        "extend_cell_KiB_s_at_60fps,select_all_ms,extend_cell_ms"
    )

    for {cols, rows} <- sizes,
        fixture <- [:ascii, :short_lines, :styled, :wide] do
      benchmark(cols, rows, fixture, iterations)
    end

    IO.puts("\nPlain ASCII prototypes (generated and cell-checked, not used by the application):")
    IO.puts("size,operation,current_B,markers_in_row_B,changed_span_B")

    for {cols, rows} <- sizes do
      with_snapshot(cols, rows, :ascii, fn ctx ->
        for {name, previous, next} <- transitions(cols, rows), name != :idle do
          before = overlays(ctx, previous)
          after_overlays = overlays(ctx, next)
          current = Frame.build_payload(ctx.lines, ctx.lines, before, after_overlays, cols)

          candidates =
            for mode <- [:row, :span] do
              payload = prototype(ctx, previous, next, mode)
              verify_cells!(ctx, before, current, payload)
              byte_size(payload)
            end

          print_csv(["#{cols}x#{rows}", name, byte_size(current) | candidates])
        end
      end)
    end
  end

  defp benchmark(cols, rows, fixture, iterations) do
    with_snapshot(cols, rows, fixture, fn ctx ->
      samples =
        Map.new(transitions(cols, rows), fn {name, previous, next} ->
          before = overlays(ctx, previous)

          build = fn ->
            Frame.build_payload(ctx.lines, ctx.lines, before, overlays(ctx, next), cols)
          end

          payload = build.()
          timings = for _ <- 1..iterations, do: elem(:timer.tc(build), 0)
          median = timings |> Enum.sort() |> Enum.at(div(iterations, 2))
          {name, %{bytes: byte_size(payload), ms: Float.round(median / 1000, 3)}}
        end)

      print_csv([
        "#{cols}x#{rows}",
        fixture,
        samples.select_all.bytes,
        samples.extend_cell.bytes,
        samples.shrink_cell.bytes,
        samples.extend_row.bytes,
        samples.clear.bytes,
        samples.idle.bytes,
        Float.round(samples.extend_cell.bytes * 60 / 1024, 2),
        samples.select_all.ms,
        samples.extend_cell.ms
      ])
    end)
  end

  defp transitions(cols, rows) do
    middle = div(rows, 2)
    full = {rows - 1, cols - 1}

    [
      {:select_all, nil, full},
      {:extend_cell, {middle, div(cols, 2) - 1}, {middle, div(cols, 2)}},
      {:shrink_cell, {middle, div(cols, 2)}, {middle, div(cols, 2) - 1}},
      {:extend_row, {middle - 1, cols - 1}, {middle, cols - 1}},
      {:clear, full, nil},
      {:idle, full, full}
    ]
  end

  defp with_snapshot(cols, rows, fixture, fun) do
    line = fixture_line(fixture, cols)

    surface =
      Surface.new(cols: cols, rows: rows)
      |> Surface.write(Enum.join(List.duplicate(line, rows), "\r\n"))

    terminal = %Termite.Terminal{size: %{width: cols, height: rows}}
    theme = Breeze.Theme.builtin(:gruvbox)

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: BreezeVTerm.SelectionBenchmark.View,
        terminal: terminal,
        theme: theme,
        start_opts: [surface: surface]
      )

    try do
      {:ok, _acc, box, [decoration]} =
        Breeze.ChildServer.render_snapshot(pid, terminal: terminal, focused: "terminal")

      %{viewport_width: ^cols, viewport_height: ^rows} = decoration.layout

      fun.(%{
        cols: cols,
        rows: rows,
        line: line,
        lines: Frame.normalize_lines(box.content, rows),
        decoration: decoration,
        animation_ctx: %{layout: decoration.layout, theme: theme, now: 0}
      })
    after
      GenServer.stop(pid)
    end
  end

  defp fixture_line(:ascii, cols) do
    for col <- 0..(cols - 1), into: "", do: <<?a + rem(col, 26)>>
  end

  defp fixture_line(:short_lines, cols), do: fixture_line(:ascii, min(cols, 80))

  # Alternate red/green every eight cells to expose per-style overlay overhead.
  defp fixture_line(:styled, cols) do
    text = fixture_line(:ascii, cols)

    for col <- 0..(cols - 1)//8 do
      color = if rem(div(col, 8), 2) == 0, do: 31, else: 32
      "\e[#{color}m" <> binary_part(text, col, min(8, cols - col))
    end
    |> IO.iodata_to_binary()
    |> Kernel.<>("\e[0m")
  end

  defp fixture_line(:wide, cols),
    do: String.duplicate("界", div(cols, 2)) <> String.duplicate("x", rem(cols, 2))

  defp overlays(ctx, head) do
    selection =
      if head do
        %{anchor: {0, 0}, head: head, moved?: true, dragging?: true, width: ctx.cols}
      end

    state = Map.put(ctx.decoration.state, :selection, selection)

    {:ok, _box, overlays: overlays} =
      Implicit.animate(:root, ctx.decoration.box, [], state, ctx.animation_ctx)

    overlays
  end

  # These two prototypes deliberately handle only the uniform, non-reversed ASCII
  # fixture. They demonstrate achievable wire sizes, not a general ANSI splicer.
  # Production composition must handle SGR resets, existing reverse, wide cells,
  # clipped panes, scrolling, and other overlays.
  defp prototype(ctx, previous, next, mode) do
    rows =
      for {line, row} <- Enum.with_index(ctx.lines),
          old_right = selected_right(previous, row, ctx.cols),
          new_right = selected_right(next, row, ctx.cols),
          old_right != new_right do
        case mode do
          :row ->
            count = new_right + 1

            marked =
              if count == 0 do
                ctx.line
              else
                "\e[7m" <>
                  binary_part(ctx.line, 0, count) <>
                  "\e[27m" <>
                  binary_part(ctx.line, count, ctx.cols - count)
              end

            [position(row, 0), String.replace(line, ctx.line, marked, global: false)]

          :span ->
            left = min(old_right, new_right) + 1
            count = abs(new_right - old_right)
            [base_style, _rest] = String.split(line, ctx.line, parts: 2)

            [
              position(row, left),
              base_style,
              if(new_right > old_right, do: "\e[7m", else: "\e[27m"),
              binary_part(ctx.line, left, count),
              "\e[0m"
            ]
        end
      end

    # Clearing selection brings back the existing cursor overlay.
    cursor =
      if is_nil(next), do: Breeze.TerminalOverlay.render_overlays(overlays(ctx, nil)), else: ""

    IO.iodata_to_binary([rows, cursor])
  end

  defp selected_right(nil, _row, _cols), do: -1
  defp selected_right({end_row, _col}, row, _cols) when row > end_row, do: -1
  defp selected_right({end_row, col}, row, _cols) when row == end_row, do: col
  defp selected_right(_head, _row, cols), do: cols - 1

  defp position(row, col), do: "\e[#{row + 1};#{col + 1}H"

  defp verify_cells!(ctx, before, current, candidate) do
    baseline =
      Surface.new(cols: ctx.cols, rows: ctx.rows)
      |> Surface.write(Frame.build_payload(nil, ctx.lines, [], before, ctx.cols))

    expected = Surface.write(baseline, current)
    actual = Surface.write(baseline, candidate)

    if actual.screen != expected.screen do
      raise "prototype changed the displayed cells or styles"
    end
  end

  defp print_csv(values), do: IO.puts(Enum.join(values, ","))
end

BreezeVTerm.SelectionBenchmark.run()

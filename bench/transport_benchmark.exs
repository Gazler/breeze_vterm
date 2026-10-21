# mix run bench/transport_benchmark.exs
# Actual Breeze frame payloads; no SSH connection, framing or compression.
Code.require_file("support/baseline.exs", __DIR__)
{_, baseline_hash} = BreezeVTerm.BenchBaseline.load(:render)

defmodule BreezeVTerm.TransportBenchmark.BeforeView do
  use Breeze.View
  import BreezeVTerm.Baseline.Components
  def mount(opts, term), do: {:ok, assign(term, surface: opts[:surface])}
  def handle_info({:surface, surface}, term), do: {:noreply, assign(term, surface: surface)}

  def render(assigns) do
    ~H"""
    <box class="width-full height-full">
      <.terminal id="terminal" surface={@surface} selectable cursor-blink={false}/>
    </box>
    """
  end
end

defmodule BreezeVTerm.TransportBenchmark.AfterView do
  use Breeze.View
  import Breeze.VTerm.Components
  def mount(opts, term), do: {:ok, assign(term, surface: opts[:surface])}
  def handle_info({:surface, surface}, term), do: {:noreply, assign(term, surface: surface)}

  def render(assigns) do
    ~H"""
    <box class="width-full height-full">
      <.terminal id="terminal" surface={@surface} selectable cursor-blink={false}/>
    </box>
    """
  end
end

defmodule BreezeVTerm.TransportBenchmark do
  alias Breeze.Server.Frame
  alias BreezeVTerm.TransportBenchmark.{BeforeView, AfterView}

  def run(hash) do
    sizes =
      System.get_env("SIZES", "120x40,270x100,400x120")
      |> String.split(",")
      |> Enum.map(fn size ->
        [cols, rows] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
        if cols < 4 or rows < 4, do: raise("SIZES must be at least 4x4")
        {cols, rows}
      end)

    renderer = if System.get_env("FRAME_RENDERER") == "diff", do: Breeze.VTerm.Frame, else: Frame
    IO.puts("Before: #{hash}; after: working tree. Same Breeze/dependencies/theme.")

    IO.puts(
      "After frame renderer: #{inspect(renderer)}; times are median warm frame composition only."
    )

    IO.puts("Full-width pane, static cursor; steady viewport; no scrolling or clipboard copying.")

    IO.puts(
      "Bytes are server→client ANSI payloads before SSH framing/compression. 60 updates/s is a projection."
    )

    IO.puts(
      "size,fixture,operation,before_B,after_B,delta_B,after_KiB_s_at_60_updates,before_us,after_us"
    )

    for {cols, rows} <- sizes, fixture <- [:ascii, :styled, :wide] do
      before =
        measure(
          BreezeVTerm.Baseline.Surface,
          BreezeVTerm.Baseline.Implicit,
          BeforeView,
          cols,
          rows,
          fixture
        )

      after_result =
        measure(
          Breeze.VTerm.Surface,
          Breeze.VTerm.Implicit,
          AfterView,
          cols,
          rows,
          fixture,
          renderer
        )

      for {operation, payload} <- before do
        current = Keyword.fetch!(after_result, operation)
        # Every measured comparison must paint the same visible cells/styles.
        if payload.screen != current.screen,
          do: raise("Different rendered results for #{fixture}/#{operation}")

        a = byte_size(payload.bytes)
        b = byte_size(current.bytes)

        IO.puts(
          Enum.join(
            [
              "#{cols}x#{rows}",
              fixture,
              operation,
              a,
              b,
              b - a,
              Float.round(b * 60 / 1024, 2),
              payload.us,
              current.us
            ],
            ","
          )
        )
      end
    end
  end

  defp measure(model, implicit, view, cols, rows, fixture, renderer \\ Frame) do
    line = fixture_line(fixture, cols)
    bytes = Enum.join(List.duplicate(line, rows), "\r\n")
    surface = model.new(cols: cols, rows: rows) |> model.write(bytes <> "\e[H")
    terminal = %Termite.Terminal{size: %{width: cols, height: rows}}
    theme = Breeze.Theme.builtin(:gruvbox)

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: view,
        terminal: terminal,
        theme: theme,
        start_opts: [surface: surface]
      )

    try do
      initial = snapshot(pid, terminal, theme)
      base_overlays = overlays(implicit, initial, nil, cols)

      {initial_payload, initial_us} =
        timed_frame(renderer, [nil, initial.lines, [], base_overlays, cols])

      paint = fn previous, next ->
        old_overlays = overlays(implicit, initial, previous, cols)
        new_overlays = overlays(implicit, initial, next, cols)

        {bytes, us} =
          timed_frame(renderer, [initial.lines, initial.lines, old_overlays, new_overlays, cols])

        screen = painted_screen(initial.lines, old_overlays, bytes, cols, rows)
        %{bytes: bytes, screen: screen, us: us}
      end

      middle = div(rows, 2)
      full = {rows - 1, cols - 1}

      selections = [
        select_all: paint.(nil, full),
        extend_cell: paint.({middle, div(cols, 2) - 1}, {middle, div(cols, 2)}),
        extend_row: paint.({middle - 1, cols - 1}, {middle, cols - 1}),
        clear_selection: paint.(full, nil),
        idle: paint.(full, full)
      ]

      replacement = Enum.join(List.duplicate(fixture_line(fixture, cols, true), rows), "\r\n")

      # Explicit positions avoid treating the old delayed-wrap bug as an optimization.
      changes =
        for {name, output} <- [
              {:edit_cell, "\e[1;1HZ"},
              {:change_all, "\e[H" <> replacement <> "\e[H"}
            ] do
          updated = model.write(surface, output)
          Breeze.ChildServer.dispatch_info(pid, {:surface, updated}, terminal)
          next = snapshot(pid, terminal, theme)
          new_overlays = overlays(implicit, next, nil, cols)

          {payload, us} =
            timed_frame(renderer, [initial.lines, next.lines, base_overlays, new_overlays, cols])

          {name,
           %{
             bytes: payload,
             us: us,
             screen: painted_screen(initial.lines, base_overlays, payload, cols, rows)
           }}
        end

      first = %{
        bytes: initial_payload,
        us: initial_us,
        screen: painted_screen([], [], initial_payload, cols, rows)
      }

      [initial_paint: first] ++ changes ++ selections
    after
      GenServer.stop(pid)
    end
  end

  defp timed_frame(renderer, args) do
    payload = apply(renderer, :build_payload, args)
    samples = System.get_env("SAMPLES", "7") |> String.to_integer()

    if samples < 1, do: raise("SAMPLES must be positive")

    times =
      Task.async(fn ->
        for _ <- 1..samples do
          :erlang.garbage_collect()
          elem(:timer.tc(fn -> apply(renderer, :build_payload, args) end), 0)
        end
      end)
      |> Task.await(:infinity)

    {payload, times |> Enum.sort() |> Enum.at(div(samples, 2))}
  end

  defp snapshot(pid, terminal, theme) do
    {:ok, _, box, [decoration]} =
      Breeze.ChildServer.render_snapshot(pid, terminal: terminal, focused: "terminal")

    %{viewport_width: width, viewport_height: height} = decoration.layout

    if width != terminal.size.width or height != terminal.size.height,
      do: raise("Unexpected viewport")

    %{
      lines: Frame.normalize_lines(box.content, height),
      decoration: decoration,
      ctx: %{layout: decoration.layout, theme: theme, now: 0}
    }
  end

  defp overlays(implicit, snapshot, head, cols) do
    selection =
      if head, do: %{anchor: {0, 0}, head: head, moved?: true, dragging?: true, width: cols}

    state = Map.put(snapshot.decoration.state, :selection, selection)

    {:ok, _, overlays: overlays} =
      implicit.animate(:root, snapshot.decoration.box, [], state, snapshot.ctx)

    overlays
  end

  defp painted_screen(lines, overlays, bytes, cols, rows) do
    baseline = if lines == [], do: "", else: Frame.build_payload(nil, lines, [], overlays, cols)

    Breeze.VTerm.Surface.new(cols: cols, rows: rows)
    |> Breeze.VTerm.Surface.write(baseline)
    |> Breeze.VTerm.Surface.write(bytes)
    |> Map.take([:screen, :cursor, :style, :wrap_pending?])
  end

  defp fixture_line(fixture, cols), do: fixture_line(fixture, cols, false)

  defp fixture_line(:ascii, cols, alternate?),
    do:
      for(col <- 0..(cols - 1), into: "", do: <<if(alternate?, do: ?A, else: ?a) + rem(col, 26)>>)

  defp fixture_line(:styled, cols, alternate?) do
    text = fixture_line(:ascii, cols, alternate?)

    for col <- 0..(cols - 1)//8, into: "" do
      color = if rem(div(col, 8), 2) == 0, do: 31, else: 32
      "\e[#{color}m" <> binary_part(text, col, min(8, cols - col))
    end <> "\e[0m"
  end

  defp fixture_line(:wide, cols, alternate?),
    do:
      String.duplicate(if(alternate?, do: "語", else: "界"), div(cols, 2)) <>
        String.duplicate("x", rem(cols, 2))
end

BreezeVTerm.TransportBenchmark.run(baseline_hash)

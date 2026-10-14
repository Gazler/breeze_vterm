# LIBVTERM_SRC=/path/to/libvterm-0.3.3 mix run bench/libvterm_benchmark.exs
# The C oracle is compiled into a temporary directory, never linked into BEAM.
Code.require_file("support/baseline.exs", __DIR__)

defmodule LibvtermComparison do
  alias Breeze.VTerm.Surface

  def run do
    source =
      System.get_env("LIBVTERM_SRC") ||
        raise "Set LIBVTERM_SRC to an unpacked libvterm 0.3.3 source release"

    dir =
      Path.join(
        System.tmp_dir!(),
        "breeze-libvterm-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)

    try do
      exe = Path.join(dir, "reference")
      compiler = System.get_env("CC", "cc")
      files = Path.wildcard(Path.join(source, "src/*.c"))
      if files == [], do: raise("No C sources in #{source}")

      args =
        [
          "-O2",
          "-std=c99",
          "-I#{Path.join(source, "include")}",
          Path.join(__DIR__, "libvterm_reference.c")
        ] ++ files ++ ["-o", exe]

      {output, 0} = System.cmd(compiler, args, stderr_to_stdout: true)
      if output != "", do: IO.write(output)

      IO.puts(
        "Reference: #{source}; #{compiler} -O2; UTF-8; scrollback disabled in both implementations"
      )

      validate(exe, dir)

      unless System.get_env("CHECK_ONLY") == "1" do
        baseline =
          if System.get_env("BASELINE_REF") do
            {module, hash} = BreezeVTerm.BenchBaseline.load()
            IO.puts("Pre-port Elixir baseline: #{hash}; shared current dependencies")
            module
          end

        benchmark(exe, dir, baseline)
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp validate(exe, dir) do
    {cases, _} = Code.eval_file(Path.expand("../test/fixtures/libvterm_cases.txt", __DIR__))

    Enum.each(cases, fn {name, cols, rows, bytes} ->
      path = Path.join(dir, "input")
      File.write!(path, bytes)
      # Feed a whole stream and one byte at a time, on both sides of the comparison.
      Enum.each([0, 1], fn size ->
        native = invoke(exe, ["snapshot", cols, rows, path, 1, size, 1]) |> snapshot(cols)
        chunks = if size == 0, do: [bytes], else: for(<<byte <- bytes>>, do: <<byte>>)

        surface =
          Enum.reduce(
            chunks,
            Surface.new(cols: cols, rows: rows, scrollback_limit: 0),
            &Surface.write(&2, &1)
          )

        actual = Map.take(surface, [:screen, :cursor])

        if native != actual do
          rows =
            Enum.zip(native.screen, actual.screen)
            |> Enum.with_index()
            |> Enum.reject(fn {{a, b}, _} -> a == b end)

          raise "#{name} (chunk #{size}) differs: cursor C=#{inspect(native.cursor)} Elixir=#{inspect(actual.cursor)}; rows=#{inspect(rows, limit: :infinity)}"
        end
      end)
    end)

    IO.puts(
      "Conformance: #{length(cases)} streams × 2 chunkings agree on every cell, supported style and cursor position"
    )
  end

  defp snapshot(output, cols) do
    [cursor | cells] = String.split(output, "\n", trim: true)
    [row, col] = cursor |> String.split("\t") |> Enum.map(&String.to_integer/1)

    screen =
      Enum.map(cells, fn line ->
        [chars, bold, italic, reverse, fg, bg] = String.split(line, "\t")

        text =
          if chars == "-",
            do: "",
            else: chars |> String.split(",") |> Enum.map(&String.to_integer/1) |> List.to_string()

        style =
          %{}
          |> attr(:bold, bold)
          |> attr(:italic, italic)
          |> attr(:reverse, reverse)
          |> color(:foreground_color, fg)
          |> color(:background_color, bg)

        %{text: text, style: style}
      end)
      |> Enum.chunk_every(cols)

    %{screen: screen, cursor: %{row: row, col: col}}
  end

  defp attr(style, _key, "0"), do: style
  defp attr(style, key, _), do: Map.put(style, key, true)
  defp color(style, _key, "d"), do: style
  defp color(style, key, "i:" <> n), do: Map.put(style, key, String.to_integer(n))

  defp color(style, key, "r:" <> rgb),
    do:
      Map.put(
        style,
        key,
        rgb |> String.split(",") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
      )

  defp benchmark(exe, dir, baseline) do
    iterations = String.to_integer(System.get_env("ITERATIONS", "10000"))
    samples = String.to_integer(System.get_env("SAMPLES", "5"))
    if iterations < 1 or samples < 1, do: raise("ITERATIONS and SAMPLES must be positive")

    sizes =
      System.get_env("SIZES", "120x40,400x120")
      |> String.split(",")
      |> Enum.map(fn size ->
        [cols, rows] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
        if cols < 2 or rows < 1, do: raise("SIZES requires at least 2 columns and 1 row")
        {cols, rows}
      end)

    IO.puts(
      "Median µs/write (#{samples} samples), emulation only; construction, compilation, process startup, I/O and snapshot extraction excluded"
    )

    if baseline,
      do: IO.puts("size\tworkload\tbytes/write\tbefore µs\tafter µs\tC µs\tafter/before"),
      else: IO.puts("size\tworkload\tbytes/write\tElixir µs\tC µs\tElixir/C\tElixir MiB/s")

    for {cols, rows} <- sizes do
      bulk = String.duplicate(String.duplicate("x", cols - 2) <> "\r\n", 1000)

      for {label, bytes, count} <- [
            {"prompt", "x\b \b", iterations},
            {"styled", "\e[32mhello\e[0m world\r\n", iterations},
            {"repaint", "\e[H" <> String.duplicate("x", cols * rows), 100},
            {"bulk", bulk, 10}
          ] do
        path = Path.join(dir, "input")
        File.write!(path, bytes)
        initial = Surface.new(cols: cols, rows: rows, scrollback_limit: 0)
        Surface.write(initial, bytes)

        # Compare the repeated workload too, outside either timed region.
        reference = invoke(exe, ["snapshot", cols, rows, path, count, 0, 1]) |> snapshot(cols)
        actual = Enum.reduce(1..count, initial, fn _, s -> Surface.write(s, bytes) end)

        if reference != Map.take(actual, [:screen, :cursor]),
          do: raise("Benchmark #{label} at #{cols}x#{rows} produces different screens")

        {before_time, elixir} = time_models(baseline, cols, rows, bytes, count, samples, actual)

        native =
          invoke(exe, ["bench", cols, rows, path, count, 0, samples])
          |> String.split("\n", trim: true)
          |> Enum.map(fn line -> line |> String.split("\t") |> hd() |> String.to_float() end)
          |> median()

        mib = byte_size(bytes) / (elixir / 1_000_000) / 1_048_576

        if baseline do
          IO.puts(
            "#{cols}x#{rows}\t#{label}\t#{byte_size(bytes)}\t#{Float.round(before_time, 3)}\t#{Float.round(elixir, 3)}\t#{native}\t#{Float.round(elixir / before_time, 2)}x"
          )
        else
          IO.puts(
            "#{cols}x#{rows}\t#{label}\t#{byte_size(bytes)}\t#{Float.round(elixir, 3)}\t#{native}\t#{Float.round(elixir / native, 1)}x\t#{Float.round(mib, 2)}"
          )
        end
      end
    end
  end

  defp time_models(baseline, cols, rows, bytes, count, samples, expected) do
    models = if baseline, do: [baseline, Surface], else: [Surface]

    initials =
      Map.new(models, fn model ->
        initial = model.new(cols: cols, rows: rows, scrollback_limit: 0)
        model.write(initial, bytes)
        {model, initial}
      end)

    # Alternate order to reduce systematic warmup/frequency bias. Final cell
    # comparisons are outside the timer; the old physical cursor bug is excluded.
    measurements =
      for sample <- 1..samples, reduce: %{} do
        acc ->
          order = if rem(sample, 2) == 0, do: Enum.reverse(models), else: models

          Enum.reduce(order, acc, fn model, acc ->
            :erlang.garbage_collect()

            {us, result} =
              :timer.tc(fn ->
                Enum.reduce(1..count, Map.fetch!(initials, model), fn _, s ->
                  model.write(s, bytes)
                end)
              end)

            if result.screen != expected.screen,
              do: raise("Benchmark model #{inspect(model)} produces different cells")

            Map.update(acc, model, [us / count], &[us / count | &1])
          end)
      end

    {if(baseline, do: median(measurements[baseline])), median(measurements[Surface])}
  end

  defp median(samples), do: samples |> Enum.sort() |> Enum.at(div(length(samples), 2))

  defp invoke(exe, args) do
    case System.cmd(exe, Enum.map(args, &to_string/1), stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "Reference exited #{status}: #{output}"
    end
  end
end

LibvtermComparison.run()

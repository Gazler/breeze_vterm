# LIBVTERM_SRC=/path/to/libvterm-0.3.3 mix run bench/frame_oracle.exs
# Independent C replay of both renderers, including attributes not in Surface.
defmodule BreezeVTerm.FrameOracle do
  alias Breeze.Server.Frame, as: Legacy
  alias Breeze.VTerm.Frame

  def run do
    src = System.fetch_env!("LIBVTERM_SRC") |> Path.expand()

    dir =
      Path.join(
        System.tmp_dir!(),
        "breeze-frame-oracle-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)

    try do
      exe = Path.join(dir, "reference")

      args =
        ["-O2", "-std=c99", "-I#{src}/include", Path.expand("libvterm_reference.c", __DIR__)] ++
          Path.wildcard(Path.join(src, "src/*.c")) ++ ["-o", exe]

      {output, status} = System.cmd(System.get_env("CC", "cc"), args, stderr_to_stdout: true)
      if status != 0, do: raise(output)
      width = 80
      height = 4
      styles = ["", "\e[31m", "\e[1;3;4;5;7;9;38;2;12;34;56;48;5;42m"]

      cases =
        for style <- styles,
            text <- [String.duplicate("a", width), String.duplicate("界", div(width, 2))] do
          line = style <> text <> "\e[0m"
          lines = List.duplicate(line, height)

          first = %{
            x: 0,
            y: 1,
            content: "\e[0m" <> style <> "\e[7m" <> String.slice(text, 0, 5) <> "\e[0m"
          }

          more = %{
            first
            | content: "\e[0m" <> style <> "\e[7m" <> String.slice(text, 0, 6) <> "\e[0m"
          }

          cursor = %{
            x: 0,
            y: 0,
            char: String.first(text),
            foreground_color: 0,
            background_color: 3
          }

          changes = [
            {lines, lines, [], [first]},
            {lines, lines, [first], [more]},
            {lines, lines, [more], [first]},
            {lines, lines, [more], []},
            {lines, lines, [cursor], [%{cursor | x: 4}]},
            {lines, List.replace_at(lines, 2, style <> "xyz" <> "\e[0m"), [], []}
          ]

          changes
        end
        |> List.flatten()

      cases = cases ++ scroll_cases(styles, width)

      Enum.each(Enum.with_index(cases), fn {{old, new, old_overlays, overlays}, index} ->
        height = length(old)
        initial = Legacy.build_payload(nil, old, [], old_overlays, width)
        expected = initial <> Legacy.build_payload(old, new, old_overlays, overlays, width)
        candidate = initial <> Frame.build_payload(old, new, old_overlays, overlays, width)

        # Probe delayed wrap and restored scrolling margins as well as the
        # immediate result; leaked terminal state could corrupt a later frame.
        for tail <- ["", "!\e[#{height};1H\eD\e[H*"] do
          a = snapshot(exe, dir, expected <> tail, width, height)
          b = snapshot(exe, dir, candidate <> tail, width, height)

          if a != b do
            differences =
              Enum.zip(String.split(a, "\n"), String.split(b, "\n"))
              |> Enum.with_index()
              |> Enum.filter(fn {{x, y}, _} -> x != y end)
              |> Enum.take(5)

            raise(
              "C libvterm disagrees for frame case #{index}, probe #{inspect(tail)}: #{inspect(differences)}"
            )
          end
        end
      end)

      IO.puts(
        "#{length(cases)} frame transitions match in C libvterm, including cursor, wide cells, extended attributes and subsequent wrap/scroll probes."
      )
    after
      File.rm_rf!(dir)
    end
  end

  defp scroll_cases(styles, width) do
    full =
      for style <- styles,
          {glyph, size} <- [{"a", 1}, {"界", 2}],
          delta <- [-8, -3, -1, 1, 3, 8] do
        source =
          for row <- 0..31 do
            text =
              String.pad_leading(to_string(row), 2, "0") <>
                String.duplicate(glyph, div(width - 2, size))

            style <> text <> "\e[0m"
          end

        old = Enum.slice(source, 8, 12)
        new = Enum.slice(source, 8 + delta, 12)

        overlay = %{
          x: 2,
          y: 4,
          content: style <> "\e[7m" <> String.duplicate(glyph, 8) <> "\e[0m"
        }

        next_overlays = if (4 - delta) in 0..11, do: [%{overlay | y: 4 - delta}], else: []
        {old, new, [overlay], next_overlays}
      end

    partial =
      for style <- styles, delta <- [-1, 1] do
        sidebar =
          for row <- 0..9, do: if(row in [3, 6], do: "Menu #{row}  | ", else: "        | ")

        source =
          for row <- 0..11, do: style <> String.duplicate(<<65 + row>>, width - 10) <> "\e[0m"

        frame = fn offset ->
          [String.duplicate("H", width)] ++
            Enum.zip_with(sidebar, Enum.slice(source, offset, 10), &(&1 <> &2)) ++
            [String.duplicate("F", width)]
        end

        popup = [%{x: 30, y: 5, content: "\e[7mPopup\e[0m"}]
        {frame.(1), frame.(1 + delta), popup, popup}
      end

    full ++ partial
  end

  defp snapshot(exe, dir, bytes, width, height) do
    path = Path.join(dir, "input.ansi")
    File.write!(path, bytes)

    {output, 0} =
      System.cmd(exe, ["snapshot-attrs", to_string(width), to_string(height), path, "1", "0", "1"])

    # libvterm's putglyph updates the leading cell's pen, but only marks the
    # continuation's chars[0]; its other fields retain unrelated previous data.
    # Compare continuation positions, and styles on the glyphs that own them.
    output
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "-\t" <> _ -> "-"
      line -> line
    end)
  end
end

BreezeVTerm.FrameOracle.run()

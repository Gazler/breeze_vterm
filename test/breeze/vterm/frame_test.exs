defmodule Breeze.VTerm.FrameTest do
  use ExUnit.Case, async: true

  alias Breeze.Server.Frame, as: Legacy
  alias Breeze.VTerm.{Frame, Surface}

  test "a selection extension only repaints its changed cell" do
    line = String.duplicate("a", 400)
    before = [highlight(0, 0, String.duplicate("a", 200))]
    after_overlays = [highlight(0, 0, String.duplicate("a", 201))]
    {original, result} = check([line], [line], before, after_overlays, 400)
    assert byte_size(result) < 40
    assert byte_size(result) < byte_size(original) / 10
    assert result =~ "\e[1;201H"
    refute result =~ "aa"
  end

  test "selection start, shrink, clear, reverse styles and overlapping cursor" do
    lines = ["\e[31ma\e[7mbc\e[27mdef\e[0m", "other"]
    cursor = %{x: 1, y: 0, char: "b", foreground_color: 0, background_color: 3}
    one = [cursor, highlight(0, 0, "a")]
    many = [cursor, highlight(0, 0, "abcde")]

    for {old, new} <- [{[cursor], one}, {one, many}, {many, one}, {many, [cursor]}] do
      check(lines, lines, old, new, 12)
    end
  end

  test "text edits, removed suffixes and separated spans preserve physical cursor and wrap" do
    for {old, new} <- [
          {"abcdefghij", "abXdefghYj"},
          {"abcdefghij", "ab"},
          {"ab", "abcdefghij"},
          {"\e[31mabcdefghij\e[0m", "\e[32ma\e[31mbcdefghij\e[0m"}
        ] do
      check([old], [new], [], [], 10)
    end
  end

  test "wide glyph changes, replacements and selection stay on glyph boundaries" do
    for {old, new} <- [
          {"a界bc界z", "a語bc界z"},
          {"a界bc界z", "axxbc界z"},
          {"axxbc界z", "a界bc界z"},
          {"\e[31ma界bc界z\e[0m", "\e[32ma界bc界z\e[0m"},
          {"a界bc界z", "a界bc界語"}
        ] do
      check([old], [new], [], [], 9)
    end

    check(["a界bc界z"], ["a界bc界z"], [highlight(1, 0, "界")], [highlight(1, 0, "界bc界")], 9)
  end

  test "moving, hiding and overlapping overlays repair the underlying text" do
    lines = ["abcdefghijkl", "012345678901", "------------"]

    states = [
      [],
      [highlight(3, 1, "345")],
      [highlight(2, 1, "23456"), highlight(4, 1, "XYZ")],
      [highlight(8, 0, "ijkl")],
      [%{x: 8, y: 0, content: "", visible?: false}],
      []
    ]

    for [old, new] <- Enum.chunk_every(states, 2, 1, :discard),
        do: check(lines, lines, old, new, 12)
  end

  test "unmodelled commands, complex text and unsafe overlays use the original writer" do
    for {line, overlays} <- [
          {"\e[31mleaking style", []},
          {"\e]8;;https://example.com\e\\link\e]8;;\e\\", []},
          {"ab\tcd", []},
          {"é", []},
          {"界text", [highlight(1, 0, "x")]},
          {"text", [%{x: 1, y: 0, content: "x", clear_line: true}]},
          {"text", [%{x: 1, y: 0, content: "x", no_wrap: true}]},
          {"text", [highlight(19, 0, "long")]}
        ] do
      original = Legacy.build_payload(["old"], [line], [], overlays, 20)

      assert Frame.build_payload(["old"], [line], [], overlays, 20) ==
               original
    end
  end

  test "SGR attributes outside the Surface subset are retained verbatim" do
    style = "\e[2;3;4;5;9;38;2;12;34;56;48;5;42m"
    line = style <> String.duplicate("x", 100) <> "\e[0m"
    changed = style <> "y" <> String.duplicate("x", 99) <> "\e[0m"
    {original, result} = check([line], [changed], [], [], 100)
    assert byte_size(result) < byte_size(original)
    assert result =~ style
  end

  test "initial paint, idle frames and geometry changes use existing semantics" do
    assert Frame.build_payload(nil, ["abc"], [], [], 10) ==
             Legacy.build_payload(nil, ["abc"], [], [], 10)

    assert Frame.build_payload(["abc"], ["abc"], [], [], 10) == ""

    hidden = [%{x: 0, y: 0, content: "hidden", visible?: false}]
    assert Frame.build_payload(["abc"], ["abc"], [], hidden, 10) == ""

    assert Frame.build_payload(["abc"], ["abc", "def"], [], [], 10) ==
             Legacy.build_payload(["abc"], ["abc", "def"], [], [], 10)
  end

  test "deterministic mixed edits and selection updates replay identically" do
    :rand.seed(:exsss, {14, 71, 23})
    width = 30
    initial = List.duplicate(String.duplicate("a", width), 4)

    Enum.reduce(1..80, {initial, []}, fn _, {lines, overlays} ->
      y = :rand.uniform(4) - 1
      x = :rand.uniform(width) - 1
      text = Enum.at(lines, y)
      replacement = <<?a + :rand.uniform(25)>>
      text = binary_part(text, 0, x) <> replacement <> binary_part(text, x + 1, width - x - 1)
      next = List.replace_at(lines, y, text)
      count = :rand.uniform(width - x)
      selection = [highlight(x, y, binary_part(text, x, count))]
      check(lines, next, overlays, selection, width)
      {next, selection}
    end)
  end

  test "scrolling moves selection with the text and repairs its changing boundaries" do
    width = 80
    source = for row <- 0..30, do: String.duplicate(<<65 + row>>, width)

    for delta <- [-3, -1, 1, 3] do
      old = Enum.slice(source, 10, 10)
      new = Enum.slice(source, 10 + delta, 10)

      selection = fn offset ->
        for {text, y} <- Enum.with_index(Enum.slice(source, offset, 10)), offset + y <= 15 do
          highlight(0, y, if(offset + y == 15, do: String.slice(text, 0, 20), else: text))
        end
      end

      before = selection.(10)
      after_overlays = selection.(10 + delta)
      {_, candidate} = check(old, new, before, after_overlays, width)
      assert candidate =~ if(delta > 0, do: "\eD", else: "\eM")
      assert candidate =~ "\e[r"
      cell_only = Frame.build_payload(old, new, before, after_overlays, width, scroll: false)
      assert byte_size(candidate) < byte_size(cell_only) / 2
    end
  end

  test "scroll repairs stationary sidebar labels and popup while preserving header and footer" do
    sidebar = for row <- 0..9, do: if(row in [3, 6], do: "Menu #{row}  | ", else: "        | ")
    content = for row <- 0..10, do: String.duplicate(<<65 + row>>, 90)

    frame = fn offset ->
      [String.duplicate("H", 100)] ++
        Enum.zip_with(sidebar, Enum.slice(content, offset, 10), &(&1 <> &2)) ++
        [String.duplicate("F", 100)]
    end

    old = frame.(0)
    new = frame.(1)
    popup = [highlight(35, 4, "Popup stays here")]
    {_, candidate} = check(old, new, popup, popup, 100)
    assert candidate =~ "\eD"

    assert byte_size(candidate) <
             byte_size(Frame.build_payload(old, new, popup, popup, 100, scroll: false))

    # The scrolling region must exclude the unchanged header/footer.
    assert candidate =~ "\e[2;11r"
  end

  test "scrolling wide styled rows restores default blank styling and full margins" do
    for delta <- [-1, 1] do
      source = for row <- 0..9, do: "\e[31;44m#{row}" <> String.duplicate("界", 39) <> "x\e[0m"
      old = Enum.slice(source, 1, 8)
      new = Enum.slice(source, 1 + delta, 8) |> List.replace_at(if(delta > 0, do: 7, else: 0), "")
      {_, candidate} = check(old, new, [], [], 80)
      assert candidate =~ if(delta > 0, do: "\eD", else: "\eM")
    end
  end

  test "scrollbar arrows do not force repainting entire boundary rows" do
    frame = fn offset ->
      for y <- 0..9 do
        edge =
          cond do
            y == 0 -> "^"
            y == 9 -> "v"
            true -> "|"
          end

        String.duplicate(<<65 + offset + y>>, 199) <> edge
      end
    end

    {_, payload} = check(frame.(0), frame.(1), [], [], 200)
    assert payload =~ "\e[1;10r"
    assert byte_size(payload) < 400
  end

  test "unsupported content prevents scrolling and tiny shifts keep the cheaper payload" do
    old = ["\e]8;;https://example.com\e\\link\e]8;;\e\\", "aaaa", "bbbb", "cccc", "dddd"]
    new = [hd(old), "bbbb", "cccc", "dddd", "eeee"]

    assert Frame.build_payload(old, new, [], [], 8) ==
             Legacy.build_payload(old, new, [], [], 8)

    {_, candidate} = check(["a", "b", "c"], ["b", "c", "d"], [], [], 1)
    refute candidate =~ "\eD"
  end

  test "successive scrolls and stationary overlays leave the terminal ready for the next frame" do
    source = for row <- 0..60, do: "#{row}:" <> String.duplicate(<<65 + rem(row, 26)>>, 55)
    old = Enum.slice(source, 15, 10)
    initial = Surface.new(cols: 60, rows: 10, scrollback_limit: 0)
    initial = Surface.write(initial, Legacy.build_payload(nil, old, [], [], 60))

    Enum.reduce([-1, -3, 2, 4, -2, 1, -4, 3], {15, old, [], initial}, fn delta,
                                                                         {offset, old, overlays,
                                                                          display} ->
      offset = offset + delta
      new = Enum.slice(source, offset, 10)
      next_overlays = [highlight(8, 4, "stationary")]
      payload = Frame.build_payload(old, new, overlays, next_overlays, 60)
      display = Surface.write(display, payload)
      expected = Surface.write(initial, Legacy.build_payload(nil, new, [], next_overlays, 60))
      assert display.screen == expected.screen
      assert display.scroll_region == {0, 9}
      {offset, new, next_overlays, display}
    end)
  end

  defp highlight(x, y, text), do: %{x: x, y: y, content: "\e[0m\e[7m" <> text <> "\e[0m"}

  defp check(previous, lines, old, new, width) do
    original = Legacy.build_payload(previous, lines, old, new, width)
    candidate = Frame.build_payload(previous, lines, old, new, width)

    initial =
      Surface.new(cols: width, rows: length(lines), scrollback_limit: 0)
      |> Surface.write(Legacy.build_payload(nil, previous, [], old, width))

    expected = Surface.write(initial, original)
    actual = Surface.write(initial, candidate)
    assert actual.screen == expected.screen
    assert actual.cursor == expected.cursor
    assert actual.wrap_pending? == expected.wrap_pending?
    assert actual.style == expected.style
    assert actual.scroll_region in [nil, {0, length(lines) - 1}]
    assert byte_size(candidate) <= byte_size(original)
    {original, candidate}
  end
end

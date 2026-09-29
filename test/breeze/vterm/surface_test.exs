defmodule Breeze.VTerm.SurfaceTest do
  use ExUnit.Case, async: true

  alias Breeze.VTerm.Surface

  test "UTF-8 codepoints survive every byte split" do
    for text <- ["é", "❯", "🍏"], split <- 1..(byte_size(text) - 1) do
      prefix = binary_part(text, 0, split)
      suffix = binary_part(text, split, byte_size(text) - split)
      surface = Surface.new(cols: 8, rows: 2) |> Surface.write(prefix)
      assert surface.buffer == prefix
      assert surface.cursor == %{row: 0, col: 0}
      surface = Surface.write(surface, suffix <> "x")
      assert surface.buffer == ""

      assert surface.screen ==
               (Surface.new(cols: 8, rows: 2) |> Surface.write(text <> "x")).screen
    end
  end

  test "malformed UTF-8 is discarded without losing subsequent output" do
    for bytes <- [<<255>>, <<128>>, <<192, 175>>, <<237, 160, 128>>, <<244, 144, 128, 128>>] do
      surface = Surface.new(cols: 8, rows: 1) |> Surface.write(bytes <> "ok")
      assert Surface.lines(surface) == ["ok      "]
      assert surface.buffer == ""
    end

    surface = Surface.new(cols: 8, rows: 1) |> Surface.write(<<226>>) |> Surface.write("ok")
    assert Surface.lines(surface) == ["ok      "]
  end

  test "UTF-8 encoded controls cannot leak into rendered text" do
    for codepoint <- 0x80..0x9F do
      surface =
        Surface.new(cols: 8, rows: 1)
        |> Surface.write(<<0xC2>>)
        |> Surface.write(<<codepoint>> <> "ok")

      assert Surface.lines(surface) == ["ok      "]
    end
  end

  test "OSC payloads are discarded incrementally, including split terminators" do
    surface = Surface.new(cols: 8, rows: 1) |> Surface.write("\e]52;c;")

    surface =
      Enum.reduce(1..64, surface, fn _, acc ->
        next = Surface.write(acc, String.duplicate("x", 4096))
        assert next.buffer == ""
        assert next.parser_state == :osc
        next
      end)

    surface = surface |> Surface.write("\e") |> Surface.write("\\ok")
    assert surface.parser_state == :ground
    assert Surface.lines(surface) == ["ok      "]
  end

  test "overlong CSI parameters stay bounded and are ignored through their final byte" do
    surface = Surface.new(cols: 8, rows: 1) |> Surface.write("\e[")

    surface =
      Enum.reduce(1..64, surface, fn _, acc ->
        next = Surface.write(acc, String.duplicate("1;", 2048))
        assert next.buffer == ""
        assert next.parser_state == :discard_csi
        next
      end)

    surface = Surface.write(surface, "31mplain\e[32mG")

    assert Surface.slice(surface, 0, 1) == [
             [{"plain", %{}}, {"G", %{foreground_color: 2}}, {"  ", %{}}]
           ]
  end

  test "CSI parsing is independent of chunk boundaries and supports cancellation" do
    bytes = "\e[38;2;12;34;56mhello\e[0m\e]ignored\a!"
    initial = Surface.new(cols: 10, rows: 1)
    chunked = Enum.reduce(:binary.bin_to_list(bytes), initial, &Surface.write(&2, <<&1>>))
    assert chunked.screen == Surface.write(initial, bytes).screen

    for prefix <- ["\e[12;", "\e[" <> String.duplicate("1", 300), "\e]ignored"] do
      surface = initial |> Surface.write(prefix) |> Surface.write(<<24>> <> "ok")
      assert Surface.lines(surface) == ["ok        "]
    end
  end

  test "an empty-prompt backspace bell does not occupy a cell or damage rendered rows" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("❯ ")
    after_bell = Surface.write(surface, "\a")

    assert after_bell.cursor == surface.cursor
    assert Surface.lines(after_bell) == Surface.lines(surface)
    assert Surface.slice(after_bell, 0, 2) == Surface.slice(surface, 0, 2)
  end

  test "ignores nonprinting control bytes while preserving backspace editing" do
    surface =
      Surface.new(cols: 8, rows: 2)
      |> Surface.write("❯ x\b \b" <> <<0, 7, 14, 15, 17, 19, 127>>)

    assert Surface.lines(surface) == ["❯       ", "        "]
    assert surface.cursor == %{row: 0, col: 2}
  end

  test "writes printable text into the screen" do
    surface =
      Surface.new(cols: 8, rows: 2)
      |> Surface.write("hello")

    assert Surface.lines(surface) == ["hello   ", "        "]
    assert surface.cursor == %{row: 0, col: 5}
  end

  test "handles line wrapping and scrollback" do
    surface =
      Surface.new(cols: 4, rows: 2)
      |> Surface.write("abcdEFGHI")

    assert Surface.lines(surface) == ["EFGH", "I   "]
    assert Surface.scrollback_rows(surface) == 1
  end

  test "virtual text exposes scrollback before the visible screen" do
    surface =
      Surface.new(cols: 4, rows: 2)
      |> Surface.write("abcdEFGHI")

    virtual_text = Surface.virtual_text(surface)

    assert Surface.line_count(surface) == 3
    assert virtual_text.line_count_fn.(4) == 3

    assert [
             [{"abcd", %{}}],
             [{"EFGH", %{}}],
             [{"I   ", %{}}]
           ] = virtual_text.slice_fn.(0, 3, 4)
  end

  test "scrollback can be capped" do
    surface =
      Surface.new(cols: 8, rows: 1, scrollback_limit: 2)
      |> Surface.write("one\r\ntwo\r\nthree\r\nfour")

    virtual_text = Surface.virtual_text(surface)

    assert Surface.scrollback_rows(surface) == 2
    assert Surface.line_count(surface) == 3

    assert [
             [{"two     ", %{}}],
             [{"three   ", %{}}],
             [{"four    ", %{}}]
           ] = virtual_text.slice_fn.(0, 3, 8)
  end

  test "virtual text clips rows to the requested viewport width" do
    surface =
      Surface.new(cols: 6, rows: 1)
      |> Surface.write("abcdef")

    virtual_text = Surface.virtual_text(surface)

    assert [[{"abcd", %{}}]] = virtual_text.slice_fn.(0, 1, 4)
  end

  test "wide glyph continuations do not render as extra spaces" do
    surface =
      Surface.new(cols: 4, rows: 1)
      |> Surface.write("🍏a")

    assert Surface.lines(surface) == ["🍏a "]
    assert [[{"🍏a ", %{}}]] = Surface.virtual_text(surface).slice_fn.(0, 1, 4)
  end

  test "applies SGR styling to rendered segments" do
    surface =
      Surface.new(cols: 8, rows: 1)
      |> Surface.write("a\e[31;1mb\e[0mc")

    assert [
             {"a", %{}},
             {"b", %{bold: true, foreground_color: 1}},
             {"c     ", %{}}
           ] = Surface.slice(surface, 0, 1) |> hd()
  end

  test "buffers incomplete escape sequences across writes" do
    surface =
      Surface.new(cols: 4, rows: 1)
      |> Surface.write("\e[31")
      |> Surface.write("mR")

    assert [{"R", %{foreground_color: 1}}, {"   ", %{}}] = Surface.slice(surface, 0, 1) |> hd()
  end

  test "supports cursor movement and clearing" do
    surface =
      Surface.new(cols: 6, rows: 2)
      |> Surface.write("hello")
      |> Surface.write("\e[1;1HYo")
      |> Surface.write("\e[2J\e[1;1Hx")

    assert Surface.lines(surface) == ["x     ", "      "]
  end

  test "supports alternate screen restore" do
    surface =
      Surface.new(cols: 6, rows: 2)
      |> Surface.write("main")
      |> Surface.write("\e[?1049h")
      |> Surface.write("alt")

    assert Surface.lines(surface) == ["alt   ", "      "]
    assert surface.alt_screen? == true

    surface = Surface.write(surface, "\e[?1049l")

    assert Surface.lines(surface) == ["main  ", "      "]
    assert surface.alt_screen? == false
  end

  test "supports common erase variants" do
    surface =
      Surface.new(cols: 6, rows: 2)
      |> Surface.write("abcdef")
      |> Surface.write("\e[1;4H\e[1K")

    assert Surface.lines(surface) == ["    ef", "      "]

    surface =
      surface
      |> Surface.write("\e[2;1H123456")
      |> Surface.write("\e[2;4H\e[1J")

    assert Surface.lines(surface) == ["      ", "    56"]
  end

  test "resizes the visible screen buffer" do
    surface =
      Surface.new(cols: 4, rows: 2)
      |> Surface.write("abcde")
      |> Surface.resize(6, 3)

    assert surface.cols == 6
    assert surface.rows == 3
    assert Surface.lines(surface) == ["abcd  ", "e     ", "      "]
  end

  test "encodes key events as terminal input bytes" do
    assert Surface.input(%{"key" => "a"}) == "a"
    assert Surface.input(%{"ctrlKey" => true, "key" => "c"}) == <<3>>
    assert Surface.input(%{"ctrlKey" => true, "key" => "Backspace"}) == "\x7f"
    assert Surface.input(%{"key" => "\x7f"}) == "\x7f"
    assert Surface.input(%{"key" => "ArrowUp"}) == "\e[A"
    assert Surface.input(%{"key" => "\t"}) == "\t"
    assert Surface.input("ShiftTab") == "\e[Z"
    assert Surface.input(%{"altKey" => true, "key" => "x"}) == "\ex"
  end
end

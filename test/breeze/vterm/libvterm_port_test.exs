defmodule Breeze.VTerm.LibvtermPortTest do
  use ExUnit.Case, async: true
  alias Breeze.VTerm.Surface

  # The same streams are also compared cell-by-cell with the C reference by
  # bench/libvterm_benchmark.exs. Normal tests need no C toolchain or dependency.
  {cases, _} = Code.eval_file("../../fixtures/libvterm_cases.txt", __DIR__)

  for {name, cols, rows, bytes} <- cases do
    @bytes bytes
    @cols cols
    @rows rows
    test "#{name} is independent of write boundaries" do
      initial = Surface.new(cols: @cols, rows: @rows)
      expected = Surface.write(initial, @bytes)

      for split <- 0..byte_size(@bytes) do
        actual =
          initial
          |> Surface.write(binary_part(@bytes, 0, split))
          |> Surface.write(binary_part(@bytes, split, byte_size(@bytes) - split))

        assert comparable(actual) == comparable(expected)
      end

      actual = Enum.reduce(:binary.bin_to_list(@bytes), initial, &Surface.write(&2, <<&1>>))
      assert comparable(actual) == comparable(expected)
    end
  end

  test "right edge is a physical cursor position with delayed wrapping" do
    surface = Surface.new(cols: 4, rows: 2) |> Surface.write("abcd")
    assert surface.cursor == %{row: 0, col: 3}
    assert surface.wrap_pending?
    assert Surface.lines(Surface.write(surface, "X")) == ["abcd", "X   "]
    assert Surface.lines(Surface.write(surface, "\bX")) == ["abXd", "    "]
    assert Surface.lines(Surface.write(surface, "\e[DX")) == ["abXd", "    "]
    assert Surface.lines(Surface.write(surface, "\e[4GX")) == ["abcX", "    "]
  end

  test "disabled autowrap replaces the last cell without scrolling" do
    surface = Surface.new(cols: 4, rows: 2) |> Surface.write("\e[?7labcdef")
    assert Surface.lines(surface) == ["abcf", "    "]
    assert surface.cursor == %{row: 0, col: 3}
    refute surface.wrap_pending?
    assert Surface.lines(Surface.write(surface, "\e[?7hXY")) == ["abcX", "Y   "]
  end

  test "restoring an unchanged cursor preserves delayed wrapping" do
    for {save, restore} <- [{"\e7", "\e8"}, {"\e[s", "\e[u"}, {"\e[?1048h", "\e[?1048l"}] do
      surface = Surface.new(cols: 4, rows: 2) |> Surface.write("abcd" <> save <> restore)

      assert surface.wrap_pending?
      assert surface.cursor == %{row: 0, col: 3}
      assert Surface.lines(Surface.write(surface, "X")) == ["abcd", "X   "]

      moved = Surface.write(surface, "\r\e[4G" <> restore)
      refute moved.wrap_pending?
      assert Surface.lines(Surface.write(moved, "X")) == ["abcX", "    "]

      moved = Surface.new(cols: 4, rows: 2) |> Surface.write("ab" <> save <> "cd" <> restore)
      refute moved.wrap_pending?
      assert Surface.lines(Surface.write(moved, "X")) == ["abXd", "    "]
    end
  end

  test "tab moves over existing content and stops at the edge" do
    surface = Surface.new(cols: 12, rows: 2) |> Surface.write("abcdefghijkl\r\tX\tY")
    assert Surface.lines(surface) == ["abcdefghXjkY", "            "]
  end

  test "tab stops can be set and cleared and new columns get default stops" do
    surface =
      Surface.new(cols: 12, rows: 2)
      |> Surface.write("\e[3g\e[5G\eH\r\tX")

    assert surface.cursor.col == 5
    surface = surface |> Surface.resize(24, 2) |> Surface.write("\r\tA\tB")
    assert surface.cursor.col == 17
    assert Enum.at(hd(surface.screen), 4).text == "A"
    assert Enum.at(hd(surface.screen), 16).text == "B"
    surface = Surface.write(surface, "\e[5G\e[g\r\t")
    assert surface.cursor.col == 16
    assert Surface.write(surface, "\e[999Z").cursor.col == 0
  end

  test "origin mode makes addressing relative to and bounded by the margins" do
    surface = Surface.new(cols: 8, rows: 6) |> Surface.write("\e[2;5r\e[?6h")
    assert surface.cursor == %{row: 1, col: 0}
    assert Surface.write(surface, "\e[2;3H").cursor == %{row: 2, col: 2}
    assert Surface.write(surface, "\e[999B").cursor.row == 4
    assert Surface.write(surface, "\e[999A").cursor.row == 1
    assert Surface.write(surface, "\e[?6l").cursor == %{row: 0, col: 0}
  end

  test "erasing retains current colors and resets character attributes" do
    surface =
      Surface.new(cols: 6, rows: 2)
      |> Surface.write("abcdef\e[3G\e[31;44;1;3;7m\e[2X")

    assert Surface.lines(surface) == ["ab  ef", "      "]
    assert surface.cursor == %{row: 0, col: 2}

    for col <- [2, 3] do
      assert Enum.at(hd(surface.screen), col).style == %{foreground_color: 1, background_color: 4}
    end

    assert Surface.write(surface, "\e[9J").screen == surface.screen
    assert Surface.write(surface, "\e[9K").screen == surface.screen
  end

  test "inserting and deleting lines preserve the cursor column" do
    surface = Surface.new(cols: 8, rows: 4) |> Surface.write("one\r\ntwo\r\nthree\e[2;3H")
    assert Surface.write(surface, "\e[L").cursor == surface.cursor
    assert Surface.write(surface, "\e[M").cursor == surface.cursor
  end

  test "save and restore include pen and cursor visibility" do
    surface =
      Surface.new(cols: 8, rows: 3)
      |> Surface.write("\e[31mAB\e7\e[?25l\e[32m\e[2;3HX\e8Y")

    assert surface.cursor_visible?
    assert Surface.slice(surface, 0, 1) == [[{"ABY", %{foreground_color: 1}}, {"     ", %{}}]]
  end

  test "application cursor keys use SS3 through the stateful input API" do
    surface = Surface.new() |> Surface.write("\e[?1h")
    assert Surface.input(surface, %{"key" => "ArrowUp"}) == "\eOA"
    assert Surface.input(surface, "Home") == "\eOH"
    assert Surface.input(surface, "End") == "\eOF"
    assert Surface.input(surface, "a") == "a"
    assert Surface.input(surface, %{"ctrlKey" => true, "key" => "c"}) == <<3>>
    assert Surface.input(Surface.write(surface, "\e[?1l"), "ArrowUp") == "\e[A"
    assert Breeze.VTerm.input(surface, "ArrowDown") == "\eOB"
  end

  test "reset clears screen and terminal modes while preserving surface identity" do
    surface =
      Surface.new(cols: 8, rows: 3)
      |> Surface.write("abc\e[31m\e[?1;6;25h\e[?7l\e[3g")

    reset = Surface.write(surface, "\ec")
    assert reset.id == surface.id
    assert reset.autowrap?
    refute reset.origin_mode?
    refute reset.application_cursor?
    assert reset.style == %{}
    assert reset.cursor == %{row: 0, col: 0}
    assert Surface.lines(reset) == List.duplicate("        ", 3)
  end

  test "private and intermediate CSI sequences cannot be misinterpreted as plain commands" do
    surface = Surface.new(cols: 8, rows: 3) |> Surface.write("\e[31mabc")

    for sequence <- ["\e[?0m", "\e[>2J", "\e[1;1;2;2;7$r", "\e[?1H", "\e[4$p"] do
      result = Surface.write(surface, sequence)
      assert result.screen == surface.screen
      assert result.cursor == surface.cursor
      assert result.style == surface.style
    end
  end

  test "unsupported string payloads stay bounded and never become text" do
    for prefix <- ["\e]", "\ePq", "\e_", "\e^", "\eX"] do
      surface = Surface.new(cols: 8, rows: 2) |> Surface.write(prefix)

      surface =
        Enum.reduce(1..8, surface, fn _, s ->
          s = Surface.write(s, String.duplicate("x", 8192))
          assert s.buffer == ""
          assert is_atom(s.parser_state)
          s
        end)

      assert Surface.lines(surface |> Surface.write("\e") |> Surface.write("\\ok")) == [
               "ok      ",
               "        "
             ]

      assert Surface.lines(Surface.write(surface, "\x18ok")) == ["ok      ", "        "]
    end
  end

  test "C0 controls inside a CSI execute while preserving its parameters" do
    surface = Surface.new(cols: 8, rows: 4) |> Surface.write("\e[3\n;4HX")
    assert surface.cursor == %{row: 2, col: 4}
    assert Enum.at(Surface.lines(surface), 2) == "   X    "
  end

  test "colon RGB supports an omitted color-space field" do
    # Intentional improvement over libvterm 0.3.3, which misreads the empty field.
    surface = Surface.new(cols: 8, rows: 1) |> Surface.write("\e[38:2::12:34:56mX")
    assert hd(hd(surface.screen)).style == %{foreground_color: {12, 34, 56}}
  end

  test "overlong escape intermediates and malformed CSI data are discarded" do
    for prefix <- ["\e" <> String.duplicate(" ", 1024), "\e[31$2"] do
      surface = Surface.new(cols: 8, rows: 1) |> Surface.write("\e[32m")
      result = surface |> Surface.write(prefix) |> Surface.write("mX")
      assert Surface.lines(result) == ["X       "]
      assert hd(hd(result.screen)).style == %{foreground_color: 2}
      assert result.buffer == ""
    end
  end

  test "controls interrupt an incomplete UTF-8 character" do
    for sequence <- ["\e]ignored\a", "\x18", "\x1a", "\r"] do
      surface =
        Surface.new(cols: 8, rows: 1)
        |> Surface.write(<<0xC2>>)
        |> Surface.write(sequence <> <<0xA3>> <> "X")

      assert Surface.lines(surface) == ["X       "]
    end
  end

  defp comparable(surface), do: surface |> Map.from_struct() |> Map.drop([:id, :version])
end

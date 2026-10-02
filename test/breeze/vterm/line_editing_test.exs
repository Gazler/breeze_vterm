defmodule Breeze.VTerm.LineEditingTest do
  use ExUnit.Case, async: true
  alias Breeze.VTerm.Surface

  test "Delete is encoded forwards and DCH shifts the rest of the line left" do
    assert Surface.input(%{"key" => "Delete"}) == "\e[3~"
    surface = Surface.new(cols: 10, rows: 1) |> Surface.write("abcdef\e[3D\e[P")
    assert Surface.lines(surface) == ["abcef     "]
    assert surface.cursor == %{row: 0, col: 3}
  end

  test "readline insertion shifts text instead of overwriting after moving left" do
    for insert <- ["\e[@X", "\e[1@X", "\e[0@X", "\e[4hX\e[4l"] do
      surface = Surface.new(cols: 10, rows: 1) |> Surface.write("abcd\e[2D" <> insert)
      assert Surface.lines(surface) == ["abXcd     "]
      assert surface.cursor == %{row: 0, col: 3}
    end
  end

  test "insert mode handles batched ASCII and Unicode and returns to replacement mode" do
    surface =
      Surface.new(cols: 12, rows: 1)
      |> Surface.write("abcd\e[2D\e[4hXYé\e[4lZ")

    assert Surface.lines(surface) == ["abXYéZd     "]
  end

  test "editing commands preserve styles, clamp counts and leave other rows alone" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("\e[31mabcdef\e[4D\e[2@")
    assert Surface.lines(surface) == ["ab  cdef", "        "]
    assert Enum.at(hd(surface.screen), 4).style == %{foreground_color: 1}
    assert Enum.at(hd(surface.screen), 2).style == %{foreground_color: 1}
    surface = Surface.write(surface, "\e[999P")
    assert Surface.lines(surface) == ["ab      ", "        "]
    assert surface.cursor == %{row: 0, col: 2}
  end

  test "wide characters shift as cells and clipped halves become blanks" do
    for {input, expected} <- [
          {"ab界cd\e[5D\e[@X", "aXb界c"},
          {"abcd界\e[5D\e[@X", "aXbcd "},
          {"a界bcd\e[5D\e[P", "a bcd "},
          {"a界bcd\e[4D\e[@X", "a X bc"}
        ] do
      surface = Surface.new(cols: 6, rows: 1) |> Surface.write(input)
      assert Surface.lines(surface) == [expected]
      assert length(hd(surface.screen)) == 6
    end
  end

  test "normal output still replaces cells unless insert mode is requested" do
    surface = Surface.new(cols: 6, rows: 1) |> Surface.write("abcd\e[2DX")
    assert Surface.lines(surface) == ["abXd  "]
  end

  test "split control sequences behave the same as complete shell output" do
    bytes = "abcd\e[2D\e[4hXY\e[4l\e[P"
    expected = Surface.new(cols: 10, rows: 1) |> Surface.write(bytes)
    assert Surface.lines(expected) == ["abXYd     "]

    for split <- 0..byte_size(bytes) do
      first = binary_part(bytes, 0, split)
      rest = binary_part(bytes, split, byte_size(bytes) - split)
      actual = Surface.new(cols: 10, rows: 1) |> Surface.write(first) |> Surface.write(rest)
      assert actual.screen == expected.screen
      assert actual.cursor == expected.cursor
    end
  end
end

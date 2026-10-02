defmodule Breeze.VTerm.ScrollRegionTest do
  use ExUnit.Case, async: true
  alias Breeze.VTerm.Surface

  defp screen do
    Surface.new(cols: 8, rows: 5)
    |> Surface.write("HEAD\r\n30\r\n31\r\n32\r\nSTATUS")
  end

  defp lines(surface), do: Enum.map(Surface.lines(surface), &String.trim_trailing/1)

  test "reverse index scrolls the Vim text region down before painting newly exposed rows" do
    surface = screen() |> Surface.write("\e[2;4r\e[2;1H\eM29")
    assert lines(surface) == ["HEAD", "29", "30", "31", "STATUS"]
    surface = Surface.write(surface, "\e[2;1H\eM28")
    assert lines(surface) == ["HEAD", "28", "29", "30", "STATUS"]
    assert surface.scrollback_count == 0
  end

  test "Vim's insert-line sequence preserves consecutive rows after paging down" do
    surface = Surface.new(cols: 100, rows: 33)

    surface =
      Enum.reduce(Enum.with_index(30..60, 1), surface, fn {n, row}, acc ->
        Surface.write(acc, "\e[#{row};1H#{n}")
      end)

    surface = Surface.write(surface, "\e[32;1HSTATUS\e[33;1HCOMMAND")

    Enum.reduce([29, 28, 27], surface, fn number, acc ->
      # Captured from Neovim: set text margins, insert a row, reset margins,
      # then paint only the newly exposed line.
      bytes = "\e[1;31r\e[H\e[L\e[r\e[H#{number}\e[K"

      updated =
        Enum.reduce(:binary.bin_to_list(bytes), acc, fn byte, s -> Surface.write(s, <<byte>>) end)

      assert Enum.take(lines(updated), 31) == Enum.map(number..(number + 30), &to_string/1)
      assert Enum.drop(lines(updated), 31) == ["STATUS", "COMMAND"]
      updated
    end)
  end

  test "index, next line and linefeed scroll only at the bottom margin" do
    for sequence <- ["\n", "\eD", "\eE"] do
      surface = screen() |> Surface.write("\e[2;4r\e[4;1H" <> sequence <> "33")
      assert lines(surface) == ["HEAD", "31", "32", "33", "STATUS"]
      assert surface.scrollback_count == 0
    end
  end

  test "insert/delete lines operate between cursor and bottom margin" do
    surface = screen() |> Surface.write("\e[2;4r\e[3;1H\e[LNEW")
    assert lines(surface) == ["HEAD", "30", "NEW", "31", "STATUS"]
    surface = Surface.write(surface, "\e[3;1H\e[M")
    assert lines(surface) == ["HEAD", "30", "31", "", "STATUS"]
    assert surface.cursor == %{row: 2, col: 0}
    assert surface.scrollback_count == 0
  end

  test "explicit scrolls clamp to region height and preserve cursor and fixed rows" do
    for {sequence, expected} <- [
          {"\e[S", ["HEAD", "31", "32", "", "STATUS"]},
          {"\e[T", ["HEAD", "", "30", "31", "STATUS"]},
          {"\e[999S", ["HEAD", "", "", "", "STATUS"]}
        ] do
      surface = screen() |> Surface.write("\e[2;4r\e[3;3H" <> sequence)
      assert lines(surface) == expected
      assert surface.cursor == %{row: 2, col: 2}
      assert surface.scrollback_count == 0
    end
  end

  test "invalid margins and line edits outside the region are ignored" do
    surface = screen() |> Surface.write("\e[2;4r\e[5;3H")

    for bytes <- ["\e[L", "\e[M", "\e[4;2r", "\e[2;9r", "\e[3;3r"] do
      updated = Surface.write(surface, bytes)
      assert updated.screen == surface.screen
      assert updated.cursor == surface.cursor
    end
  end

  test "resetting margins restores full-screen scrolling and homes the cursor" do
    surface = screen() |> Surface.write("\e[2;4r\e[r")
    assert surface.cursor == %{row: 0, col: 0}
    surface = Surface.write(surface, "\e[5;1H\n")
    assert lines(surface) == ["30", "31", "32", "STATUS", ""]
    assert surface.scrollback_count == 1
  end

  test "alternate-screen scrolling never accumulates shell scrollback" do
    surface = screen() |> Surface.write("\e[?1049h\e[5;1H\n\e[3S")
    assert surface.scrollback_count == 0
    surface = Surface.write(surface, "\e[?1049l")
    assert lines(surface) == lines(screen())
  end

  test "resize resets margins and split reverse-index input is buffered" do
    surface = screen() |> Surface.write("\e[2;4r") |> Surface.resize(8, 6)
    surface = Surface.write(surface, "\e[1;1H\e") |> Surface.write("MNEW")
    assert lines(surface) == ["NEW", "HEAD", "30", "31", "32", "STATUS"]
  end
end

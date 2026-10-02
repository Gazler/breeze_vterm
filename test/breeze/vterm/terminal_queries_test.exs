defmodule Breeze.VTerm.TerminalQueriesTest do
  use ExUnit.Case, async: true

  alias Breeze.VTerm
  alias Breeze.VTerm.Surface

  test "answers foreground and background queries with the configured default colors" do
    surface =
      VTerm.new(
        cols: 8,
        rows: 1,
        foreground_color: {255, 128, 1},
        background_color: {30, 30, 46},
        on_reply: &send(self(), {:reply, &1})
      )
      |> VTerm.write("a\e[31;44m\e]10;?\a\e]11;?\e\\b")

    assert_receive {:reply, "\e]10;rgb:ffff/8080/0101\a"}
    assert_receive {:reply, "\e]11;rgb:1e1e/1e1e/2e2e\e\\"}
    refute_receive {:reply, _}, 0
    assert Surface.lines(surface) == ["ab      "]
    assert surface.cursor == %{row: 0, col: 2}
    assert surface.style == %{foreground_color: 1, background_color: 4}
  end

  test "queries survive every split, including split string terminators" do
    for code <- [10, 11], terminator <- ["\a", "\e\\"] do
      query = "\e]#{code};?#{terminator}"
      color = if code == 10, do: "e5e5/e5e5/e5e5", else: "0000/0000/0000"
      expected = "\e]#{code};rgb:#{color}#{terminator}"

      for split <- 1..(byte_size(query) - 1) do
        prefix = binary_part(query, 0, split)
        suffix = binary_part(query, split, byte_size(query) - split)

        surface =
          VTerm.new(cols: 8, rows: 1, on_reply: &send(self(), {:reply, &1}))
          |> VTerm.write(prefix)

        refute_receive {:reply, _}, 0
        surface = VTerm.write(surface, suffix <> "ok")
        assert_receive {:reply, ^expected}
        refute_receive {:reply, _}, 0
        assert surface.parser_state == :ground
        assert surface.buffer == ""
        assert Surface.lines(surface) == ["ok      "]
      end
    end
  end

  test "bytewise queries reply once each in stream order and never replay on later writes" do
    surface = VTerm.new(on_reply: &send(self(), {:reply, &1}))

    surface =
      for <<byte <- "\e]11;?\a\e]10;?\e\\\e]11;?\a">>, reduce: surface do
        surface -> VTerm.write(surface, <<byte>>)
      end

    for expected <- [
          "\e]11;rgb:0000/0000/0000\a",
          "\e]10;rgb:e5e5/e5e5/e5e5\e\\",
          "\e]11;rgb:0000/0000/0000\a"
        ] do
      assert_receive {:reply, reply}
      assert reply == expected
    end

    surface |> VTerm.write("") |> VTerm.write("hello") |> VTerm.resize(20, 5)
    refute_receive {:reply, _}, 0
  end

  test "cancellation and malformed or unsupported OSCs produce no replies" do
    surface = VTerm.new(cols: 8, rows: 1, on_reply: &send(self(), {:reply, &1}))

    for sequence <- [
          "\e]10;?" <> <<24>>,
          "\e]11;?" <> <<26>>,
          "\e]11;?\e" <> <<24>>,
          "\e]11;?\eX\a",
          "\e]11;?x\a",
          "\e]11;\a",
          "\e]11;rgb:ffff/ffff/ffff\a",
          "\e]0;title\a",
          "\e]12;?\e\\",
          "\e]52;c;?\a"
        ] do
      result = VTerm.write(surface, sequence <> "ok\e]11;?\a")
      assert Surface.lines(result) == ["ok      "]
      assert_receive {:reply, "\e]11;rgb:0000/0000/0000\a"}
      refute_receive {:reply, _}, 0
    end
  end

  test "an overlong OSC starting like a query is discarded without retaining its payload" do
    surface =
      VTerm.new(cols: 8, rows: 1, on_reply: &send(self(), {:reply, &1}))
      |> VTerm.write("\e]11;?")

    surface =
      Enum.reduce(1..64, surface, fn _, acc ->
        next = VTerm.write(acc, String.duplicate("x", 4096))
        assert next.parser_state == :osc
        assert next.buffer == ""
        next
      end)

    surface = surface |> VTerm.write("\e") |> VTerm.write("\\ok")
    assert Surface.lines(surface) == ["ok      "]
    refute_receive {:reply, _}, 0
  end

  test "queries remain silent without a callback" do
    surface = VTerm.new(cols: 8, rows: 1) |> VTerm.write("\e]10;?\a\e]11;?\e\\\e[6nok")
    assert surface.on_reply == nil
    assert surface.parser_state == :ground
    assert Surface.lines(surface) == ["ok      "]
  end

  test "answers gh's color and cursor position queries in order across chunks" do
    surface =
      VTerm.new(cols: 8, rows: 3, on_reply: &send(self(), {:reply, &1}))
      |> VTerm.write("\e[2;3H\e]11;?\e\\\e[6")

    assert_receive {:reply, "\e]11;rgb:0000/0000/0000\e\\"}
    refute_receive {:reply, _}, 0
    surface = VTerm.write(surface, "n\e[1;1H")
    assert_receive {:reply, "\e[2;3R"}
    refute_receive {:reply, _}, 0
    assert surface.cursor == %{row: 0, col: 0}
  end

  test "cursor reports stay within the screen at the wrap boundary and after resizing" do
    surface =
      VTerm.new(cols: 4, rows: 2, on_reply: &send(self(), {:reply, &1}))
      |> VTerm.write("abcd\e[6n")

    assert_receive {:reply, "\e[1;4R"}
    surface = VTerm.write(surface, "e\e[6n")
    assert_receive {:reply, "\e[2;2R"}
    surface = surface |> VTerm.resize(2, 1) |> VTerm.write("\e[6n")
    assert_receive {:reply, "\e[1;2R"}

    surface = VTerm.write(surface, "\e[?1049h\e[6n\e[?1049l\e[6n")
    assert_receive {:reply, "\e[1;1R"}
    assert_receive {:reply, "\e[1;2R"}
    assert surface.cursor == %{row: 0, col: 1}
  end

  test "rejects invalid reply callbacks and query colors at construction" do
    assert_raise ArgumentError, ~r/:on_reply/, fn -> VTerm.new(on_reply: :invalid) end

    for key <- [:foreground_color, :background_color],
        value <- [nil, 7, "#ffffff", {256, 0, 0}, {0, -1, 0}, {0, 0, 1.5}] do
      assert_raise ArgumentError, ~r/RGB tuple/, fn -> VTerm.new([{key, value}]) end
    end
  end
end

defmodule Breeze.VTerm.SelectionTest do
  use ExUnit.Case, async: true
  alias Breeze.VTerm.{Surface, Selection}

  test "copies forward and backward ranges without styles or row padding" do
    surface = Surface.new(cols: 8, rows: 3) |> Surface.write("\e[31mhello\r\nworld")
    assert Selection.text(surface, {0, 1}, {1, 2}) == "ello\nwor"
    assert Selection.text(surface, {1, 2}, {0, 1}) == "ello\nwor"
  end

  test "selecting either cell of a wide character copies the whole grapheme" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("a界éz")
    assert Selection.text(surface, {0, 2}, {0, 2}) == "界"
    assert Selection.text(surface, {0, 1}, {0, 3}) == "界é"
  end

  test "selection can read scrollback and clamps out of range coordinates" do
    surface = Surface.new(cols: 6, rows: 2) |> Surface.write("one\r\ntwo\r\nthree")
    assert Selection.text(surface, {-2, -4}, {99, 99}) == "one\ntwo\nthree"
  end

  test "mouse selection reaches all visible buffer rows in a pane taller than the screen" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("one\r\ntwo\r\nthree\r\nfour")

    for height <- [4, 6], row <- [3, 99] do
      {:ok, state, _} = init_selectable(surface)

      event = %{
        "mouse" => %{"button" => "left", "action" => "press"},
        "row" => row,
        "col" => 0,
        "element" => %{width: 8, height: height, content_height: 4}
      }

      {{:change, %{selection: :start}}, state, capture_mouse: true} =
        Breeze.VTerm.Implicit.handle_event(nil, event, state)

      assert state.selection.anchor == {3, 0}
      release = event |> put_in(["mouse", "action"], "release") |> Map.put("col", 3)

      {:noreply, state, capture_mouse: false} =
        Breeze.VTerm.Implicit.handle_event(nil, release, state)

      assert state.selection.head == {3, 3}

      assert {{:change, %{copy: "four"}}, _} =
               Breeze.VTerm.Implicit.handle_event(
                 nil,
                 %{"mouse" => %{"button" => "right", "action" => "press"}},
                 state
               )
    end
  end

  test "selection scrolling starts at the visible buffer edge in a tall pane" do
    surface =
      Surface.new(cols: 8, rows: 2)
      |> Surface.write("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")

    {:ok, state, _} = init_selectable(surface, %{offset_y: 0, pinned_bottom: false})

    event = %{
      "mouse" => %{"button" => "left", "action" => "press"},
      "row" => 0,
      "col" => 0,
      "element" => %{width: 8, height: 4, content_height: 6}
    }

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(nil, event, state)

    drag = event |> put_in(["mouse", "action"], "move") |> Map.put("col", 3)

    Enum.reduce([{1, 0, 1}, {2, 0, 2}, {3, 1, 4}, {99, 2, 5}, {99, 2, 5}], state, fn
      {row, offset, head_row}, state ->
        {:noreply, state, consumed: true} =
          Breeze.VTerm.Implicit.handle_event(nil, Map.put(drag, "row", row), state)

        assert state.offset_y == offset
        assert state.selection.head == {head_row, 3}
        assert state.selection.anchor == {0, 0}
        state
    end)
  end

  test "equal-version surface branches invalidate selection before copying" do
    initial = Surface.new(cols: 8, rows: 2)
    surface = Surface.write(initial, "abc")
    replacement = Surface.write(initial, "xyz")
    assert surface.id == replacement.id
    assert surface.version == replacement.version
    {:ok, state, _} = init_selectable(surface)

    event = %{
      "mouse" => %{"button" => "left", "action" => "press"},
      "row" => 0,
      "col" => 0,
      "element" => %{width: 8, height: 2}
    }

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(nil, event, state)

    release = event |> put_in(["mouse", "action"], "release") |> Map.put("col", 2)

    {:noreply, state, capture_mouse: false} =
      Breeze.VTerm.Implicit.handle_event(nil, release, state)

    copy = %{"mouse" => %{"button" => "right", "action" => "press"}}
    assert {{:change, %{copy: "abc"}}, _} = Breeze.VTerm.Implicit.handle_event(nil, copy, state)

    {:ok, preserved, _} = init_selectable(surface, state)
    assert preserved.selection == state.selection

    {:ok, replaced, _} = init_selectable(replacement, state)
    assert replaced.selection == nil

    assert {:noreply, ^replaced, capture_mouse: false} =
             Breeze.VTerm.Implicit.handle_event(nil, copy, replaced)
  end

  test "highlighting clips to the viewport and output invalidates the selection" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("abcdefgh\r\nijklmnop")
    {:ok, state, _} = init_selectable(surface)

    state =
      Map.put(state, :selection, %{
        anchor: {0, 0},
        head: {1, 7},
        moved?: true,
        dragging?: false,
        width: 8
      })

    box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}

    {:ok, _, overlays: overlays} =
      Breeze.VTerm.Implicit.animate(:root, box, [], state, %{
        layout: %{left: 10, top: 5, width: 4, height: 1},
        now: 0
      })

    for overlay <- overlays, overlay.visible? do
      assert overlay.x >= 10

      assert overlay.x +
               BackBreeze.Utils.string_length(Map.get(overlay, :content, Map.get(overlay, :char))) <=
               14

      assert overlay.y == 5
    end

    {:ok, updated, _} =
      init_selectable(Surface.write(surface, "!"), state)

    assert updated.selection == nil
  end

  test "selection inverses text and internal spaces without trailing padding" do
    surface = Surface.new(cols: 12, rows: 1) |> Surface.write("\e[31mab c界  ")
    {:ok, state, _} = init_selectable(surface)

    state =
      Map.put(state, :selection, %{
        anchor: {0, 0},
        head: {0, 11},
        moved?: true,
        dragging?: false,
        width: 12
      })

    box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}

    {:ok, _, overlays: overlays} =
      Breeze.VTerm.Implicit.animate(:root, box, [], state, %{
        layout: %{left: 0, top: 0, width: 12, height: 1},
        now: 0
      })

    highlights = Enum.filter(overlays, & &1.visible?)

    assert Enum.map(
             highlights,
             &{&1.x,
              BackBreeze.Utils.strip_escape_chars(Map.get(&1, :content, Map.get(&1, :char)))}
           ) == [{0, "ab c界"}]

    for highlight <- highlights do
      assert highlight.content =~ "38;5;1"
      assert highlight.content =~ ~r/\e\[[0-9;]*\b7[;m]/
      refute Map.has_key?(highlight, :background_color)
    end

    assert Selection.text(surface, {0, 0}, {0, 11}) == "ab c界"
  end

  test "selected spaces before later text are highlighted but blank lines are not" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("a  b")
    assert Selection.highlights(surface, {0, 1}, {0, 2}, 0, 2, 8) == [{0, 1, "  ", %{}}]
    assert Selection.highlights(surface, {1, 0}, {1, 7}, 0, 2, 8) == []
  end

  test "cached highlights distinguish edited branches, bounds, styles and viewport clipping" do
    original = Surface.new(cols: 8, rows: 1)
    red = Surface.write(original, "\e[31ma界bc")
    green = Surface.write(original, "\e[32mx語yz")
    assert {red.id, red.version} == {green.id, green.version}

    for _ <- 1..2 do
      assert Selection.highlights(red, {0, 0}, {0, 7}, 0, 1, 8) ==
               [{0, 0, "a界bc", %{foreground_color: 1}}]

      assert Selection.highlights(green, {0, 0}, {0, 7}, 0, 1, 8) ==
               [{0, 0, "x語yz", %{foreground_color: 2}}]

      assert Selection.highlights(red, {0, 0}, {0, 7}, 0, 1, 2) ==
               [{0, 0, "a ", %{foreground_color: 1}}]

      assert Selection.highlights(red, {0, 2}, {0, 3}, 0, 1, 8) ==
               [{0, 1, "界b", %{foreground_color: 1}}]
    end
  end

  test "coalesced selection overlays preserve styles, wide cells and the final cursor" do
    source =
      "\e[31ma界\e[1;32mbc\e[0;7;34mde\e[0m\r\n" <>
        "\e[3;38;2;1;2;3mx\e[0;44my\e[0mz"

    surface = Surface.new(cols: 10, rows: 2) |> Surface.write(source)
    {:ok, state, _} = init_selectable(surface)
    state = %{state | selection: %{anchor: {0, 0}, head: {1, 9}, moved?: true, width: 10}}
    box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}

    for theme <- [nil, Breeze.Theme.builtin(:gruvbox)] do
      {:ok, _, overlays: overlays} =
        Breeze.VTerm.Implicit.animate(:root, box, [], state, %{
          layout: %{left: 0, top: 0, width: 10, height: 2},
          theme: theme,
          now: 0
        })

      highlights = Enum.filter(overlays, & &1.visible?)
      assert length(highlights) == 4
      assert Enum.map(highlights, &{&1.x, &1.y}) == [{0, 0}, {5, 0}, {0, 1}, {2, 1}]

      painted =
        Surface.new(cols: 10, rows: 2)
        |> Surface.write(Breeze.TerminalOverlay.render_overlays(highlights))

      assert painted.cursor == %{row: 1, col: 2}

      for {original_row, painted_row} <- Enum.zip(surface.screen, painted.screen),
          {original, actual} <- Enum.zip(original_row, painted_row),
          original.text != " " do
        assert actual.text == original.text
        expected_style = Map.merge(Breeze.Theme.default_style(theme), original.style)

        for key <- [:foreground_color, :background_color, :bold, :italic],
            do: assert(Map.get(actual.style, key) == Map.get(expected_style, key))

        assert Map.get(actual.style, :reverse, false) ==
                 not Map.get(original.style, :reverse, false)
      end
    end
  end

  test "coalescing retains cursor positioning around zero-width and complex text" do
    for text <- ["\u0301", "☀️"] do
      surface = Surface.new(cols: 10, rows: 1) |> Surface.write(text <> "\e[31ma\e[32mb\e[34mc")
      {:ok, state, _} = init_selectable(surface)
      state = %{state | selection: %{anchor: {0, 0}, head: {0, 9}, moved?: true, width: 10}}
      box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}

      {:ok, _, overlays: overlays} =
        Breeze.VTerm.Implicit.animate(:root, box, [], state, %{
          layout: %{left: 0, top: 0, width: 10, height: 1},
          now: 0
        })

      assert Enum.map(Enum.filter(overlays, & &1.visible?), & &1.x) == [0, 1, 3]
    end
  end

  test "copy toast is clipped and anchored to the bottom right of the pane" do
    {:ok, state, meta} =
      Breeze.VTerm.Implicit.init(
        [],
        %{:"terminal-copy-notice" => 123, :"cursor-blink" => false},
        %{}
      )

    box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}

    {:ok, _, overlays: overlays} =
      Breeze.VTerm.Implicit.animate(:root, box, [], state, %{
        layout: %{left: 10, top: 5, width: 30, height: 4},
        now: 0
      })

    toast = List.last(overlays)
    assert BackBreeze.Utils.strip_escape_chars(toast.content) == " Copied 123 chars "
    assert toast.x + BackBreeze.Utils.string_length(toast.content) == 40
    assert toast.y == 8
    assert meta[:rerender_every] == :change
  end

  test "disabling selection clears an active drag and releases capture on the next event" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("hello")
    {:ok, state, _} = init_selectable(surface)

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(
        nil,
        %{"mouse" => %{"button" => "left", "action" => "press"}},
        state
      )

    {:ok, preserved, _} = init_selectable(surface, state)
    assert preserved.selection == state.selection

    for attrs <- [%{}, %{:"terminal-selectable" => false}, %{:"terminal-selectable" => "false"}] do
      {:ok, disabled, _} =
        Breeze.VTerm.Implicit.init([], Map.put(attrs, :"terminal-surface", surface), state)

      assert disabled.selection == nil

      assert {:noreply, ^disabled, capture_mouse: false} =
               Breeze.VTerm.Implicit.handle_event(
                 nil,
                 %{"mouse" => %{"button" => "right", "action" => "press"}},
                 disabled
               )
    end
  end

  defmodule View do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(opts, term) do
      {:ok,
       assign(term,
         owner: opts[:owner],
         selectable: Keyword.get(opts, :selectable, false),
         selection_autoscroll: Keyword.get(opts, :selection_autoscroll, false),
         surface:
           Keyword.get(opts, :surface) ||
             Surface.new(cols: 8, rows: 2) |> Surface.write("hello\r\nworld")
       )}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-2 width-20 height-4">
        <box id="other" focusable>sidebar</box>
        <.terminal
          id="terminal"
          surface={@surface}
          selectable={@selectable}
          selection_autoscroll={@selection_autoscroll}
          cursor-blink={false}
          br-change="terminal"
        />
      </box>
      """
    end

    def handle_event("terminal", event, term) do
      send(term.assigns.owner, {:terminal_event, event})
      {:noreply, term}
    end

    def handle_event(_, _, term), do: {:noreply, term}
  end

  test "mouse selection is disabled by default and when explicitly false" do
    for opts <- [[], [selectable: false], [selectable: "false"]] do
      {:ok, pid} = Breeze.ChildServer.start(view: View, start_opts: [owner: self()] ++ opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      %{left: left, top: top} = decoration.layout

      mouse(pid, "press", left, top)
      mouse(pid, "move", left + 3, top)
      mouse(pid, "release", left + 3, top)

      Breeze.ChildServer.dispatch_input(pid, %{
        "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
      })

      {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
      assert implicit.selection == nil
      assert :sys.get_state(pid).mouse_capture == nil
      refute_receive {:terminal_event, _}
    end
  end

  test "opting in enables dragging and right-click copy within the pane" do
    {:ok, pid} =
      Breeze.ChildServer.start(view: View, start_opts: [owner: self(), selectable: true])

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = decoration.layout

    mouse(pid, "press", left + 1, top)
    assert_receive {:terminal_event, %{selection: :start}}
    mouse(pid, "move", left + 3, top)
    mouse(pid, "release", left + 3, top)
    refute_receive {:terminal_event, %{copy: _}}

    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
    })

    assert_receive {:terminal_event, %{copy: "ell"}}
  end

  test "selection overlays update when cursor blinking is disabled" do
    {:ok, pid} =
      Breeze.ChildServer.start(view: View, start_opts: [owner: self(), selectable: true])

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = decoration.layout

    mouse(pid, "press", left + 1, top)
    mouse(pid, "move", left + 3, top)
    mouse(pid, "release", left + 3, top)

    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    assert decoration.every_ms == :change

    {:ok, _, overlays: [cursor, highlight]} =
      Breeze.VTerm.Implicit.animate(:root, decoration.box, [], decoration.state, %{
        layout: decoration.layout,
        now: 0
      })

    refute cursor.visible?
    assert highlight.visible?
    assert BackBreeze.Utils.strip_escape_chars(highlight.content) == "ell"
    assert Breeze.TerminalOverlay.render_overlay(highlight) =~ ~r/\e\[[0-9;]*\b7[;m]/

    Breeze.ChildServer.dispatch_input(pid, "x")
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")

    {:ok, _, overlays: [cursor]} =
      Breeze.VTerm.Implicit.animate(:root, decoration.box, [], decoration.state, %{
        layout: decoration.layout,
        now: 1500
      })

    assert cursor.visible?
  end

  test "compact snapshots retain selection behavior without transferring scrollback" do
    surface =
      Surface.new(cols: 120, rows: 30)
      |> Surface.write(Enum.map_join(1..90, "\r\n", &"\e[31mrow #{&1}\e[0m 界 text"))

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: View,
        start_opts: [owner: self(), selectable: true, surface: surface]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, _, _, [initial]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = initial.layout
    mouse(pid, "press", left + 1, top + 1)
    mouse(pid, "move", left + 3, top)
    mouse(pid, "release", left + 3, top)

    {:ok, full_acc, _, [full]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")

    {:ok, compact_acc, _, [compact]} =
      Breeze.ChildServer.render_snapshot(pid, focused: "terminal", compact_snapshot: true)

    assert Map.has_key?(full_acc, :input_routing_signature)
    refute Map.has_key?(compact_acc, :input_routing_signature)
    refute Enum.any?(compact_acc.elements, fn {_, flags} -> flags[:"terminal-surface"] end)
    refute match?(%Surface{}, compact.state.surface)
    assert :erts_debug.flat_size(compact) < div(:erts_debug.flat_size(full), 10)

    box = %BackBreeze.Box{content: "", style: %BackBreeze.Style{}}
    ctx = %{layout: full.layout, now: 0}

    assert Breeze.VTerm.Implicit.animate(:root, box, [], compact.state, ctx) ==
             Breeze.VTerm.Implicit.animate(:root, box, [], full.state, ctx)

    {_, state} = :sys.get_state(pid).implicit_state["terminal"]
    assert state.surface == surface
    selection = state.selection
    expected = Selection.text(surface, selection.anchor, selection.head, selection.width)

    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
    })

    assert_receive {:terminal_event, %{copy: ^expected}}

    {:ok, inspected_acc, _, [inspected]} =
      Breeze.ChildServer.render_snapshot(pid,
        focused: "terminal",
        compact_snapshot: true,
        render_tree?: true
      )

    assert inspected.state.surface == surface
    assert Map.has_key?(inspected_acc, :input_routing_signature)
  end

  test "dragging at the top scrolls upward and extends the copied selection" do
    surface =
      Surface.new(cols: 8, rows: 4)
      |> Surface.write("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: View,
        start_opts: [owner: self(), selectable: true, surface: surface]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = decoration.layout

    mouse(pid, "press", left + 3, top + 2)
    mouse(pid, "move", left, top + 1)
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.pinned_bottom
    assert implicit.selection.anchor == {4, 3}

    mouse(pid, "move", left, top)
    {:ok, _, box} = Breeze.ChildServer.render(pid, focused: "terminal")
    assert box.content =~ "two"
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.offset_y == 1
    refute implicit.pinned_bottom
    assert implicit.selection.anchor == {4, 3}
    assert implicit.selection.head == {1, 0}

    mouse(pid, "release", left, top)
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.offset_y == 1
    assert :sys.get_state(pid).mouse_capture == nil

    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
    })

    assert_receive {:terminal_event, %{copy: "two\nthree\nfour\nfive"}}
  end

  test "dragging above the top continues scrolling and stops at the start of the buffer" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("one\r\ntwo\r\nthree\r\nfour")
    {:ok, state, _} = init_selectable(surface)

    event = %{
      "mouse" => %{"button" => "left", "action" => "press"},
      "row" => 1,
      "col" => 3,
      "element" => %{width: 8, height: 2, content_height: 4}
    }

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(nil, event, state)

    assert state.selection.anchor == {3, 3}
    drag = event |> put_in(["mouse", "action"], "move") |> Map.put("row", -1) |> Map.put("col", 0)

    state =
      Enum.reduce([1, 0, 0], state, fn offset, state ->
        {:noreply, state, consumed: true} = Breeze.VTerm.Implicit.handle_event(nil, drag, state)
        assert state.offset_y == offset
        assert state.selection.head == {offset, 0}
        assert state.selection.anchor == {3, 3}
        state
      end)

    {:noreply, state, capture_mouse: false} =
      Breeze.VTerm.Implicit.handle_event(nil, put_in(drag, ["mouse", "action"], "release"), state)

    assert {{:change, %{copy: "one\ntwo\nthree\nfour"}}, _} =
             Breeze.VTerm.Implicit.handle_event(
               nil,
               %{"mouse" => %{"button" => "right", "action" => "press"}},
               state
             )
  end

  test "dragging at the bottom scrolls downward and extends the copied selection" do
    surface =
      Surface.new(cols: 8, rows: 4)
      |> Surface.write("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: View,
        start_opts: [owner: self(), selectable: true, surface: surface]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    Breeze.ChildServer.dispatch_input(pid, "PageUp")
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = decoration.layout

    mouse(pid, "press", left, top + 1)
    mouse(pid, "move", left + 3, top + 2)
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.offset_y == 0
    assert implicit.selection.anchor == {1, 0}

    mouse(pid, "move", left + 3, top + 3)
    {:ok, _, box} = Breeze.ChildServer.render(pid, focused: "terminal")
    assert box.content =~ "five"
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.offset_y == 1
    refute implicit.pinned_bottom
    assert implicit.selection.anchor == {1, 0}
    assert implicit.selection.head == {4, 3}

    mouse(pid, "release", left + 3, top + 3)
    {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
    assert implicit.offset_y == 1
    assert :sys.get_state(pid).mouse_capture == nil

    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
    })

    assert_receive {:terminal_event, %{copy: "two\nthree\nfour\nfive"}}
  end

  test "dragging below the bottom continues scrolling and stops at the end of the buffer" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("one\r\ntwo\r\nthree\r\nfour")
    {:ok, state, _} = init_selectable(surface, %{offset_y: 0, pinned_bottom: false})

    event = %{
      "mouse" => %{"button" => "left", "action" => "press"},
      "row" => 0,
      "col" => 0,
      "element" => %{width: 8, height: 2, content_height: 4}
    }

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(nil, event, state)

    assert state.selection.anchor == {0, 0}
    drag = event |> put_in(["mouse", "action"], "move") |> Map.put("row", 2) |> Map.put("col", 3)

    state =
      Enum.reduce([1, 2, 2], state, fn offset, state ->
        {:noreply, state, consumed: true} = Breeze.VTerm.Implicit.handle_event(nil, drag, state)
        assert state.offset_y == offset
        assert state.pinned_bottom == (offset == 2)
        assert state.selection.head == {offset + 1, 3}
        assert state.selection.anchor == {0, 0}
        state
      end)

    {:noreply, state, capture_mouse: false} =
      Breeze.VTerm.Implicit.handle_event(nil, put_in(drag, ["mouse", "action"], "release"), state)

    assert {{:change, %{copy: "one\ntwo\nthree\nfour"}}, _} =
             Breeze.VTerm.Implicit.handle_event(
               nil,
               %{"mouse" => %{"button" => "right", "action" => "press"}},
               state
             )
  end

  test "drag stays with the pane and only right click copies its text" do
    {:ok, pid} =
      Breeze.ChildServer.start(view: View, start_opts: [owner: self(), selectable: true])

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    %{left: left, top: top} = decoration.layout
    mouse(pid, "press", left + 1, top)
    assert :sys.get_state(pid).mouse_capture == "terminal"
    Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    mouse(pid, "move", 0, top + 1)
    assert :sys.get_state(pid).mouse_capture == "terminal"
    mouse(pid, "release", 0, top + 1)
    assert :sys.get_state(pid).mouse_capture == nil
    refute_receive {:terminal_event, %{copy: _}}

    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "right", "action" => "press", "x" => left, "y" => top}
    })

    assert_receive {:terminal_event, %{copy: "ello\nw"}}
    mouse(pid, "press", 0, 0)
    assert :sys.get_state(pid).focused == "other"
  end

  test "clicks, Escape, and typing release mouse capture before the next render" do
    for cancellation <- [:click, "Escape", "\e", "x"] do
      {:ok, pid} =
        Breeze.ChildServer.start(view: View, start_opts: [owner: self(), selectable: true])

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      %{left: left, top: top} = decoration.layout
      mouse(pid, "press", left + 1, top)
      assert :sys.get_state(pid).mouse_capture == "terminal"

      if cancellation == :click do
        mouse(pid, "release", left + 1, top)
      else
        mouse(pid, "move", left + 3, top)
        Breeze.ChildServer.dispatch_input(pid, cancellation)
      end

      state = :sys.get_state(pid)
      assert state.mouse_capture == nil
      {_, implicit} = state.implicit_state["terminal"]
      assert implicit.selection == nil

      mouse(pid, "press", 0, 0)
      assert :sys.get_state(pid).focused == "other"
    end
  end

  test "release ends capture when selection was invalidated during a drag" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("hello\r\nworld")

    for changes <- [
          [selectable: false],
          [surface: Surface.write(surface, "!")],
          [surface: Surface.resize(surface, 7, 2)]
        ] do
      {:ok, pid} =
        Breeze.ChildServer.start(
          view: View,
          start_opts: [owner: self(), selectable: true, surface: surface]
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, _, _, [decoration]} = Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      %{left: left, top: top} = decoration.layout
      mouse(pid, "press", left + 1, top)
      assert :sys.get_state(pid).mouse_capture == "terminal"

      :ok = Breeze.ChildServer.update_assigns(pid, changes)
      Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      {_, implicit} = :sys.get_state(pid).implicit_state["terminal"]
      assert implicit.selection == nil

      mouse(pid, "release", 0, top + 1)
      assert :sys.get_state(pid).mouse_capture == nil
      mouse(pid, "press", 0, 0)
      assert :sys.get_state(pid).focused == "other"
    end
  end

  test "clicks do not copy and typing clears selection" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("hello")
    {:ok, state, _} = init_selectable(surface)

    event = %{
      "mouse" => %{"button" => "left", "action" => "press"},
      "row" => 0,
      "col" => 1,
      "element" => %{width: 8, height: 2}
    }

    {{:change, %{selection: :start}}, state, capture_mouse: true} =
      Breeze.VTerm.Implicit.handle_event(nil, event, state)

    {{:change, %{selection: :clear}}, state, capture_mouse: false} =
      Breeze.VTerm.Implicit.handle_event(
        nil,
        put_in(event, ["mouse", "action"], "release"),
        state
      )

    {{:change, %{input: "x"}}, state, capture_mouse: false} =
      Breeze.VTerm.Implicit.handle_event(nil, %{"key" => "x"}, state)

    assert state.selection == nil
  end

  defp init_selectable(surface, state \\ %{}) do
    Breeze.VTerm.Implicit.init(
      [],
      %{:"terminal-surface" => surface, :"terminal-selectable" => true},
      state
    )
  end

  defp mouse(pid, action, x, y) do
    Breeze.ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => "left", "action" => action, "x" => x, "y" => y}
    })
  end
end

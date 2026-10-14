defmodule Breeze.VTerm.EdgeScrollTest do
  use ExUnit.Case, async: true
  alias Breeze.VTerm.{Implicit, Selection, Surface}

  defmodule View do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(opts, term),
      do:
        {:ok,
         term
         |> assign(surface: opts[:surface], owner: opts[:owner], selectable: true)
         |> focus("terminal")}

    def render(assigns) do
      ~H"""
      <box class="width-full height-full">
        <.terminal
          id="terminal"
          surface={@surface}
          selectable={@selectable}
          selection_autoscroll
          cursor-blink={false}
          br-change="input"
        />
      </box>
      """
    end

    def handle_info({Breeze.VTerm, :edge_scroll, _, _} = message, term),
      do: Breeze.VTerm.handle_info(message, term)

    def handle_info(:unfocus, term), do: {:noreply, focus(term, nil)}

    def handle_event("input", event, term) do
      send(term.assigns.owner, {:input, event})
      {:noreply, term}
    end
  end

  test "holding either edge scrolls without mouse movement and release preserves the full copy" do
    for direction <- [:up, :down] do
      {pid, surface} = start()

      if direction == :down,
        do:
          :sys.replace_state(pid, fn term ->
            {mod, state} = term.implicit_state["terminal"]

            put_in(
              term.implicit_state["terminal"],
              {mod, %{state | offset_y: 0, pinned_bottom: false}}
            )
          end)

      Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      edge_row = if direction == :up, do: 0, else: 5
      mouse(pid, "press", 2, 2)
      mouse(pid, "move", 0, edge_row)
      initial = state(pid)
      assert initial.edge_scroll
      await(fn -> abs(state(pid).offset_y - initial.offset_y) >= 2 end)
      mouse(pid, "release", 0, edge_row)
      released = state(pid)
      assert released.selection.anchor == initial.selection.anchor
      assert released.selection.head == {released.offset_y + edge_row, 0}
      assert released.edge_scroll == nil
      assert :sys.get_state(pid).mouse_capture == nil
      Process.sleep(110)
      assert state(pid).offset_y == released.offset_y

      Breeze.ChildServer.dispatch_input(pid, %{
        "mouse" => %{"button" => "right", "action" => "press", "x" => 0, "y" => edge_row}
      })

      expected =
        Selection.text(
          surface,
          released.selection.anchor,
          released.selection.head,
          released.selection.width
        )

      assert_receive {:input, %{copy: ^expected}}
    end
  end

  test "moving inside, cancellation, blur and new output stop timers and ignore stale ticks" do
    for action <- [:inside, :escape, :typing, :blur, :async_blur, :output, :disable] do
      {pid, surface} = start()
      mouse(pid, "press", 2, 2)
      mouse(pid, "move", 0, 0)
      token = state(pid).edge_scroll.token

      case action do
        :inside ->
          mouse(pid, "move", 0, 2)

        :escape ->
          Breeze.ChildServer.dispatch_input(pid, "Escape")

        :typing ->
          Breeze.ChildServer.dispatch_input(pid, "x")

        :blur ->
          Breeze.ChildServer.set_focus(pid, nil)

        :async_blur ->
          send(pid, :unfocus)

        :output ->
          Breeze.ChildServer.update_assigns(pid, surface: Surface.write(surface, "!"))
          Breeze.ChildServer.render_snapshot(pid, focused: "terminal")

        :disable ->
          Breeze.ChildServer.update_assigns(pid, selectable: false)
          Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
      end

      stopped = state(pid)
      assert stopped.edge_scroll == nil
      send(pid, {Breeze.VTerm, :edge_scroll, "terminal", token})
      Process.sleep(80)
      assert state(pid) == stopped
    end
  end

  test "reinitializing preserves valid timers and cancels invalidated or disabled scrolling" do
    surface = Surface.new(cols: 8, rows: 2) |> Surface.write("hello")

    attrs = %{
      id: "terminal",
      "terminal-surface": surface,
      "terminal-selectable": true,
      "terminal-selection-autoscroll": true
    }

    changes = [
      output: Map.put(attrs, :"terminal-surface", Surface.write(surface, "!")),
      resize: Map.put(attrs, :"terminal-surface", Surface.resize(surface, 10, 3)),
      selection_disabled: Map.put(attrs, :"terminal-selectable", false),
      autoscroll_disabled: Map.put(attrs, :"terminal-selection-autoscroll", false)
    ]

    for {change, changed_attrs} <- changes do
      {:ok, state, _} = Implicit.init([], attrs, %{})
      token = make_ref()
      timer = Process.send_after(self(), {Breeze.VTerm, :edge_scroll, "terminal", token}, 60_000)

      try do
        selection = %{anchor: {0, 0}, head: {0, 2}, moved?: true, dragging?: true, width: 8}
        state = %{state | selection: selection, edge_scroll: %{timer: timer, token: token}}

        {:ok, preserved, _} = Implicit.init([], attrs, state)
        assert preserved.selection == selection
        assert preserved.edge_scroll == state.edge_scroll
        assert is_integer(Process.read_timer(timer))

        {:ok, stopped, _} = Implicit.init([], changed_attrs, preserved)
        assert stopped.selection == if(change == :autoscroll_disabled, do: selection, else: nil)
        assert stopped.edge_scroll == nil
        assert Process.read_timer(timer) == false
        assert Implicit.scroll_tick(token, stopped) == stopped
      after
        Process.cancel_timer(timer)
      end
    end
  end

  test "acceleration is bounded and repeated mouse movement doesn't queue extra scroll steps" do
    {pid, _} = start()
    mouse(pid, "press", 2, 2)
    mouse(pid, "move", 0, 0)
    :sys.suspend(pid)
    frozen = :sys.get_state(pid)
    {_, initial} = frozen.implicit_state["terminal"]
    Process.cancel_timer(initial.edge_scroll.timer)
    :sys.resume(pid)

    # Drive the clock-dependent callback with an old start time, avoiding a
    # long sleep while checking the accelerated movement and retained anchor.
    :sys.replace_state(pid, fn term ->
      {mod, state} = term.implicit_state["terminal"]
      state = put_in(state.edge_scroll.started_at, System.monotonic_time(:millisecond) - 10_000)
      put_in(term.implicit_state["terminal"], {mod, state})
    end)

    for col <- 0..10, do: mouse(pid, "move", col, 0)
    assert state(pid).offset_y == initial.offset_y
    send(pid, {Breeze.VTerm, :edge_scroll, "terminal", initial.edge_scroll.token})
    stepped = state(pid)
    assert stepped.offset_y == initial.offset_y - 3
    assert stepped.selection.anchor == initial.selection.anchor
    assert stepped.selection.head == {stepped.offset_y, 10}
    mouse(pid, "release", 10, 0)
  end

  test "reaching the buffer boundary stops the timer" do
    {pid, _} = start(8)
    mouse(pid, "press", 2, 2)
    mouse(pid, "move", 0, 0)
    await(fn -> state(pid).edge_scroll == nil end)
    stopped = state(pid)
    assert stopped.offset_y == 0
    assert stopped.selection.head == {0, 0}
    Process.sleep(80)
    assert state(pid) == stopped
  end

  test "viewport changes stop a pending tick without scrolling" do
    {pid, _} = start()
    mouse(pid, "press", 2, 2)
    mouse(pid, "move", 0, 0)
    initial = state(pid)
    mouse(pid, "release", 0, 0)
    viewport = initial.__element__
    changed = %{initial | __element__: %{viewport | viewport_height: 7}}
    stopped = Implicit.scroll_tick(initial.edge_scroll.token, changed)
    assert stopped.edge_scroll == nil
    assert stopped.offset_y == initial.offset_y
    assert stopped.selection == initial.selection
  end

  test "view forwarding ignores removed, replaced and unrelated terminals" do
    {pid, _} = start()
    mouse(pid, "press", 2, 2)
    mouse(pid, "move", 0, 0)
    token = state(pid).edge_scroll.token
    mouse(pid, "release", 0, 0)
    term = :sys.get_state(pid)
    message = {Breeze.VTerm, :edge_scroll, "terminal", token}

    for current <- [
          term,
          Breeze.View.reset(term, "terminal"),
          Breeze.View.put_implicit(term, "terminal", OtherImplicit, %{value: :untouched})
        ] do
      assert {:noreply, ^current, invalidate: false} = Breeze.VTerm.handle_info(message, current)
    end

    assert {:noreply, ^term, invalidate: false} =
             Breeze.VTerm.handle_info({Breeze.VTerm, :edge_scroll, "other", token}, term)
  end

  test "a previous drag's queued tick cannot move a new selection" do
    {pid, _} = start()
    mouse(pid, "press", 2, 2)
    mouse(pid, "move", 0, 0)
    old_token = state(pid).edge_scroll.token
    mouse(pid, "release", 0, 0)
    mouse(pid, "press", 3, 3)
    mouse(pid, "move", 0, 0)
    current = state(pid)
    refute current.edge_scroll.token == old_token
    assert ^current = Implicit.scroll_tick(old_token, current)
    mouse(pid, "release", 0, 0)
  end

  defp start(lines \\ 120) do
    surface =
      Surface.new(cols: 24, rows: 6)
      |> Surface.write(Enum.map_join(1..lines, "\r\n", &"line #{&1}"))

    {:ok, pid} =
      Breeze.ChildServer.start(
        view: View,
        start_opts: [owner: self(), surface: surface],
        terminal: %Termite.Terminal{size: %{width: 24, height: 6}}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    Breeze.ChildServer.render_snapshot(pid, focused: "terminal")
    {pid, surface}
  end

  defp state(pid), do: :sys.get_state(pid).implicit_state["terminal"] |> elem(1)

  defp mouse(pid, action, x, y),
    do:
      Breeze.ChildServer.dispatch_input(pid, %{
        "mouse" => %{"button" => "left", "action" => action, "x" => x, "y" => y}
      })

  defp await(fun, tries \\ 100)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, tries - 1)
        )
  end
end

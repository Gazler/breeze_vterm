defmodule Breeze.VTerm.ExampleTest do
  use ExUnit.Case, async: false

  alias Breeze.ChildServer

  defmodule TerminalAdapter do
    def write(owner, bytes) do
      send(owner, {:terminal_write, bytes})
      {:ok, owner}
    end
  end

  setup_all do
    previous = System.get_env("BREEZE_VTERM_SKIP_RUN")
    System.put_env("BREEZE_VTERM_SKIP_RUN", "1")

    try do
      Code.require_file("../../../examples/vterm.exs", __DIR__)
    after
      if previous,
        do: System.put_env("BREEZE_VTERM_SKIP_RUN", previous),
        else: System.delete_env("BREEZE_VTERM_SKIP_RUN")
    end

    :ok
  end

  setup do
    terminal = %Termite.Terminal{
      adapter: {TerminalAdapter, self()},
      size: %{width: 100, height: 20}
    }

    {:ok, pid} =
      ChildServer.start(view: VTermExample, terminal: terminal, start_opts: [start_shells: false])

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    ChildServer.render_snapshot(pid, focused: "vterm")
    layout = ChildServer.layout_snapshot(pid).mouse_targets["vterm"]
    %{pid: pid, x: layout.left + 1, y: layout.top + 1}
  end

  test "dragging selects text and right-click sends it to the terminal clipboard", context do
    %{pid: pid, x: x, y: y} = context
    mouse(pid, "left", "press", x, y)
    mouse(pid, "left", "move", x + 2, y)
    mouse(pid, "left", "release", x + 2, y)
    assert :sys.get_state(pid).assigns.selecting

    mouse(pid, "right", "press", x, y)
    clipboard = "\e]52;c;" <> Base.encode64("fra") <> "\e\\"
    assert_receive {:terminal_write, ^clipboard}

    assert {:noreply, "vterm", true} = ChildServer.dispatch_input(pid, "x")
    state = :sys.get_state(pid)
    refute state.assigns.selecting
    assert {_, %{selection: nil}} = state.implicit_state["vterm"]
  end

  test "Ctrl-C clears a selection at an empty prompt without quitting", context do
    %{pid: pid, x: x, y: y} = context

    consoles =
      Enum.map(:sys.get_state(pid).assigns.consoles, fn console ->
        %{console | shell_busy?: false, command: "", prompt_cursor: console.surface.cursor}
      end)

    :ok = ChildServer.update_assigns(pid, consoles: consoles)
    ChildServer.render_snapshot(pid, focused: "vterm")
    mouse(pid, "left", "press", x, y)
    mouse(pid, "left", "move", x + 2, y)
    mouse(pid, "left", "release", x + 2, y)

    ChildServer.render_snapshot(pid, focused: "vterm")
    assert ChildServer.metadata(pid).focused_implicit_meta.captures_control_keys

    assert {:noreply, "vterm", true} =
             ChildServer.dispatch_input(pid, %{"key" => "c", "ctrlKey" => true})

    refute :sys.get_state(pid).assigns.selecting
    assert :sys.get_state(pid).mouse_capture == nil
  end

  defp mouse(pid, button, action, x, y) do
    ChildServer.dispatch_input(pid, %{
      "mouse" => %{"button" => button, "action" => action, "x" => x, "y" => y}
    })
  end
end

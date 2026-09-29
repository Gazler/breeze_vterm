defmodule Breeze.VTerm.ComponentsTest do
  use ExUnit.Case, async: true

  alias Breeze.ChildServer
  alias Breeze.VTerm.Surface

  defmodule PromptTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface = Surface.new(cols: 8, rows: 2) |> Surface.write("❯ ")
      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="width-10 height-4">
        <.terminal id="terminal" surface={@surface} class="border"/>
      </box>
      """
    end

    def handle_info({:output, bytes}, term) do
      {:noreply, assign(term, surface: Surface.write(term.assigns.surface, bytes))}
    end
  end

  test "a shell bell after backspace preserves the bordered terminal frame" do
    {:ok, pid} = ChildServer.start(view: PromptTerminalExample, start_opts: [])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, _, before_box} = ChildServer.render(pid, focused: "terminal")
    send(pid, {:output, "\a"})
    assert {:ok, _, after_box} = ChildServer.render(pid, focused: "terminal")

    assert after_box.content == before_box.content
    refute after_box.content =~ "\a"
    assert Enum.all?(plain_rows(after_box.content), &(BackBreeze.Utils.string_length(&1) == 10))
  end

  defmodule TerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface =
        Surface.new(cols: 10, rows: 3)
        |> Surface.write("ready")

      {:ok, term |> focus("terminal") |> assign(input: nil, surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-1 width-10 height-3">
        <.terminal id="terminal" surface={@surface} br-change="terminal_input"/>
      </box>
      """
    end

    def handle_event("terminal_input", %{input: input}, term) do
      {:noreply, assign(term, input: input)}
    end

    def handle_event(_, _, term), do: {:noreply, term}
  end

  defmodule ColoredTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface =
        Surface.new(cols: 10, rows: 2)
        |> Surface.write("\e[32mgreen\e[0m")

      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="width-10 height-2">
        <.terminal id="terminal" surface={@surface}/>
      </box>
      """
    end
  end

  defmodule WideTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface =
        Surface.new(cols: 12, rows: 2)
        |> Surface.write("abcdefghijkl")

      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-1 width-10 height-2">
        <.terminal id="terminal" surface={@surface}/>
      </box>
      """
    end
  end

  defmodule ScrollbackTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface =
        Surface.new(cols: 10, rows: 3)
        |> Surface.write("one\r\ntwo\r\nthree\r\nfour")

      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-1 width-10 height-3">
        <.terminal id="terminal" surface={@surface}/>
      </box>
      """
    end
  end

  defmodule ReleasedCaptureTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface = Surface.new(cols: 10, rows: 3)

      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-1 width-10 height-3">
        <.terminal
          id="terminal"
          surface={@surface}
          capture_control_keys="false"
          capture_focus_keys="false"
        />
      </box>
      """
    end
  end

  defmodule BorderedScrollbarTerminalExample do
    use Breeze.View
    import Breeze.VTerm.Components

    def mount(_opts, term) do
      surface =
        Surface.new(cols: 10, rows: 8)
        |> Surface.write(
          Enum.map_join(1..24, "\r\n", fn index ->
            "line " <> String.pad_leading(Integer.to_string(index), 2, "0")
          end)
        )

      {:ok, term |> focus("terminal") |> assign(surface: surface)}
    end

    def render(assigns) do
      ~H"""
      <box class="grid grid-cols-1 width-12 height-10">
        <.terminal id="terminal" surface={@surface} class="border"/>
      </box>
      """
    end
  end

  test "renders a terminal surface as a focusable block" do
    {:ok, pid} = ChildServer.start(view: TerminalExample, start_opts: [])

    assert {:ok, acc, box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})
    assert acc.focusables == ["terminal"]
    assert box.content =~ "ready"
  end

  test "emits encoded input from focused terminal blocks" do
    {:ok, pid} = ChildServer.start(view: TerminalExample, start_opts: [])

    assert {:ok, _acc, _box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})
    assert {:noreply, "terminal", true} = ChildServer.dispatch_input(pid, "ArrowUp")

    assert :sys.get_state(pid).assigns.input == "\e[A"
  end

  test "page keys scroll focused terminal blocks instead of emitting shell input" do
    {:ok, pid} = ChildServer.start(view: TerminalExample, start_opts: [])

    assert {:ok, _acc, _box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})
    assert {:noreply, "terminal", true} = ChildServer.dispatch_input(pid, "PageUp")
    assert :sys.get_state(pid).assigns.input == nil

    assert {:noreply, "terminal", true} = ChildServer.dispatch_input(pid, "PageDown")
    assert :sys.get_state(pid).assigns.input == nil
  end

  test "can release control and focus key capture through component attributes" do
    {:ok, pid} = ChildServer.start(view: ReleasedCaptureTerminalExample, start_opts: [])

    assert {:ok, _acc, _box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})

    assert %{
             captures_printable_keys: true,
             captures_keys: ["PageUp", "PageDown"]
           } = ChildServer.metadata(pid).focused_implicit_meta

    refute Map.has_key?(ChildServer.metadata(pid).focused_implicit_meta, :captures_control_keys)
    refute Map.has_key?(ChildServer.metadata(pid).focused_implicit_meta, :captures_focus_keys)
  end

  test "renders SGR foreground colors from terminal output" do
    {:ok, pid} = ChildServer.start(view: ColoredTerminalExample, start_opts: [])

    assert {:ok, _acc, box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})
    assert box.content =~ ~r/\e\[[0-9;]*38;5;2mgreen\e\[0m/
    refute box.content =~ "38;5;2;38;5;"
  end

  test "clips terminal rows to the rendered viewport width" do
    {:ok, pid} = ChildServer.start(view: WideTerminalExample, start_opts: [])

    assert {:ok, acc, box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})

    assert box.content =~ "abcdefghij"
    refute box.content =~ "kl"

    assert %{width: 10, content_width: 10, viewport_width: 10} =
             Enum.find(acc.dimensions, &match?(%{width: 10}, &1))
  end

  test "renders an arrowed vertical scrollbar when terminal scrollback overflows" do
    {:ok, pid} = ChildServer.start(view: ScrollbackTerminalExample, start_opts: [])

    assert {:ok, acc, box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})

    assert %BackBreeze.Scrollbar{enabled: true, axis: :vertical} =
             acc.boxes["terminal"].style.scrollbar

    assert box.content =~ "█"
    assert box.content =~ "▲"
    assert box.content =~ "▼"
  end

  test "can render an arrowed scrollbar on a bordered terminal without narrowing content" do
    {:ok, pid} = ChildServer.start(view: BorderedScrollbarTerminalExample, start_opts: [])

    assert {:ok, acc, box} = ChildServer.render(pid, focused: "terminal", implicit_state: %{})

    assert %BackBreeze.Scrollbar{mode: :inset} = acc.boxes["terminal"].style.scrollbar

    assert box.content =~ "line 17   ▲"
    assert box.content =~ "line 18   │"
    assert box.content =~ "line 22   █"
    assert box.content =~ "line 23   █"
    assert box.content =~ "line 24   ▼"
    refute box.content =~ "││"
    assert box.content |> String.graphemes() |> Enum.count(&(&1 == "█")) == 2

    assert box.content
           |> plain_rows()
           |> Enum.all?(&(BackBreeze.Utils.string_length(&1) == 12))
  end

  test "renders the cursor as a focused terminal overlay" do
    {:ok, pid} = ChildServer.start(view: TerminalExample, start_opts: [])

    assert {:ok, _acc, _box, [decoration]} =
             ChildServer.render_snapshot(pid, focused: "terminal", implicit_state: %{})

    assert %{
             mod: Breeze.VTerm.Implicit,
             active_when_focused: true,
             every_ms: 500,
             state: %{cursor: %{row: 0, col: 5, char: " "}},
             box: box,
             layout: layout
           } = decoration

    assert {:ok, ^box, overlays: [overlay]} =
             Breeze.VTerm.Implicit.animate(:root, box, [focused: true], decoration.state, %{
               layout: layout,
               now: 0,
               last_interaction_at: 0,
               theme: Breeze.Theme.new(:system16)
             })

    assert overlay.x == layout.left + 5
    assert overlay.y == layout.top
    assert overlay.char == " "
  end

  defp plain_rows(content) do
    content
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.split("\n")
  end
end

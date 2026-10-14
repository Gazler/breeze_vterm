defmodule Breeze.VTerm.FrameIntegrationTest do
  use ExUnit.Case, async: false

  alias Breeze.VTerm.Surface

  defmodule Adapter do
    def write(owner, bytes) do
      send(owner, {:frame_bytes, bytes})
      {:ok, owner}
    end
  end

  defmodule Child do
    use Breeze.View

    def mount(opts, term) do
      send(opts[:observer], {:child, self()})
      {:ok, assign(term, text: String.duplicate("a", 100))}
    end

    def render(assigns) do
      ~H"""
      <box class="width-full height-full bg-panel">{@text}</box>
      """
    end

    def handle_info(:edit, term),
      do: {:noreply, assign(term, text: "z" <> String.duplicate("a", 99))}
  end

  defmodule Root do
    use Breeze.View
    def mount(opts, term), do: {:ok, assign(term, observer: opts[:observer])}

    def render(assigns) do
      ~H"""
      <box class="relative width-full height-full">
        <box style="fixed top-0 left-0 width-full height-1">Header</box>
        <box style="fixed top-1 left-0 width-full height-4">
          <live
            id="child"
            view={Breeze.VTerm.FrameIntegrationTest.Child}
            start_opts={[observer: @observer]}
          >
          </live>
        </box>
      </box>
      """
    end
  end

  @tag skip:
         if(Map.has_key?(%Breeze.Server.State.Frame{}, :renderer),
           do: false,
           else: "requires Breeze frame_renderer support"
         )
  test "live child updates go through the configured renderer and preserve surrounding UI" do
    terminal = %Termite.Terminal{
      adapter: {Adapter, self()},
      reader: make_ref(),
      size: %{width: 100, height: 6}
    }

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Root,
        start_opts: [observer: self()],
        terminal: terminal,
        theme: Breeze.Theme.builtin(:gruvbox),
        frame_renderer: Breeze.VTerm.Frame
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert_receive {:child, child}
    initial = collect([])
    assert initial != ""
    previous = :sys.get_state(pid)
    Breeze.ChildServer.dispatch_info(child, :edit, terminal)
    assert_receive {:frame_bytes, delta}, 2_000
    assert String.starts_with?(delta, "\e[?2026h")
    assert String.ends_with?(delta, "\e[?2026l")
    state = :sys.get_state(pid)
    assert state.debug.stats.last_render_cause == :child_patch

    original_delta =
      Breeze.Server.Frame.build_payload(
        previous.frame.last_lines,
        state.frame.last_lines,
        previous.frame.last_overlays,
        state.frame.last_overlays,
        100
      )

    assert byte_size(delta) < byte_size(original_delta)

    actual = Surface.new(cols: 100, rows: 6) |> Surface.write(initial) |> Surface.write(delta)

    reference =
      Breeze.Server.Frame.build_payload(
        nil,
        state.frame.last_lines,
        [],
        state.frame.last_overlays,
        100
      )

    expected = Surface.new(cols: 100, rows: 6) |> Surface.write(reference)
    assert actual.screen == expected.screen
    assert Enum.at(actual.screen, 0) |> Enum.take(6) |> Enum.map_join(& &1.text) == "Header"
  end

  defp collect(chunks) do
    receive do
      {:frame_bytes, bytes} -> collect([bytes | chunks])
    after
      0 -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end

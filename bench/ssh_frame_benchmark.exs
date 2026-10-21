# Uses the Breeze Git dependency configured in mix.exs.
# mix run bench/ssh_frame_benchmark.exs
# SCENARIO=scroll mix run bench/ssh_frame_benchmark.exs
# SCENARIO=scroll BASELINE=cell LAYOUT=framed TIMINGS=1 mix run bench/ssh_frame_benchmark.exs
# FIXTURE=source SIZE=156x80 LAYOUT=framed SCENARIO=scroll mix run bench/ssh_frame_benchmark.exs
# SCENARIO=hold SIZE=80x24 mix run bench/ssh_frame_benchmark.exs
# Starts a loopback-only, temporary SSH listener. No external server is used.
Mix.ensure_application!(:ssh)
{:ok, _} = Application.ensure_all_started(:ssh)
if System.get_env("PROFILE") == "1", do: Mix.ensure_application!(:tools)

defmodule BreezeVTerm.SSHFrameBenchmark.Adapter do
  def start(opts) do
    terminal = opts |> Map.new() |> Map.merge(%{owner: self(), ref: make_ref()})
    send(terminal.channel_pid, {:reader, terminal.owner, terminal.ref})
    {:ok, terminal}
  end

  def reader(terminal), do: {:ok, terminal.ref}

  def resize(terminal) do
    ref = make_ref()
    send(terminal.channel_pid, {:geometry, self(), ref})

    receive do
      {^ref, size} -> size
    after
      5_000 -> %{width: 80, height: 24}
    end
  end

  def stop(_terminal), do: :ok

  def write(terminal, bytes) do
    bytes = IO.iodata_to_binary(bytes)

    case :ssh_connection.send(terminal.connection, terminal.channel, bytes) do
      :ok -> send(terminal.observer, {:server_bytes, bytes})
      {:error, _} -> send(terminal.owner, {terminal.ref, {:signal, :hup}})
    end

    {:ok, terminal}
  end
end

# Serve Breeze directly as an SSH channel: no OS PTY, shell or line editor.
defmodule BreezeVTerm.SSHFrameBenchmark.Channel do
  @behaviour :ssh_server_channel
  def init([observer, renderer, surface, framed?]) do
    {:ok,
     %{
       observer: observer,
       renderer: renderer,
       surface: surface,
       framed?: framed?,
       owner: nil,
       ref: nil,
       channel: nil,
       size: %{width: surface.cols, height: surface.rows}
     }}
  end

  def handle_msg({:ssh_channel_up, channel, _connection}, state),
    do: {:ok, %{state | channel: channel}}

  def handle_msg({:reader, owner, ref}, state), do: {:ok, %{state | owner: owner, ref: ref}}

  def handle_msg({:geometry, from, ref}, state) do
    send(from, {ref, state.size})
    {:ok, state}
  end

  def handle_msg(_, state), do: {:ok, state}

  def handle_ssh_msg(
        {:ssh_cm, connection, {:pty, channel, reply, {_term, width, height, _, _, _}}},
        state
      ) do
    :ssh_connection.reply_request(connection, reply, :success, channel)
    {:ok, %{state | size: %{width: width, height: height}}}
  end

  def handle_ssh_msg({:ssh_cm, connection, {:shell, channel, reply}}, state) do
    channel_pid = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)

      result =
        Breeze.Server.start_link(
          view: BreezeVTerm.SSHFrameBenchmark.View,
          start_opts: [surface: state.surface, observer: state.observer, framed?: state.framed?],
          theme: Breeze.Theme.builtin(:gruvbox),
          frame_renderer: state.renderer,
          mouse: [mode: :drag],
          enhanced_keyboard: false,
          terminal_opts: [
            adapter: BreezeVTerm.SSHFrameBenchmark.Adapter,
            channel_pid: channel_pid,
            connection: connection,
            channel: channel,
            observer: state.observer
          ]
        )

      case result do
        {:ok, session} ->
          send(state.observer, {:session, session})
          ref = Process.monitor(session)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          end

        {:error, reason} ->
          send(state.observer, {:startup_error, reason})
      end
    end)

    :ssh_connection.reply_request(connection, reply, :success, channel)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:data, _, 0, bytes}}, state) do
    send(state.owner, {state.ref, {:data, bytes}})
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:window_change, _, width, height, _, _}}, state) do
    send(state.owner, {state.ref, {:signal, :winch}})
    {:ok, %{state | size: %{width: width, height: height}}}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, channel}}, state), do: {:stop, channel, state}
  def handle_ssh_msg(_, state), do: {:ok, state}

  def terminate(_, state) do
    if state.owner, do: send(state.owner, {state.ref, {:signal, :hup}})
    :ok
  end
end

defmodule BreezeVTerm.SSHFrameBenchmark.View do
  use Breeze.View
  import Breeze.VTerm.Components

  def mount(opts, term) do
    send(opts[:observer], {:view, self()})

    {:ok,
     term
     |> assign(
       surface: opts[:surface],
       framed?: opts[:framed?],
       autoscroll: System.get_env("SCENARIO") == "hold"
     )
     |> focus("terminal")}
  end

  def render(%{framed?: true} = assigns) do
    ~H"""
    <box class="relative width-full height-full">
      <box style="fixed top-0 left-0 width-full height-1" class="bg-panel">SSH benchmark header</box>
      <box style={"fixed top-1 left-0 width-20 height-#{@surface.rows}"} class="bg-panel">
        <box class="height-1">Sidebar</box>
        <box class="height-1">Console A</box>
        <box class="height-1">Console B</box>
        <box class="height-1">Status: connected</box>
      </box>
      <box style={"fixed top-1 left-20 width-#{@surface.cols} height-#{@surface.rows}"}>
        <.terminal
          id="terminal"
          surface={@surface}
          selectable
          selection_autoscroll={if @autoscroll do
      "true"
    else
      "false"
    end}
          cursor-blink={false}
          br-change="input"
        />
      </box>
      <box style="fixed bottom-0 left-0 width-full height-1" class="bg-panel">
        SSH benchmark footer
      </box>
    </box>
    """
  end

  def render(assigns) do
    ~H"""
    <box class="width-full height-full">
      <.terminal
        id="terminal"
        surface={@surface}
        selectable
        selection_autoscroll={if @autoscroll do
      "true"
    else
      "false"
    end}
        cursor-blink={false}
        br-change="input"
      />
    </box>
    """
  end

  # Match examples/vterm.exs: copy sends the selected text through OSC 52.
  def handle_event("input", %{copy: text}, term) do
    terminal = Termite.Terminal.write(term.terminal, "\e]52;c;" <> Base.encode64(text) <> "\e\\")
    {:noreply, %{term | terminal: terminal}}
  end

  def handle_event("input", _, term), do: {:noreply, term}

  def handle_info({Breeze.VTerm, :edge_scroll, _, _} = message, term),
    do: Breeze.VTerm.handle_info(message, term)

  def handle_info(:edit, term) do
    {:noreply, assign(term, surface: Breeze.VTerm.write(term.assigns.surface, "\e[1;1HZ"))}
  end
end

defmodule BreezeVTerm.SSHFrameBenchmark.CellFrame do
  def build_payload(previous, lines, old, new, width),
    do: Breeze.VTerm.Frame.build_payload(previous, lines, old, new, width, scroll: false)
end

defmodule BreezeVTerm.SSHFrameBenchmark do
  @compile {:no_warn_undefined, :eprof}
  alias BreezeVTerm.SSHFrameBenchmark.Channel
  alias Breeze.VTerm.Surface

  def run do
    Logger.configure(level: :warning)

    unless Map.has_key?(%Breeze.Server.State.Frame{}, :renderer),
      do: raise("Requires Breeze with frame_renderer support; update the dependency first")

    [cols, rows] =
      System.get_env("SIZE", "400x120") |> String.split("x") |> Enum.map(&String.to_integer/1)

    if cols < 25 or rows < 8, do: raise("SIZE must be at least 25x8")

    scenario = System.get_env("SCENARIO", "stationary")

    unless scenario in ["stationary", "scroll", "hold"],
      do: raise("Unknown SCENARIO: #{scenario}")

    layout = System.get_env("LAYOUT", "full")
    unless layout in ["full", "framed"], do: raise("Unknown LAYOUT: #{layout}")

    if layout == "framed" and (cols < 45 or rows < 10),
      do: raise("Framed SIZE must be at least 45x10")

    baseline =
      case System.get_env("BASELINE", "row") do
        "row" -> Breeze.Server.Frame
        "cell" -> BreezeVTerm.SSHFrameBenchmark.CellFrame
        other -> raise("Unknown BASELINE: #{other}")
      end

    dir =
      Path.join(
        System.tmp_dir!(),
        "breeze-ssh-bench-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      {_, 0} =
        System.cmd("ssh-keygen", [
          "-q",
          "-t",
          "ed25519",
          "-N",
          "",
          "-f",
          Path.join(dir, "ssh_host_ed25519_key")
        ])

      IO.puts("Breeze served directly over OTP SSH; #{cols}x#{rows}; one pane; static cursor.")
      IO.puts("Scenario: #{scenario}; layout: #{layout}; baseline: #{inspect(baseline)}")

      IO.puts(
        "SSH bytes count encrypted server→client TCP payload, excluding handshake and TCP/IP headers."
      )

      IO.puts(
        "fixture,action,before_ANSI_B,after_ANSI_B,before_SSH_B,after_SSH_B,before_first_byte_us,after_first_byte_us"
      )

      fixtures =
        case System.get_env("FIXTURE", "all") do
          "all" -> [:ascii, :styled]
          "source" -> [:source]
          other -> raise("Unknown FIXTURE: #{other}")
        end

      for fixture <- fixtures do
        before = measure(dir, baseline, fixture, cols, rows, scenario, layout)
        after_result = measure(dir, Breeze.VTerm.Frame, fixture, cols, rows, scenario, layout)

        for {action, old} <- before do
          new = Keyword.fetch!(after_result, action)

          if old.screen != new.screen do
            differences =
              for {key, value} <- old.screen, value != new.screen[key] do
                if key == :screen do
                  cells =
                    Enum.zip(List.flatten(value), List.flatten(new.screen[key]))
                    |> Enum.with_index()
                    |> Enum.filter(fn {{a, b}, _} -> a != b end)
                    |> Enum.take(3)

                  {key, cells}
                else
                  {key, value, new.screen[key]}
                end
              end

            raise("Different SSH screens for #{fixture}/#{action}: #{inspect(differences)}")
          end

          if old.selection != new.selection,
            do: raise("Different selections for #{fixture}/#{action}")

          IO.puts(
            Enum.join(
              [
                fixture,
                action,
                old.bytes,
                new.bytes,
                old.ssh,
                new.ssh,
                old.first_byte_us,
                new.first_byte_us
              ],
              ","
            )
          )
        end
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp measure(dir, renderer, fixture, cols, rows, scenario, layout) do
    observer = self()

    viewport =
      if layout == "framed",
        do: %{cols: cols - 20, rows: rows - 2, left: 20, top: 1},
        else: %{cols: cols, rows: rows, left: 0, top: 0}

    texts = fixture_texts(viewport.cols, viewport.rows, scenario, fixture)

    surface =
      Surface.new(cols: viewport.cols, rows: viewport.rows)
      |> Surface.write(Enum.map_join(texts, "\r\n", &style_line(&1, fixture)) <> "\e[H")

    password = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    {:ok, daemon} =
      :ssh.daemon(0,
        ip: {127, 0, 0, 1},
        system_dir: String.to_charlist(dir),
        user_dir: String.to_charlist(dir),
        auth_methods: ~c"password",
        user_passwords: [{~c"bench", String.to_charlist(password)}],
        ssh_cli: {Channel, [observer, renderer, surface, layout == "framed"]}
      )

    {:ok, info} = :ssh.daemon_info(daemon)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, nodelay: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    proxy = spawn_link(fn -> proxy_accept(listener, info[:port]) end)

    try do
      {:ok, connection} =
        :ssh.connect(
          ~c"127.0.0.1",
          port,
          [
            user: ~c"bench",
            password: String.to_charlist(password),
            silently_accept_hosts: true,
            save_accepted_host: false,
            user_interaction: false,
            user_dir: String.to_charlist(dir),
            preferred_algorithms: [compression: [:none]]
          ],
          10_000
        )

      try do
        {:ok, channel} = :ssh_connection.session_channel(connection, 10_000)

        :success =
          :ssh_connection.ptty_alloc(
            connection,
            channel,
            [term: ~c"xterm-256color", width: cols, height: rows],
            10_000
          )

        algorithms = :ssh.connection_info(connection, [:algorithms])
        IO.puts("# #{fixture}, #{inspect(renderer)}: #{inspect(algorithms[:algorithms])}")
        :ok = :ssh_connection.shell(connection, channel)

        initial =
          collect(connection, channel, %{server: [], client: [], session: nil, view: nil}, 500)

        unless initial.session && initial.view,
          do: raise("SSH TUI did not start: #{inspect(initial)}")

        expected = IO.iodata_to_binary(Enum.reverse(initial.server))
        received = IO.iodata_to_binary(Enum.reverse(initial.client))
        if expected != received, do: raise("Initial SSH output differs from adapter writes")

        display =
          Surface.new(cols: cols, rows: rows, scrollback_limit: 0) |> Surface.write(received)

        try do
          actions = actions(scenario, connection, channel, initial.view, viewport)

          {results, _} =
            Enum.map_reduce(
              actions,
              display,
              fn {action, trigger}, display ->
                previous = implicit_state(initial.view)
                old_frame = :sys.get_state(Breeze.Server.runtime_pid(initial.session)).frame

                profile? =
                  System.get_env("PROFILE") == "1" and renderer == Breeze.VTerm.Frame and
                    action == :scroll_up_1

                if profile?,
                  do:
                    :eprof.start_profiling([
                      initial.view,
                      Breeze.Server.runtime_pid(initial.session)
                    ])

                before_bytes = proxy_bytes(proxy)
                sent_at = System.monotonic_time(:microsecond)
                trigger.()

                result =
                  collect(
                    connection,
                    channel,
                    %{server: [], client: [], session: initial.session, view: initial.view},
                    if(scenario == "hold", do: 500, else: 150),
                    action not in [:selection_press, :down_press, :release]
                  )

                if profile? do
                  :eprof.stop_profiling()
                  IO.puts("# profile #{fixture}/#{action}")
                  :eprof.analyze(:total, sort: :time)
                end

                server = result.server |> Enum.reverse() |> IO.iodata_to_binary()
                client = result.client |> Enum.reverse() |> IO.iodata_to_binary()

                if server != client,
                  do:
                    raise(
                      "SSH output differs for #{action}: #{byte_size(server)} sent, #{byte_size(client)} received"
                    )

                display = Surface.write(display, client)
                implicit = implicit_state(initial.view)

                if scenario == "scroll",
                  do: verify_scroll!(action, previous, implicit, client, texts)

                if scenario == "hold" and action == :hold_top do
                  unless implicit.offset_y == 0 and implicit.edge_scroll == nil and
                           implicit.selection.anchor == previous.selection.anchor and
                           implicit.selection.head == {0, 0},
                         do: raise("Holding the edge did not reach the start of scrollback")

                  IO.puts(
                    "# held edge: #{previous.scrollback_rows} rows, #{length(result.server)} writes, #{result.last_byte_at - sent_at} us to final output; no further mouse movement"
                  )
                end

                if scenario == "hold" and action == :copy_scrollback,
                  do: verify_scroll!(action, previous, implicit, client, texts, false)

                frame = verify_display!(initial.session, display, cols, rows, action)

                if renderer == Breeze.VTerm.Frame and action in [:scroll_up_1, :scroll_down_1] do
                  capture_frame(
                    old_frame,
                    frame,
                    previous,
                    implicit,
                    viewport,
                    cols,
                    fixture,
                    action
                  )
                end

                if System.get_env("TIMINGS") == "1" and renderer == Breeze.VTerm.Frame and
                     action in [:scroll_up_1, :scroll_down_1] do
                  time_composition(old_frame, frame, cols, fixture, action)
                end

                metrics = %{
                  bytes: byte_size(client),
                  ssh: proxy_bytes(proxy) - before_bytes,
                  first_byte_us: if(result[:first_byte_at], do: result.first_byte_at - sent_at),
                  screen: Map.take(display, [:screen, :cursor, :style, :wrap_pending?]),
                  selection: Map.take(implicit, [:offset_y, :pinned_bottom, :selection])
                }

                {{action, metrics}, display}
              end
            )

          results
        after
          Breeze.Server.stop(initial.session)

          collect(
            connection,
            channel,
            %{server: [], client: [], session: initial.session, view: initial.view},
            100
          )
        end
      after
        :ssh.close(connection)
      end
    after
      send(proxy, :stop)
      :gen_tcp.close(listener)
      :ssh.stop_daemon(daemon)
    end
  end

  defp fixture_texts(cols, rows, scenario, :source) do
    lines =
      File.read!(Path.expand("../lib/breeze/vterm/surface.ex", __DIR__)) |> String.split("\n")

    count = if scenario in ["scroll", "hold"], do: rows * 3, else: rows

    lines
    |> Stream.cycle()
    |> Enum.take(count)
    |> Enum.map(&String.slice(&1, 0, cols))
  end

  defp fixture_texts(cols, rows, "stationary", _) do
    text = for col <- 0..(cols - 1), into: "", do: <<?a + rem(col, 26)>>
    List.duplicate(text, rows)
  end

  defp fixture_texts(cols, rows, scenario, _) when scenario in ["scroll", "hold"] do
    # Distinct dense rows prevent a stationary/repeated-row fixture from hiding
    # the cost of shifting the viewport. Three screens include two of history.
    for row <- 0..(rows * 3 - 1) do
      body =
        for block <- 0..div(cols, 64), into: "" do
          :crypto.hash(:sha256, "#{row}:#{block}") |> Base.encode16(case: :lower)
        end

      (String.pad_leading(Integer.to_string(row), 6, "0") <> " " <> body)
      |> binary_part(0, cols)
    end
  end

  defp style_line(text, fixture) when fixture in [:ascii, :source], do: text

  defp style_line(text, :styled) do
    for col <- 0..(byte_size(text) - 1)//8, into: "" do
      "\e[#{if rem(div(col, 8), 2) == 0, do: 31, else: 32}m" <>
        binary_part(text, col, min(8, byte_size(text) - col))
    end <> "\e[0m"
  end

  defp actions("stationary", connection, channel, view, viewport) do
    [
      {:edit_cell, fn -> send(view, :edit) end},
      {:selection_press, fn -> mouse(connection, channel, viewport, 0, 1, 1) end},
      {:select_prefix, fn -> mouse(connection, channel, viewport, 32, 20, 6) end},
      {:extend_cell, fn -> mouse(connection, channel, viewport, 32, 21, 6) end},
      {:extend_row, fn -> mouse(connection, channel, viewport, 32, 21, 7) end},
      {:clear_selection, fn -> :ssh_connection.send(connection, channel, "\e") end}
    ]
  end

  defp actions("scroll", connection, channel, _view, %{rows: rows} = viewport) do
    [
      {:selection_press, fn -> mouse(connection, channel, viewport, 0, 20, div(rows, 2)) end},
      {:select_to_top, fn -> mouse(connection, channel, viewport, 32, 1, 2) end},
      {:wheel_up_drag, fn -> mouse(connection, channel, viewport, 64, 1, 2) end},
      {:wheel_down_drag, fn -> mouse(connection, channel, viewport, 65, 1, 2) end},
      {:scroll_up_1, fn -> mouse(connection, channel, viewport, 32, 1, 1) end},
      {:scroll_up_2, fn -> mouse(connection, channel, viewport, 32, 1, 1) end},
      {:scroll_up_3, fn -> mouse(connection, channel, viewport, 32, 1, 1) end},
      {:release, fn -> mouse(connection, channel, viewport, 0, 1, 1, "m") end},
      {:wheel_down, fn -> mouse(connection, channel, viewport, 65, 1, 2) end},
      {:copy_scrollback, fn -> mouse(connection, channel, viewport, 2, 1, 1) end},
      {:wheel_up, fn -> mouse(connection, channel, viewport, 64, 1, 2) end},
      {:clear_selection, fn -> :ssh_connection.send(connection, channel, "\e") end},
      {:down_press, fn -> mouse(connection, channel, viewport, 0, 1, 2) end},
      {:select_to_bottom, fn -> mouse(connection, channel, viewport, 32, 20, rows - 1) end},
      {:scroll_down_1, fn -> mouse(connection, channel, viewport, 32, 20, rows) end},
      {:scroll_down_2, fn -> mouse(connection, channel, viewport, 32, 20, rows) end},
      {:scroll_down_3, fn -> mouse(connection, channel, viewport, 32, 20, rows) end}
    ]
  end

  defp actions("hold", connection, channel, _view, %{rows: rows} = viewport) do
    [
      {:selection_press, fn -> mouse(connection, channel, viewport, 0, 20, div(rows, 2)) end},
      {:hold_top, fn -> mouse(connection, channel, viewport, 32, 1, 1) end},
      {:release, fn -> mouse(connection, channel, viewport, 0, 1, 1, "m") end},
      {:copy_scrollback, fn -> mouse(connection, channel, viewport, 2, 1, 1) end}
    ]
  end

  defp implicit_state(view) do
    term = :sys.get_state(view)
    {_, state} = term.implicit_state["terminal"]
    Map.put(state, :mouse_capture, term.mouse_capture)
  end

  defp verify_display!(session, display, cols, rows, action) do
    frame = :sys.get_state(Breeze.Server.runtime_pid(session)).frame
    full = Breeze.Server.Frame.build_payload(nil, frame.last_lines, [], frame.last_overlays, cols)
    reference = Surface.new(cols: cols, rows: rows, scrollback_limit: 0) |> Surface.write(full)

    unless display.screen == reference.screen,
      do: raise("SSH display differs from a fresh full frame for #{action}")

    frame
  end

  defp time_composition(previous, frame, width, fixture, action) do
    args = [
      previous.last_lines,
      frame.last_lines,
      previous.last_overlays,
      frame.last_overlays,
      width
    ]

    for renderer <- [
          Breeze.Server.Frame,
          BreezeVTerm.SSHFrameBenchmark.CellFrame,
          Breeze.VTerm.Frame
        ] do
      us =
        Task.async(fn ->
          apply(renderer, :build_payload, args)

          for _ <- 1..7 do
            :erlang.garbage_collect()
            {us, _} = :timer.tc(fn -> apply(renderer, :build_payload, args) end)
            us
          end
          |> Enum.sort()
          |> Enum.at(3)
        end)
        |> Task.await(30_000)

      IO.puts(
        "# repeated frame composition #{fixture}/#{action}, #{inspect(renderer)}: #{us} us (median of 7 after priming, excludes layout/overlays/SSH)"
      )
    end
  end

  defp capture_frame(
         previous,
         frame,
         previous_implicit,
         implicit,
         viewport,
         width,
         fixture,
         action
       ) do
    if dir = System.get_env("CAPTURE_DIR") do
      File.mkdir_p!(dir)

      data = %{
        args: [
          previous.last_lines,
          frame.last_lines,
          previous.last_overlays,
          frame.last_overlays,
          width
        ],
        previous: previous_implicit,
        current: implicit,
        viewport: viewport,
        fixture: fixture,
        action: action
      }

      File.write!(
        Path.join(dir, "#{fixture}-#{action}.term"),
        :erlang.term_to_binary(data, [:compressed])
      )
    end
  end

  defp verify_scroll!(action, previous, state, client, texts, require_hidden? \\ true) do
    direction =
      cond do
        action in [:scroll_up_1, :scroll_up_2, :scroll_up_3] -> -1
        action in [:scroll_down_1, :scroll_down_2, :scroll_down_3] -> 1
        true -> 0
      end

    if direction != 0 do
      old_offset =
        if previous.pinned_bottom, do: previous.scrollback_rows, else: previous.offset_y

      unless state.offset_y == old_offset + direction and
               state.selection.anchor == previous.selection.anchor and state.selection.dragging?,
             do:
               raise(
                 "Selection did not scroll correctly for #{action}: #{inspect(state.selection)}"
               )

      expected_row = state.offset_y + if(direction < 0, do: 0, else: state.surface.rows - 1)

      unless elem(state.selection.head, 0) == expected_row,
        do: raise("Selection head did not follow the viewport for #{action}")
    end

    if action == :release and
         (state.selection.dragging? or state.offset_y != previous.offset_y or state.mouse_capture),
       do: raise("Release changed the viewport or retained capture")

    if action in [:wheel_up, :wheel_down, :wheel_up_drag, :wheel_down_drag] do
      delta = if action in [:wheel_up, :wheel_up_drag], do: -3, else: 3

      old_offset =
        if previous.pinned_bottom, do: previous.scrollback_rows, else: previous.offset_y

      unless state.offset_y == old_offset + delta and state.selection == previous.selection,
        do: raise("Wheel scrolling changed the selection or used the wrong offset")
    end

    if action == :copy_scrollback do
      selection = state.selection
      {{first, left}, {last, right}} = Enum.min_max([selection.anchor, selection.head])

      expected =
        texts
        |> Enum.slice(first..last)
        |> Enum.with_index(first)
        |> Enum.map_join("\n", fn {text, row} ->
          start = if row == first, do: left, else: 0
          finish = if row == last, do: right, else: selection.width - 1
          String.slice(text, start, finish - start + 1) |> String.trim_trailing(" ")
        end)

      unless first < state.scrollback_rows and (not require_hidden? or first < state.offset_y) and
               client == "\e]52;c;" <> Base.encode64(expected) <> "\e\\",
             do: raise("Copied text does not include the expected scrollback selection")

      IO.puts("# copy_scrollback: #{byte_size(expected)} UTF-8 bytes; #{last - first + 1} rows")
    end
  end

  defp mouse(connection, channel, viewport, button, x, y, final \\ "M"),
    do:
      :ssh_connection.send(
        connection,
        channel,
        "\e[<#{button};#{x + viewport.left};#{y + viewport.top}#{final}"
      )

  defp collect(connection, channel, acc, idle_ms, require_output? \\ false) do
    # Cold composition of a large styled frame can take longer than the drain
    # interval. Await the first write before applying that interval, so a slow
    # frame cannot be silently charged to the following mouse event.
    timeout = if require_output? and acc.server == [], do: 10_000, else: idle_ms

    receive do
      {:startup_error, reason} ->
        raise("SSH TUI startup failed: #{inspect(reason)}")

      {:server_bytes, bytes} ->
        collect(
          connection,
          channel,
          %{acc | server: [bytes | acc.server]},
          idle_ms,
          require_output?
        )

      {:ssh_cm, ^connection, {:data, ^channel, 0, bytes}} ->
        now = System.monotonic_time(:microsecond)
        acc = acc |> Map.put_new(:first_byte_at, now) |> Map.put(:last_byte_at, now)
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))

        collect(
          connection,
          channel,
          %{acc | client: [bytes | acc.client]},
          idle_ms,
          require_output?
        )

      {:session, pid} ->
        collect(connection, channel, %{acc | session: pid}, idle_ms, require_output?)

      {:view, pid} ->
        collect(connection, channel, %{acc | view: pid}, idle_ms, require_output?)

      {:ssh_cm, ^connection, _} ->
        collect(connection, channel, acc, idle_ms, require_output?)
    after
      timeout ->
        if require_output? and acc.server == [], do: raise("Timed out waiting for SSH frame")
        acc
    end
  end

  defp proxy_accept(listener, port) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        {:ok, server} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true, nodelay: true])

        :inet.setopts(client, active: true, nodelay: true)

        try do
          proxy_loop(client, server, 0)
        after
          :gen_tcp.close(client)
          :gen_tcp.close(server)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp proxy_loop(client, server, bytes) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(server, data)
        proxy_loop(client, server, bytes)

      {:tcp, ^server, data} ->
        :ok = :gen_tcp.send(client, data)
        proxy_loop(client, server, bytes + byte_size(data))

      {:bytes, from, ref} ->
        send(from, {ref, bytes})
        proxy_loop(client, server, bytes)

      :stop ->
        :ok

      {:tcp_closed, _} ->
        :ok
    end
  end

  defp proxy_bytes(proxy) do
    ref = make_ref()
    send(proxy, {:bytes, self(), ref})

    receive do
      {^ref, bytes} -> bytes
    after
      5_000 -> raise("SSH byte counter timed out")
    end
  end
end

BreezeVTerm.SSHFrameBenchmark.run()

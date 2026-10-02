defmodule VTermExample do
  use Breeze.View

  import Breeze.Blocks
  import Breeze.VTerm.Components

  alias Breeze.VTerm.LocalShell
  alias Breeze.VTerm

  require Logger

  @sidebar_width 35
  @terminal_border_cols 2
  @terminal_border_rows 2
  @main_header_rows 1
  @footer_rows 1
  @terminal_min_cols 20
  @terminal_min_rows 5
  @output_flush_ms 16
  @child_process_flags [min_heap_size: 16_000_000]

  @sidebar_class "width-#{@sidebar_width} height-full overflow-hidden bg-panel"

  @console_specs [
    %{
      id: "fra-web-01",
      name: "fra-web-01",
      host: "10.18.4.21",
      role: "web",
      status: "online"
    },
    %{
      id: "lon-db-01",
      name: "lon-db-01",
      host: "10.21.8.10",
      role: "database",
      status: "online"
    },
    %{
      id: "iad-build-02",
      name: "iad-build-02",
      host: "10.31.12.44",
      role: "builder",
      status: "idle"
    },
    %{
      id: "syd-edge-03",
      name: "syd-edge-03",
      host: "10.42.7.33",
      role: "edge",
      status: "degraded"
    }
  ]

  def mount(opts, term) do
    terminal_size = terminal_size(term)
    colors = query_colors(term.theme)
    consoles = Enum.map(@console_specs, &new_console(&1, terminal_size, opts, colors))

    {:ok,
     term
     |> focus("consoles")
     |> put_local_keybindings(base_keybindings())
     |> put_focus_keybindings("vterm", [{"^c", "Quit", &__MODULE__.quit_empty_shell/2}])
     |> assign(
       consoles: consoles,
       selected_console: hd(consoles).id,
       show_debug: System.get_env("BREEZE_DEBUG") == "1",
       pending_outputs: %{},
       output_flush_ref: nil
     )}
  end

  def render(assigns) do
    current_console = current_console(assigns)

    assigns =
      assigns
      |> assign(current_console: current_console)
      |> assign(capture_shell_input: boolean_attr(capture_shell_input?(current_console)))
      |> assign(sidebar_class: @sidebar_class)

    ~H"""
    <box class="grid grid-cols-1 grid-rows-2 width-screen height-screen bg">
      <box class="grid grid-cols-2 width-full height-full">
        <box class={@sidebar_class}>
          <box class="height-1 width-full overflow-hidden bold padding-left-1">Console</box>
          <.list
            id="consoles"
            br-change="select_console"
            list-selected={@selected_console}
            class="width-full height-full border focus:border-primary"
            item_class="width-full overflow-hidden"
          >
            <:item :for={console <- @consoles} value={console.id}>
              <box class="inline width-full overflow-hidden">
                <box class={console.status_class}>{console.status_label}</box>
                <box class="width-13 overflow-hidden">{console.name}</box>
                <box class="width-full text-muted overflow-hidden">{console.role}</box>
              </box>
            </:item>
          </.list>
        </box>
        <box class="grid grid-cols-1 grid-rows-2 width-full height-full">
          <box class="inline height-1 width-full overflow-hidden bg-panel padding-left-1">
            <box class="bold text-primary width-13 overflow-hidden">{@current_console.name}</box>
            <box class="text-muted width-15 overflow-hidden">{@current_console.host}</box>
            <box class={@current_console.status_class}>{@current_console.status}</box>
          </box>
          <.terminal
            id="vterm"
            surface={@current_console.surface}
            cursor-blink={false}
            br-change="vterm_input"
            class="border focus:border-primary"
            capture_control_keys={@capture_shell_input}
            capture_focus_keys={@capture_shell_input}
          />
        </box>
      </box>
      <box class="height-1 bg-panel overflow-hidden">
        <.keybinding_bar keybindings={@breeze.keybindings}/>
      </box>
      <box :if={@show_debug} style="fixed right-0 bottom-0 width-42 height-24">
        <live id="debug" view={Breeze.Debug} start_opts={[width: 42, height: 24]}>
        </live>
      </box>
    </box>
    """
  end

  def handle_event("select_console", %{value: value}, term) do
    {:noreply, assign(term, selected_console: value)}
  end

  def handle_event("vterm_input", %{input: input}, term) do
    console_id = term.assigns |> current_console() |> Map.fetch!(:id)

    {:noreply,
     update_console(term, console_id, fn console ->
       console
       |> send_shell_input(input)
       |> track_shell_input(input)
     end), invalidate: false}
  end

  def handle_event(_, %{"key" => "F2"}, term),
    do: {:noreply, assign(term, show_debug: !term.assigns.show_debug)}

  def handle_event(_, _, term), do: {:noreply, term}

  def handle_info({:vterm_output, console_id, bytes}, term) do
    {:noreply, buffer_shell_output(term, console_id, bytes), invalidate: false}
  end

  def handle_info(:flush_vterm_output, term) do
    if map_size(term.assigns.pending_outputs) == 0 do
      {:noreply, assign(term, output_flush_ref: nil), invalidate: false}
    else
      {:noreply, flush_shell_output(term)}
    end
  end

  def handle_info({:vterm_exit, console_id, status}, term) do
    term = flush_shell_output(term)

    {:noreply,
     update_console(term, console_id, fn console ->
       surface =
         console.surface
         |> VTerm.write("\r\n")
         |> VTerm.write("\e[31mlocal shell exited with status #{inspect(status)}\e[0m\r\n")

       %{console | shell: nil, surface: surface}
     end)}
  end

  def handle_info(:resize, term) do
    term = flush_shell_output(term)
    size = terminal_size(term)

    {:noreply,
     update_consoles(term, fn console ->
       if is_pid(console.shell) do
         case LocalShell.resize(console.shell, size.cols, size.rows) do
           :ok -> :ok
           {:error, reason} -> Logger.warning("Could not resize local PTY: #{inspect(reason)}")
         end
       end

       %{console | surface: VTerm.resize(console.surface, size.cols, size.rows)}
     end)}
  end

  def handle_info(_, term), do: {:noreply, term}

  defp new_console(spec, terminal_size, opts, colors) do
    console =
      spec
      |> Map.put(:status_label, status_label(spec.status))
      |> Map.put(:status_class, status_class(spec.status))
      |> Map.put(:surface, initial_surface(spec, terminal_size, colors))

    if Keyword.get(opts, :start_shells, true) do
      start_console_shell(console, spec, terminal_size, opts)
    else
      console
      |> Map.put(:shell, nil)
      |> Map.put(:command, "")
      |> Map.put(:shell_busy?, true)
      |> Map.put(:prompt_cursor, nil)
    end
  end

  defp start_console_shell(console, spec, terminal_size, opts) do
    case LocalShell.start(
           id: spec.id,
           owner: self(),
           cols: terminal_size.cols,
           rows: terminal_size.rows,
           cwd: Keyword.get(opts, :cwd, File.cwd!())
         ) do
      {:ok, shell} ->
        console
        |> Map.put(:shell, shell)
        |> Map.update!(
          :surface,
          &%{&1 | on_reply: fn bytes -> LocalShell.write(shell, bytes) end}
        )
        |> Map.put(:command, "")
        |> Map.put(:shell_busy?, true)
        |> Map.put(:prompt_cursor, nil)

      {:error, reason} ->
        console
        |> Map.put(:shell, nil)
        |> Map.update!(:surface, fn surface ->
          VTerm.write(surface, "\e[31mcould not start local shell: #{inspect(reason)}\e[0m\r\n")
        end)
    end
  end

  defp current_console(%{consoles: consoles, selected_console: selected_console}) do
    Enum.find(consoles, &(&1.id == selected_console)) || hd(consoles)
  end

  defp update_console(term, console_id, fun) do
    consoles =
      Enum.map(term.assigns.consoles, fn console ->
        if console.id == console_id, do: fun.(console), else: console
      end)

    assign(term, consoles: consoles)
  end

  defp update_consoles(term, fun) do
    assign(term, consoles: Enum.map(term.assigns.consoles, fun))
  end

  defp buffer_shell_output(term, console_id, bytes) do
    pending_outputs =
      term.assigns.pending_outputs
      |> Map.update(console_id, [bytes], fn chunks -> [bytes | chunks] end)

    term
    |> assign(pending_outputs: pending_outputs)
    |> schedule_output_flush()
  end

  defp schedule_output_flush(%{assigns: %{output_flush_ref: ref}} = term) when is_reference(ref),
    do: term

  defp schedule_output_flush(term) do
    ref = Process.send_after(self(), :flush_vterm_output, @output_flush_ms)
    assign(term, output_flush_ref: ref)
  end

  defp flush_shell_output(term) do
    pending_outputs = Map.get(term.assigns, :pending_outputs, %{})

    term =
      term
      |> cancel_output_flush()
      |> assign(pending_outputs: %{}, output_flush_ref: nil)

    Enum.reduce(pending_outputs, term, fn {console_id, chunks}, acc ->
      bytes =
        chunks
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      update_console(acc, console_id, fn console ->
        console
        |> Map.update!(:surface, &VTerm.write(&1, bytes))
        |> track_shell_output(bytes)
      end)
    end)
  end

  defp cancel_output_flush(%{assigns: %{output_flush_ref: ref}} = term) when is_reference(ref) do
    Process.cancel_timer(ref)
    term
  end

  defp cancel_output_flush(term), do: term

  defp query_colors(theme) do
    theme = Breeze.Theme.new(theme)

    Enum.flat_map([:foreground_color, :background_color], fn key ->
      color = Breeze.Theme.color(theme, key)
      color = if is_integer(color), do: Map.get(theme.terminal_palette || %{}, color), else: color

      case color do
        {_, _, _} -> [{key, color}]
        _ -> []
      end
    end)
  end

  defp initial_surface(console, terminal_size, colors) do
    VTerm.new([cols: terminal_size.cols, rows: terminal_size.rows] ++ colors)
    |> VTerm.write("\e[36m#{console.name}\e[0m connected to local PTY for #{console.host}\r\n")
    |> VTerm.write("Role: #{console.role}  Status: #{console.status}\r\n")
    |> VTerm.write(
      "Click the console list to change focus. F10 quits Breeze. Ctrl-C and Tab go to the shell.\r\n\r\n"
    )
  end

  def quit_empty_shell(_event, term) do
    if term.assigns |> current_console() |> shell_idle_empty?() do
      {:stop, term}
    else
      {:noreply, term}
    end
  end

  defp send_shell_input(%{shell: shell} = console, input) when is_pid(shell) do
    LocalShell.write(shell, input)
    console
  end

  defp send_shell_input(console, _input), do: console

  defp track_shell_input(console, "\r") do
    console
    |> Map.put(:command, "")
    |> Map.put(:shell_busy?, String.trim(Map.get(console, :command, "")) != "")
  end

  defp track_shell_input(console, "\x03") do
    console
    |> Map.put(:command, "")
    |> Map.put(:shell_busy?, true)
  end

  defp track_shell_input(console, "\x7f") do
    command =
      console
      |> Map.get(:command, "")
      |> String.graphemes()
      |> Enum.drop(-1)
      |> Enum.join()

    Map.put(console, :command, command)
  end

  defp track_shell_input(console, input) when is_binary(input) do
    if printable_shell_input?(input) do
      Map.update(console, :command, input, &(&1 <> input))
    else
      console
    end
  end

  defp track_shell_input(console, _input), do: console

  defp track_shell_output(%{surface: surface} = console, bytes) do
    if shell_prompt_output?(bytes) do
      console
      |> Map.put(:command, "")
      |> Map.put(:shell_busy?, false)
      |> Map.put(:prompt_cursor, surface.cursor)
    else
      console
    end
  end

  defp capture_shell_input?(console), do: not shell_idle_empty?(console)

  defp boolean_attr(false), do: "false"
  defp boolean_attr(_value), do: "true"

  defp base_keybindings do
    [
      {"F2", "Debug"},
      {"F10", "Quit"}
    ]
  end

  defp shell_idle_empty?(
         %{shell_busy?: false, command: "", prompt_cursor: prompt_cursor} = console
       )
       when is_map(prompt_cursor) do
    console.surface.cursor == prompt_cursor
  end

  defp shell_idle_empty?(_console), do: false

  defp printable_shell_input?(input) do
    input != "" and
      String.printable?(input) and
      Enum.all?(String.graphemes(input), fn grapheme ->
        grapheme not in ["\n", "\r", "\t", "\v", "\f"] and
          not String.match?(grapheme, ~r/[\x00-\x1F\x7F]/u)
      end)
  end

  defp shell_prompt_output?(bytes) do
    bytes
    |> strip_terminal_controls()
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.any?(&prompt_line?/1)
  end

  defp prompt_line?(line) do
    line
    |> String.trim_trailing()
    |> String.ends_with?(["$", "#", "%", ">", "\u276f", "\u276e", "\u279c"])
  end

  defp strip_terminal_controls(bytes) do
    if String.valid?(bytes) do
      bytes
      |> String.replace(~r/\e\][^\a]*(?:\a|\e\\)/, "")
      |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    else
      ""
    end
  end

  defp status_label("online"), do: "ok"
  defp status_label("idle"), do: "--"
  defp status_label("degraded"), do: "!!"
  defp status_label(_status), do: "??"

  defp status_class("online"), do: "width-8 text-success overflow-hidden"
  defp status_class("idle"), do: "width-8 text-muted overflow-hidden"
  defp status_class("degraded"), do: "width-8 text-warning overflow-hidden"
  defp status_class(_status), do: "width-8 text-accent overflow-hidden"

  defp terminal_size(term) do
    size = term.terminal.size

    %{
      cols: max(size.width - terminal_reserved_cols(), @terminal_min_cols),
      rows: max(size.height - terminal_reserved_rows(), @terminal_min_rows)
    }
  end

  defp terminal_reserved_cols do
    @sidebar_width + @terminal_border_cols
  end

  defp terminal_reserved_rows do
    @main_header_rows + @footer_rows + @terminal_border_rows
  end

  def child_process_flags, do: @child_process_flags
end

unless System.get_env("BREEZE_VTERM_SKIP_RUN") in ["1", "true", "TRUE"] do
  Breeze.Example.run(
    [
      view: VTermExample,
      alt_screen: true,
      hide_cursor: true,
      mouse: true,
      child_process_flags: VTermExample.child_process_flags(),
      reload: [paths: ["lib", "examples"]],
      global_keybindings: [{"F10", "Quit", fn _event, term -> {:stop, term} end}]
    ],
    keep_alive: :infinity
  )
end

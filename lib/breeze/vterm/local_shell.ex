defmodule Breeze.VTerm.LocalShell do
  @moduledoc """
  Local PTY-backed shell transport for VTerm demos.

  This module intentionally stays outside the VTerm surface model. It owns a
  local process and relays bytes between that process and an owner process.

  Output is delivered as `{:vterm_output, id, bytes}` without acknowledgments
  or output limits. The owner must process output promptly; a noisy process or
  slow consumer can cause unbounded mailbox growth.
  """

  use GenServer

  defstruct [:id, :owner, :owner_ref, :port]

  @type output_message :: {:vterm_output, term(), binary()}
  @type exit_message :: {:vterm_exit, term(), non_neg_integer()}

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, Keyword.put_new(opts, :owner, self()))

  @spec write(GenServer.server(), binary()) :: :ok
  def write(pid, bytes) when is_binary(bytes), do: GenServer.cast(pid, {:write, bytes})

  @doc "Resizes the Linux PTY and notifies its foreground process through SIGWINCH."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(pid, cols, rows)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0,
      do: GenServer.call(pid, {:resize, cols, rows})

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    id = Keyword.get(opts, :id, make_ref())
    cols = positive_int(Keyword.get(opts, :cols), 80)
    rows = positive_int(Keyword.get(opts, :rows), 24)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    shell = Keyword.get(opts, :shell, System.get_env("SHELL") || "/bin/sh")

    with {:ok, script} <- find_script(),
         {:ok, port} <- open_script_port(script, shell, cols, rows, cwd) do
      {:ok,
       %__MODULE__{
         id: id,
         owner: owner,
         owner_ref: Process.monitor(owner),
         port: port
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:resize, cols, rows}, _from, %{port: port} = state) do
    result =
      with {:ok, device} <- pty_device(port),
           stty when is_binary(stty) <- System.find_executable("stty") do
        case System.cmd(stty, ["-F", device, "cols", to_string(cols), "rows", to_string(rows)],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:stty_failed, String.trim(output)}}
        end
      else
        nil -> {:error, :stty_not_found}
        error -> error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:write, bytes}, %{port: port} = state) when is_binary(bytes) do
    if Port.info(port), do: Port.command(port, bytes)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    send(state.owner, {:vterm_output, state.id, data})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:vterm_exit, state.id, status})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp find_script do
    case System.find_executable("script") do
      nil -> {:error, :script_not_found}
      path -> {:ok, path}
    end
  end

  # Match the slave to script's master PTY. An inherited stderr may point at the
  # parent terminal, so choosing the first /dev/pts descriptor resizes the wrong PTY.
  defp pty_device(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        descriptors = Path.wildcard("/proc/#{pid}/fd/*")

        index =
          Enum.find_value(descriptors, fn path ->
            with {:ok, info} <- File.read("/proc/#{pid}/fdinfo/#{Path.basename(path)}"),
                 [_, index] <- Regex.run(~r/^tty-index:\s*(\d+)$/m, info) do
              index
            else
              _ -> nil
            end
          end)

        device =
          if index do
            Enum.find(descriptors, fn path ->
              File.read_link(path) == {:ok, "/dev/pts/#{index}"}
            end)
          end

        if device, do: {:ok, device}, else: {:error, :pty_not_found}

      nil ->
        {:error, :shell_closed}
    end
  end

  defp pty_device(_port), do: {:error, :shell_closed}

  defp open_script_port(script, shell, cols, rows, cwd) do
    command = shell_command(shell, cols, rows)

    port =
      Port.open(
        {:spawn_executable, script},
        [
          :binary,
          :exit_status,
          {:args, ["-q", "-f", "-c", command, "/dev/null"]},
          {:cd, cwd},
          {:env,
           [
             {~c"TERM", ~c"xterm-256color"},
             {~c"COLUMNS", String.to_charlist(Integer.to_string(cols))},
             {~c"LINES", String.to_charlist(Integer.to_string(rows))}
           ]}
        ]
      )

    {:ok, port}
  rescue
    ArgumentError -> {:error, :script_open_failed}
    ErlangError -> {:error, :script_open_failed}
  end

  defp shell_command(shell, cols, rows) do
    [
      "export TERM=xterm-256color COLUMNS=#{cols} LINES=#{rows}",
      "stty cols #{cols} rows #{rows} 2>/dev/null || true",
      "exec #{shell_escape(shell)} -i"
    ]
    |> Enum.join("; ")
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end

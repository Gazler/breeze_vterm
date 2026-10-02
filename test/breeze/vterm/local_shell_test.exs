defmodule Breeze.VTerm.LocalShellTest do
  use ExUnit.Case, async: true

  alias Breeze.VTerm.LocalShell
  alias Breeze.VTerm.Surface

  @moduletag skip:
               :os.type() != {:unix, :linux} or is_nil(System.find_executable("script")) or
                 is_nil(System.find_executable("stty"))

  test "delivers repeated output without acknowledgments or a cumulative byte limit" do
    {:ok, shell} = LocalShell.start(id: :resize_test, shell: "/bin/sh")

    LocalShell.write(shell, "stty -echo; printf '\\nREADY\\n'; exec cat\n")
    await_output("\r\nREADY\r\n")

    # Exact chunks exercise the protocol independently of OS pipe chunking.
    port = :sys.get_state(shell).port
    chunk = String.duplicate("x", 1024)

    for _ <- 1..256 do
      send(shell, {port, {:data, chunk}})
      assert_receive {:vterm_output, :resize_test, ^chunk}, 1000
    end

    assert Process.alive?(shell)
    GenServer.stop(shell)
  end

  test "the default owner is the caller and its death closes the transport" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, shell} = LocalShell.start(shell: "/bin/sh")
        send(parent, {:shell, shell})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:shell, shell}, 1000
    monitor = Process.monitor(shell)
    send(owner, :done)
    assert_receive {:DOWN, ^monitor, :process, ^shell, :normal}, 1000
  end

  test "a program waiting for color and cursor queries receives both replies through its PTY" do
    {:ok, shell} = LocalShell.start(id: :resize_test, shell: "/bin/sh")
    LocalShell.write(shell, "stty -echo; printf '\\nREADY\\n'\n")
    await_output("\r\nREADY\r\n")

    expected = "\e]11;rgb:1e1e/1e1e/2e2e\a\e[1;1R"

    surface =
      Surface.new(
        background_color: {30, 30, 46},
        on_reply: &LocalShell.write(shell, &1)
      )

    # A noncanonical read with a one-second timeout models a querying program.
    LocalShell.write(
      shell,
      "stty -icanon min 0 time 10; printf '\\033[1;1H\\033]11;?\\007\\033[6n'; " <>
        "reply=$(dd bs=1 count=#{byte_size(expected)} 2>/dev/null); " <>
        "printf '\\nREPLY:%s\\n' \"$reply\"\n"
    )

    Surface.write(surface, await_output("\e]11;?\a\e[6n"))
    await_output("REPLY:" <> expected)
    GenServer.stop(shell)
  end

  test "resizes the PTY seen by a nested terminal application and sends SIGWINCH" do
    {:ok, shell} =
      LocalShell.start(owner: self(), id: :resize_test, shell: "/bin/sh", cols: 73, rows: 24)

    # Disable echo so command text cannot be mistaken for its output.
    LocalShell.write(shell, "stty -echo; printf '\\nREADY\\n'\n")
    await_output("\r\nREADY\r\n")
    LocalShell.write(shell, "stty size\n")
    await_output("24 73\r\n")

    # A foreground process must be notified without requiring shell input.
    LocalShell.write(shell, "trap 'printf RESIZED:; stty size' WINCH\n")
    LocalShell.write(shell, "printf '\\nARMED\\n'\n")
    await_output("\r\nARMED\r\n")
    assert :ok = LocalShell.resize(shell, 123, 60)
    await_output("RESIZED:60 123\r\n")

    # Wait for the first trap to return before delivering a second SIGWINCH.
    LocalShell.write(shell, "printf '\\nRESIZE_READY\\n'\n")
    await_output("\r\nRESIZE_READY\r\n")
    assert :ok = LocalShell.resize(shell, 90, 30)
    await_output("RESIZED:30 90\r\n")

    LocalShell.write(shell, "elixir -e 'IO.inspect({:io.columns(), :io.rows()})'\n")
    await_output("{{:ok, 90}, {:ok, 30}}")
    GenServer.stop(shell)
  end

  test "resizing a running nested example does not resize its parent PTY" do
    {:ok, shell} =
      LocalShell.start(owner: self(), id: :resize_test, shell: "/bin/sh", cols: 123, rows: 40)

    LocalShell.write(
      shell,
      "SHELL=/bin/sh MIX_ENV=test mix run --no-compile --no-deps-check examples/vterm.exs\n"
    )

    surface =
      Surface.new(cols: 123, rows: 40)
      |> Surface.write(await_frame())

    assert_frame_size(surface, 123, 40)

    Enum.reduce([{90, 30}, {140, 45}, {100, 32}], surface, fn {cols, rows}, surface ->
      assert :ok = LocalShell.resize(shell, cols, rows)

      surface = surface |> Surface.resize(cols, rows) |> Surface.write(await_frame())
      assert_frame_size(surface, cols, rows)
      surface
    end)

    GenServer.stop(shell)
  end

  defp assert_frame_size(surface, cols, rows) do
    assert surface.alt_screen?
    assert surface.scrollback_count == 0
    lines = Surface.lines(surface)
    assert Enum.at(lines, 0) =~ "fra-web-01"
    assert String.at(Enum.at(lines, 1), cols - 1) == "┐"
    assert String.at(Enum.at(lines, rows - 2), cols - 1) == "┘"
    assert Enum.at(lines, rows - 1) =~ "F10 Quit"
  end

  defp await_frame do
    output = await_output("F10")
    collect_frame(output, System.monotonic_time(:millisecond) + 5000)
  end

  # Wait for the redraw to settle: the regression initially drew at the right size
  # before further SIGWINCH events repeatedly shrank the parent terminal.
  defp collect_frame(output, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "nested redraw did not settle"

    receive do
      {:vterm_output, :resize_test, bytes} ->
        collect_frame(output <> bytes, deadline)

      {:vterm_exit, :resize_test, status} ->
        flunk("nested example exited with #{status}")
    after
      50 -> output
    end
  end

  defp await_output(expected) do
    deadline = System.monotonic_time(:millisecond) + 5000
    await_output(expected, "", deadline)
  end

  defp await_output(expected, output, deadline) do
    if String.contains?(output, expected) do
      output
    else
      receive do
        {:vterm_output, :resize_test, bytes} ->
          await_output(expected, output <> bytes, deadline)

        {:vterm_exit, :resize_test, status} ->
          flunk("shell exited with #{status}: #{inspect(output)}")
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("expected #{inspect(expected)} in shell output: #{inspect(output)}")
      end
    end
  end
end

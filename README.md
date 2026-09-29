# Breeze VTerm

Virtual terminal components for Breeze applications.

Requires Elixir 1.18 or newer and Breeze 0.5.3.

## Using a Surface

```elixir
surface = Breeze.VTerm.new(cols: 80, rows: 24, scrollback_limit: 10_000)
surface = Breeze.VTerm.write(surface, "hello\r\n")
```

Import `Breeze.VTerm.Components` in a Breeze view and render the assigned surface:

```heex
<.terminal id="console" surface={@surface} br-change="console_input" />
```

The change event contains `%{input: bytes, event: event}`. Forward `bytes` to your
transport and feed its output back through `Breeze.VTerm.write/2`. The component
provides scrolling and a cursor overlay; the application owns the transport and
surface updates. Use `Breeze.VTerm.resize/3` when the content dimensions change.

This is a small terminal model, not a complete xterm emulator. It supports basic
cursor movement, erasing, SGR colors, alternate screens, and bounded scrollback.
Unsupported control sequences are ignored. Applications requiring full-screen
terminal compatibility should validate their command set before adopting it.

## Running the Example

Fetch dependencies, then run the bundled example:

```sh
mix deps.get
mix run examples/vterm.exs
```

The example opens a Breeze UI with a console list on the left and a local
PTY-backed shell on the right. Use the console list to switch focus between
hosts. When the shell is focused, regular input goes to the shell.

Useful keys:

- `F10` quits the example.
- `PageUp` and `PageDown` scroll the terminal buffer.
- Breeze handles `Ctrl-C` and `Tab` only when the focused shell prompt is
  empty. `Ctrl-C` quits the app in that state, and `Tab` changes Breeze focus.
- When the prompt is not empty, or a command is running, `Ctrl-C` and `Tab` are
  sent to the shell instead.

The local shell transport uses the system `script` executable to create a PTY.
If the example cannot start a local shell, make sure `script` is installed and
available on `PATH`.

The demo transport requires Linux, util-linux `script` and `stty`, and `/proc`.
The example keeps the shell's PTY size in sync with its surface when the window
resizes, including notifying nested terminal applications. Applications using
`LocalShell` directly should call `LocalShell.resize/3` alongside surface resizing.

## Output Handling

The surface buffers incomplete UTF-8 codepoints (at most three bytes) and discards
malformed bytes. OSC payloads are discarded incrementally. CSI parameter data is
limited to 256 bytes; overlong sequences are ignored through their final byte.

`LocalShell` sends `{:vterm_output, id, bytes}`. Process the bytes directly:

```elixir
def handle_info({:vterm_output, _id, bytes}, surface) do
  {:noreply, Breeze.VTerm.write(surface, bytes)}
end
```

Local shell output currently has no backpressure or output limits. A noisy
process or slow consumer can cause unbounded mailbox or batch-buffer growth.
Consumers should process output promptly and bound any buffering they introduce.

`LocalShell` does not sandbox shell commands. `LocalShell` runs with the host
application's OS permissions and inherited environment. Applications must control
who can send shell input and apply any required OS isolation separately.

## Development

```sh
mix test
mix run bench/surface_benchmark.exs
ITERATIONS=30 PREFILL_LINES=2000 mix run bench/vterm_benchmark.exs
```

The surface benchmark reports median time and reductions over five samples for
prompt editing, styled output, and bulk output. The full benchmark also measures
Breeze layout and rendering, using the demo without starting shell processes.

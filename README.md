# Breeze VTerm

Virtual terminal components for Breeze applications.

Requires Elixir 1.18 or newer. Breeze is pinned in `mix.lock` to the
[`master` branch](https://github.com/Gazler/breeze/tree/master),
which provides the custom frame renderer hook and compact animation snapshots.
The example enables the optimized renderer directly. See the
[frame renderer setup](#experimental-cell-diff-frame-renderer) to enable it in
your application.

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

Text selection is opt-in:

```heex
<.terminal id="console" surface={@surface} selectable br-change="console_input" />
```

Enable Breeze mouse reporting with `mouse: [mode: :drag]`. Left-drag selects text.
Each mouse movement at the top or bottom edge scrolls one row. To continue
scrolling while the pointer is held at an edge, opt in on the component:

```heex
<.terminal id="console" surface={@surface} selectable selection_autoscroll br-change="console_input" />
```

Forward its timer messages through the owning view's existing callback:

```elixir
def handle_info({Breeze.VTerm, :edge_scroll, _, _} = message, term),
  do: Breeze.VTerm.handle_info(message, term)
```

This uses ordinary process timers and `Breeze.View.update_implicit/3`; it needs
no additional Breeze timer API or implicit message callback. The example includes
both the opt-in and message forwarding. Each tick advances after 50 ms, starting
at one row and increasing to two after 400 ms and three after 800 ms
(20–60 rows/second, subject to render time). Moving inside, releasing, cancelling,
losing focus, changing viewport geometry, or reaching the buffer boundary stops
the timer. Removed terminals and stale messages do not request a render.
Breeze's focus fix invokes the existing `blur/1` handler when an asynchronous
view message changes focus. Without it, that path releases mouse capture but
leaves the timer active.
Right-clicking a selection emits
`%{copy: text}` through `br-change` for the host to write to the clipboard.
Selection also emits `%{selection: :start}` and `%{selection: :clear}` so the host
can route keys through Breeze while selecting.
Typing, Escape, new output, resizing, or disabling `selectable` clears the selection.

The terminal core is pure Elixir, with selected parser and terminal-state behavior
ported from [libvterm 0.3.3](https://www.leonerd.org.uk/code/libvterm/). There is no
NIF or native runtime dependency. Attribution and the upstream MIT license are in
[bench/THIRD_PARTY_NOTICES](bench/THIRD_PARTY_NOTICES).

The port covers streaming ESC/CSI parsing, control-string consumption, delayed
wrapping and DECAWM, origin mode and scrolling margins, configurable tab stops,
cursor/pen save and restore, newline mode, color-preserving erasure, and character
and line editing. SGR supports indexed/RGB colors, bold, italic, and inverse.
The component honors cursor visibility and application cursor-key mode. Alternate
screens and bounded scrollback remain available.

Use `Breeze.VTerm.input(surface, event)` when encoding keys directly, so arrows,
Home, and End honor application cursor mode. The component does this automatically;
`input(event)` remains available for stateless encoding.

This is a selected subset, not full libvterm/xterm compatibility. Legacy
character sets, mouse reporting to child applications, graphics,
and complete Unicode grapheme handling are outside this port. Unsupported
commands are ignored. Existing alternate-screen and resize policies are retained;
the comparison below does not establish parity for those operations.

### Terminal query replies

Programs such as `gh` query the terminal's background color and may pause until
their query times out if they receive no response. Pass an `:on_reply` callback
to send replies back as input to your transport:

```elixir
surface = Breeze.VTerm.new(
  cols: 80,
  rows: 24,
  on_reply: fn bytes -> Breeze.VTerm.LocalShell.write(shell, bytes) end,
  foreground_color: {205, 214, 244},
  background_color: {30, 30, 46}
)
```

`write/2` invokes the callback synchronously for each complete OSC 10 or OSC 11
query (`ESC ] 10 ; ?` or `ESC ] 11 ; ?` followed by BEL or `ESC \`). Replies use
the query's terminator and RGB components expanded to four hexadecimal digits,
following the [xterm protocol](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
Queries can span output chunks. The callback's return value is ignored.

Cursor position queries (`ESC [ 6 n`) also receive a reply (`ESC [ row ; col R`),
using the surface's current one-based screen coordinates. Some programs send
this query after a color query and wait for both responses.

The color options describe the host's default colors for query replies; they do
not change rendered cell styles. Use the host's theme or probed colors when
available. The fallback is a light foreground `{229, 229, 229}` on black
`{0, 0, 0}`. The local-shell example enables replies automatically.

Replies are disabled unless `:on_reply` is set. When adopting this callback in an
application that already answers color queries, remove its separate responder
to avoid sending duplicate replies. Other terminal queries remain unsupported.

## Running the Example

Fetch dependencies, then run the bundled example:

```sh
mix deps.get
mix run examples/vterm.exs
```

The example opens a Breeze UI with a console list on the left and a local
PTY-backed shell on the right. Use the console list to switch focus between
hosts. When the shell is focused, regular input goes to the shell.

Drag in the terminal pane to select text, including scrolling at either edge.
Right-click the selection to copy it using the terminal's OSC 52 clipboard support.
Escape or typing clears the selection.

Useful keys:

- `F10` quits the example.
- `PageUp` and `PageDown` scroll the terminal buffer.
- Breeze handles `Ctrl-C` and `Tab` only when the focused shell prompt is
  empty and no text is selected. `Ctrl-C` quits the app in that state, and `Tab`
  changes Breeze focus.
- When the prompt is not empty, a command is running, or text is selected,
  `Ctrl-C` and `Tab` are sent to the shell instead.

The local shell transport uses the system `script` executable to create a PTY.
If the example cannot start a local shell, make sure `script` is installed and
available on `PATH`.

The demo transport requires Linux, util-linux `script` and `stty`, and `/proc`.
The example keeps the shell's PTY size in sync with its surface when the window
resizes, including notifying nested terminal applications. Applications using
`LocalShell` directly should call `LocalShell.resize/3` alongside surface resizing.

## Output Handling

The surface buffers incomplete UTF-8 codepoints (at most three bytes) and discards
malformed bytes. OSC parsing retains at most four bytes to recognize supported
color queries; other OSC/DCS/APC/PM/SOS payloads are discarded incrementally.
ESC intermediates and CSI sequence data are limited to 256 bytes; overlong
sequences are ignored through their final byte.

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

### Comparing with libvterm

The optional reference harness compiles libvterm 0.3.3 as a separate executable.
It compares text, supported styles, and cursor position for the shared fixtures,
feeding both complete streams and individual bytes. Regular `mix test` exercises
the port without requiring C, and checks every two-part split of those fixtures.

Download and unpack the [0.3.3 source release](https://www.leonerd.org.uk/code/libvterm/libvterm-0.3.3.tar.gz),
then run with a C compiler available:

```sh
LIBVTERM_SRC=/path/to/libvterm-0.3.3 mix run bench/libvterm_benchmark.exs
LIBVTERM_SRC=/path/to/libvterm-0.3.3 CHECK_ONLY=1 mix run bench/libvterm_benchmark.exs
BASELINE_REF=3eadd33 LIBVTERM_SRC=/path/to/libvterm-0.3.3 SAMPLES=7 mix run bench/libvterm_benchmark.exs
```

The timing comparison uses identical streams and dimensions with scrollback
disabled on both sides. It reports median time per write over five samples, and
checks the final screens of the repeated workloads outside the timed region.
Compilation, process startup, construction, file I/O, and snapshot extraction are
excluded. This measures parsing and screen updates; Breeze rendering, selection,
PTY transport, and any prospective NIF/Port integration overhead are excluded.
The two implementations retain their own screen representations, so results are
workload-dependent and are not a general comparison of language speed.

Defaults are `SIZES=120x40,400x120`, `ITERATIONS=10000` for short writes,
100 iterations for full-screen repainting, 10 for bulk output, and `SAMPLES=5`.
Override `CC` to select the compiler. C is built with `-O2`.

Intentional differences from the reference include bounded parsing, discarding
malformed UTF-8 instead of emitting replacement characters, and correctly handling
the omitted color-space field in `38:2::r:g:b` (misread by libvterm 0.3.3).

Before/after measurements on an Intel Core Ultra X7 358H, Elixir 1.20.4 / OTP 29,
GCC 16.2.1 `-O2` (2026-10-13, seven samples; microseconds per write).
These recorded measurements used the original pre-port selection sources from
`f9acdcd008588c73a2af99d450b27f38f635452d`. The benchmark now defaults to the
rebased selection commit `3eadd338b8dc36d021e4e3a84f1443c475588cc5`, which also
includes terminal query replies. Its Surface is compiled into a separate namespace
using the same current dependencies. Before/after timing order alternates by
sample; both versions must produce the same final cells for each workload.

| Size | Workload | Bytes/write | Before | After | libvterm C |
| --- | --- | ---: | ---: | ---: | ---: |
| 120×40 | Prompt editing | 4 | 0.629 | 0.909 | 0.056 |
| 120×40 | Styled scrolling line | 22 | 2.663 | 3.432 | 2.393 |
| 120×40 | Full-screen repaint | 4,803 | 195.17 | 179.91 | 62.87 |
| 120×40 | Bulk scrolling | 120,000 | 7,400.70 | 6,713.00 | 3,408.93 |
| 400×120 | Prompt editing | 4 | 2.471 | 2.966 | 0.053 |
| 400×120 | Styled scrolling line | 22 | 20.780 | 22.492 | 24.376 |
| 400×120 | Full-screen repaint | 48,003 | 2,773.76 | 2,166.83 | 434.31 |
| 400×120 | Bulk scrolling | 400,000 | 34,676.70 | 23,536.80 | 27,603.29 |

These are local observations, not performance guarantees. The shared conformance
suite currently checks 34 streams in both chunkings; it is not a full libvterm
conformance suite.

### Experimental cell-diff frame renderer

`Breeze.VTerm.Frame` now composes base text, selection and cursor overlays before
comparing cells. It sends changed spans, keeps wide glyph boundaries intact, and
preserves the original writer's final cursor and delayed-wrap state. Supported
SGR sequences are retained verbatim, including attributes outside Surface's
smaller terminal model. Repeated row transitions use BackBreeze's bounded render
cache. Identical frames return immediately.

Initial paints, complex graphemes, control strings, clipped overlays, overlays
that split a wide glyph, and other unsupported cases use the existing writer.
The renderer also keeps the existing payload whenever the candidate is larger.
Short vertical shifts can use terminal scrolling commands, followed by repairs
to exposed rows, highlights and surrounding UI. The smallest supported payload
wins. Output styling is not retained between frames. This remains an opt-in
experiment for applications, with a server CPU/bandwidth tradeoff. The included
example enables it by default.

The integration belongs before the terminal adapter writes to SSH. Breeze's
per-session `:frame_renderer` option handles complete frames and live child
updates. Breeze master includes the custom frame renderer hook, compact
snapshots and asynchronous focus changes. The configured Git dependency pins
these capabilities; the unmodified 0.5.5 release does not include them:

```elixir
{:breeze, git: "https://github.com/Gazler/breeze.git", branch: "master"}
```

```sh
mix deps.get
mix deps.compile breeze
mix run examples/vterm.exs
```

Compact snapshots improve scrolling with either frame writer. Keep the
application's existing SSH terminal adapter and add the renderer option:

```elixir
Breeze.Server.start_link(
  view: MyApp.View,
  terminal: ssh_terminal,
  frame_renderer: Breeze.VTerm.Frame
)
```

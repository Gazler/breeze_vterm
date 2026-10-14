# Breeze VTerm

Virtual terminal components for Breeze applications.

Requires Elixir 1.18 or newer. Breeze is pinned in `mix.lock` to the
[`perf/scroll-patches` branch](https://github.com/Gazler/breeze/tree/perf/scroll-patches),
which provides the frame renderer and compact animation snapshots.
See the [frame renderer setup](#experimental-cell-diff-frame-renderer) to enable
the optional renderer.

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
`THIRD_PARTY_NOTICES`.

The port covers streaming ESC/CSI parsing, control-string consumption, delayed
wrapping and DECAWM, origin mode and scrolling margins, configurable tab stops,
cursor/pen save and restore, newline mode, color-preserving erasure, and character
and line editing. SGR supports indexed/RGB colors, bold, italic, and inverse.
The component honors cursor visibility and application cursor-key mode. Alternate
screens and bounded scrollback remain available.

Use `Breeze.VTerm.input(surface, event)` when encoding keys directly, so arrows,
Home, and End honor application cursor mode. The component does this automatically;
`input(event)` remains available for stateless encoding.

This is a selected subset, not full libvterm/xterm compatibility. Terminal query
replies, legacy character sets, mouse reporting to child applications, graphics,
and complete Unicode grapheme handling are outside this port. Unsupported
commands are ignored. Existing alternate-screen and resize policies are retained;
the comparison below does not establish parity for those operations.

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
malformed bytes. Unsupported OSC/DCS/APC/PM/SOS payloads are consumed incrementally
without retaining their contents. ESC intermediates and CSI sequence data are
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
mix run bench/selection_benchmark.exs
mix run bench/transport_benchmark.exs
```

The surface benchmark reports median time and reductions over five samples for
prompt editing, styled output, and bulk output. The full benchmark also measures
Breeze layout and rendering, using the demo without starting shell processes.

The selection benchmark measures ANSI bytes from Breeze's frame writer for
selecting a viewport, extending or shrinking a selection, clearing it, and idle
frames. It covers plain, short, styled, and wide-character lines at sizes up to
400×120. Override sizes and timing samples with
`SIZES=270x100,400x120 ITERATIONS=20 mix run bench/selection_benchmark.exs`.
These are output payload sizes before transport framing or compression, with a
stationary viewport; scrolling and clipboard copying are excluded. Reported
60 fps bandwidth is a projection, not a measured event rate.

It also compares two plain-ASCII prototypes: inserting inverse markers into the
cached row and repainting only cells whose selection changed. Both are checked
against the current output for identical cells and styles. The prototypes are
confined to the benchmark; production selection rendering is unchanged.

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
BASELINE_REF=f9acdcd LIBVTERM_SRC=/path/to/libvterm-0.3.3 SAMPLES=7 mix run bench/libvterm_benchmark.exs
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
The baseline is commit `f9acdcd008588c73a2af99d450b27f38f635452d`, immediately
before the libvterm port. Its Surface is compiled into a separate namespace using
the same current dependencies. Before/after timing order alternates by sample;
both versions must produce the same final cells for each benchmark workload.

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

### Remote UI bandwidth before and after the port

`mix run bench/transport_benchmark.exs` measures the actual ANSI payload emitted
by Breeze's frame writer when the whole Breeze UI runs remotely. It loads the
baseline Surface, Selection, Implicit, and Components modules from commit
`f9acdcd` into a separate namespace, leaving the working tree intact. Override
`BASELINE_REF` to use another compatible revision. Dependencies and theme are
shared. The fixture is one full-width pane, with a static cursor and a steady
viewport. Explicit cursor placement keeps the old delayed-wrap bug from affecting
the comparison. Color-heavy rows alternate red and green every eight cells.

All 72 comparisons (three sizes × three text fixtures × eight actions) produce
the same byte counts before and after, and the emitted payloads are replayed to
verify equal visible cells and styles. Results for 400×120, in bytes:

| Action | Plain: before = after | Color-heavy: before = after | Wide: before = after |
| --- | ---: | ---: | ---: |
| Initial paint | 53,349 | 210,909 | 130,643 |
| Change one cell | 493 | 1,843 | 1,135 |
| Change all rows | 53,342 | 210,902 | 130,636 |
| Select full viewport | 108,156 | 562,452 | 209,448 |
| Extend selection one cell | 702 | 3,254 | 1,448 |
| Extend selection one row | 901 | 4,677 | 1,745 |
| Clear selection | 53,342 | 210,902 | 130,636 |
| Idle frame | 0 | 0 | 0 |

At 60 one-cell selection extensions per second, this projects to 41.13 KiB/s for
plain text or 190.66 KiB/s for the color-heavy fixture, before transport overhead.
These are measured application payloads, not captured SSH wire traffic. SSH adds
channel/packet framing, padding, authentication and network overhead; compression,
if enabled, changes the result. Cursor blinking, scrolling, clipboard copying,
connection setup and client-to-server input are excluded. There is no payload
reduction from this emulator port for these cases: the shared renderer still
repaints affected rows. The selection span prototypes above remain separate.

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
experiment with a server CPU/bandwidth tradeoff.

Every nonempty frame, including initial paints and fallback redraws, is enclosed
in synchronized-output markers (`CSI ? 2026 h` / `CSI ? 2026 l`). This lets
supporting terminals such as Ghostty display the scroll and its repairs together
instead of painting an intermediate state. Both markers travel with the completed
frame in the same adapter write; idle frames still send nothing. See
[Ghostty's synchronized-output guidance](https://ghostty.org/docs/help/synchronized-output).
This adds 16 ANSI bytes per frame before SSH overhead. The historical payload
tables below predate these markers; copied clipboard text is unchanged.

The integration belongs before the terminal adapter writes to SSH. Breeze's
per-session `:frame_renderer` option handles complete frames and live child
updates. The configured Git dependency includes the frame-renderer,
compact-snapshot and asynchronous focus changes. The unmodified 0.5.5 release
does not include them:

```elixir
{:breeze, git: "https://github.com/Gazler/breeze.git", branch: "perf/scroll-patches"}
```

```sh
mix deps.get
mix deps.compile breeze
BREEZE_VTERM_DIFF_FRAME=1 mix run examples/vterm.exs
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

Compare the same 72 before/after frame cases, now with the candidate renderer:

```sh
FRAME_RENDERER=diff mix run bench/transport_benchmark.exs
LIBVTERM_SRC=/path/to/libvterm-0.3.3 mix run bench/frame_oracle.exs
```

At 400×120, extending the half-viewport selection by one cell changes from
702 to 64 bytes for plain text, 3,254 to 56 for color-heavy text, and 1,448 to
124 for wide text. Selecting the entire viewport changes from 108,156 to 54,500
bytes for plain text and 562,452 to 223,822 for color-heavy text. Initial paint
and full replacement still use the original payload sizes in these fixtures.
Every comparison checks the resulting screen, styles, cursor and delayed wrap.
The separate C oracle checks 78 transitions with extended attributes; it compares
wide-glyph styles on their leading cell, since libvterm leaves stale pen data in
continuation cells. Each transition is also followed by a wrap/scroll probe to
check that subsequent output sees the expected cursor and scrolling margins.

Frame composition takes additional CPU. In a seven-sample warm-cache run on the
machine above, the half-viewport one-cell selection update took 0.086 → 0.196 ms
for plain text and 7.276 → 14.935 ms for the color-heavy fixture. These timings
exclude overlay generation and transport. Samples run in a separate process,
with GC before each timer, to avoid retaining benchmark screen snapshots in the
timed process. Cold transitions can be substantially slower; these measurements
do not justify enabling the renderer by default.

### Direct SSH verification

```sh
mix run bench/ssh_frame_benchmark.exs
SIZE=80x24 mix run bench/ssh_frame_benchmark.exs
```

This optional harness needs OTP's SSH application, `ssh-keygen`, and Breeze's
frame-renderer support. It starts a temporary listener bound to loopback, serves
a real Breeze UI through a direct SSH channel adapter, and sends mouse input
through the SSH client. There is no OS PTY or interactive shell between Breeze
and the SSH channel. A TCP relay counts encrypted SSH bytes; the client payload must exactly
match the server adapter's writes. Before/after screens and cursor state must
also match. Temporary host keys and listeners are cleaned up afterwards.

Measured at 400×120 with AES-256-GCM and compression disabled (2026-10-13):

| Action | Plain ANSI before → after | Plain SSH before → after | Color-heavy ANSI before → after | Color-heavy SSH before → after |
| --- | ---: | ---: | ---: | ---: |
| Change one cell | 493 → 96 | 532 → 132 | 1,843 → 96 | 1,892 → 132 |
| Extend selection one cell | 519 → 61 | 564 → 100 | 1,914 → 52 | 1,956 → 100 |
| Extend selection one row | 1,417 → 513 | 1,460 → 548 | 6,490 → 1,915 | 6,532 → 1,956 |
| Clear selection | 3,151 → 2,858 | 3,188 → 2,900 | 12,379 → 10,780 | 12,420 → 10,820 |

These are bytes per action. This live test selects from (1,1) to (20,6), extends
to (21,6), then to (21,7), so its selection differs from the half-viewport frame
benchmark. SSH counts include encryption, authentication, padding and SSH
framing in the server-to-client TCP payload. They exclude connection setup,
initial paint, client input, TCP/IP headers and retransmissions. Packet sizes
depend on the negotiated algorithms and write batching; 100 bytes is this
measurement, not a universal minimum.

### Scrolling while selecting over SSH

```sh
SCENARIO=scroll mix run bench/ssh_frame_benchmark.exs
SCENARIO=scroll SIZE=80x24 mix run bench/ssh_frame_benchmark.exs
SCENARIO=scroll BASELINE=cell TIMINGS=1 mix run bench/ssh_frame_benchmark.exs
SCENARIO=scroll BASELINE=cell LAYOUT=framed mix run bench/ssh_frame_benchmark.exs
FIXTURE=source SIZE=156x80 LAYOUT=framed SCENARIO=scroll mix run bench/ssh_frame_benchmark.exs
SCENARIO=hold SIZE=80x24 mix run bench/ssh_frame_benchmark.exs
SCENARIO=hold SIZE=156x80 LAYOUT=framed FIXTURE=source mix run bench/ssh_frame_benchmark.exs
```

This scenario fills three screens with distinct, dense rows, leaving two screens
of scrollback. It drags a selection toward each edge, scrolls three times in each
direction, and wheels both during the drag and after release. Copying happens
after scrolling the selection's first rows out of view. The harness verifies
absolute selection coordinates, unchanged anchors, release of mouse capture,
and the complete OSC 52 payload against the original fixture text. Every displayed
screen must also match a fresh full render and the other renderer. Frames that
produce output wait for their first write before the transport drain interval;
otherwise a slow render could be counted against the following event.

`SCENARIO=scroll` disables automatic edge scrolling to keep each measured input
at one row. `SCENARIO=hold` enables it: one drag reaches the top edge, then no more
mouse movement is sent until the buffer boundary stops the timer. It verifies
the unchanged anchor, final selection, display, and copied scrollback with both
writers. Its byte counts cover the whole hold, rather than a single frame.
On loopback SSH, the scroll writer traversed 48 rows at 80×24 in about 1.2 seconds
and 156 source-code rows at 156×80 in about 3.0 seconds, without further mouse
movement. At 400×120 it traversed 240 rows in about 4.5 seconds for plain text and
5.4 seconds for dense colored text. All holds passed the final display and copy
checks; larger frames can render more slowly than the timer's requested cadence.

`BASELINE=cell` disables only scrolling in the before renderer; the default
baseline is Breeze's row writer. `LAYOUT=framed` adds a 20-column sidebar and
one-row header/footer, making the vterm 380×118 in a 400×120 terminal. `TIMINGS=1`
also measures frame composition in isolated tasks: seven samples after a priming
render, with GC before each timer, excluding layout, overlay generation and SSH.
`FIXTURE=source` uses source-code rows, including blank lines and trailing space,
instead of dense text. The CSV also records microseconds from sending each input
to receiving its first output byte, excluding the drain interval. The loopback
proxy disables Nagle buffering. `PROFILE=1` profiles the first upward drag with
Erlang's eprof (and distorts its latency); `CAPTURE_DIR=/tmp/frames` saves selected
frame arguments and implicit states for local investigation.

Measured encrypted SSH bytes per action at 400×120, with the same AES-256-GCM,
uncompressed direct channel as above (2026-10-13):

| Action | Plain row → cell → scroll | Color-heavy row → cell → scroll |
| --- | ---: | ---: |
| First upward edge drag, one row | 81,096 → 81,096 → 1,092 | 389,464 → 323,332 → 3,908 |
| First downward edge drag, one row | 108,088 → 108,088 → 1,460 | 564,612 → 331,160 → 5,572 |
| Wheel up during drag, three rows | 80,184 → 80,184 → 1,828 | 384,136 → 320,228 → 5,892 |
| Copy 63 selected rows | 33,220 → 33,220 → 33,220 | 33,220 → 33,220 → 33,220 |

These are synthetic dense-content measurements, not a general traffic estimate.
The upward selection begins halfway down the viewport; the downward selection
covers nearly its full height. The two cases therefore have different costs.
The cell-only renderer compares fixed screen coordinates and still sends most
of the viewport. `Breeze.VTerm.Frame` now also detects matching base rows displaced
by up to eight lines. It considers the two best offsets, trying both the matched
region and an expansion through adjacent changed rows. This prevents scrollbar
arrows from forcing full-row repaints. It moves rows using
[DECSTBM and index/reverse-index](https://xtermjs.org/docs/api/vtfeatures/), then
compares the shifted cells and overlays against the desired frame. Selection
edges, scrollbar cells and displaced sidebar/popup content are repaired. It
resets styling before scrolling, restores full margins afterwards, and preserves
the original writer's final cursor and delayed wrap. The renderer assumes it
owns the complete terminal with normal origin mode and full margins between
frames, as Breeze's frame writer does.

The commands scroll the terminal's full width within the chosen vertical region.
The framed SSH scenario verifies that adjacent UI is repaired correctly:

| Framed layout action | Plain cell → scroll | Color-heavy cell → scroll |
| --- | ---: | ---: |
| First upward edge drag, one row | 83,048 → 1,508 | 304,036 → 4,212 |
| First downward edge drag, one row | 108,552 → 1,860 | 311,908 → 5,796 |
| Wheel up during drag, three rows | 82,184 → 2,404 | 302,036 → 6,292 |

Both 80×24 and 400×120 framed sessions passed screen, cursor and copy checks.
Detection is deliberately bounded and relies on exact matches of base rows;
larger jumps or independently changing adjacent panes may miss it. Those cases
still use cell diffs or the original writer. Unsupported content also retains
the existing fallback, and scrolling is discarded when its payload is larger.
For comparison, `Breeze.VTerm.Frame.build_payload/6` accepts `scroll: false`.

### Selection scroll latency

Profiling found two costs outside the SSH payload. Every render transferred the
complete surface in attributes, routing metadata and animation state between
Breeze processes: about 74 MB of expanded Erlang terms for the plain 400×120
fixture with three screens of content. Also, one overlay per colored style run
could repeatedly exhaust BackBreeze's 4,096-entry cache.

Breeze's compact-snapshot support adds the optional implicit callback
`animation_state/2`. VTerm sends visible selection runs and cursor flags as
animation state. Breeze itself projects compositor flags
to IDs, live-dimension markers and screen dimming; custom component attributes and
input routing remain in the view process. No attribute callback is required.

The view retains the complete surface for input handling and copying; inspector
snapshots retain full metadata. This currently applies to Breeze's compact root
snapshots; live child snapshots still use their existing path. The animation
callback preserves lightweight compositor ticks without copying the complete
buffer or calling a view that may be busy processing input.

Selection also caches highlights by exact row content and bounds, builds text
with iodata, reuses style codes, and combines adjacent style runs into at most
two overlays per contiguous row segment. The final run remains separate to
preserve the original physical cursor position. Cache keys distinguish edited
branches even when they have the same surface id/version.

Measured input-to-first-output latency over loopback SSH, with the scroll renderer
enabled both before and after these CPU changes (2026-10-13):

| Fixture | Median before | Median after | Samples per version |
| --- | ---: | ---: | ---: |
| Source text, 156×80 with sidebar/header/footer | 21.4 ms | 13.8 ms | 18 edge drags across three runs |
| Dense plain text, 400×120 | 160.9 ms | 34.5 ms | Six edge drags |
| Dense colored text, 400×120 | 392.6 ms | 66.1 ms | Six edge drags |

These compare the implementation before and after the selection/snapshot changes;
the harness's CSV before/after columns instead compare the row and scroll writers
on the current checkout. They include rendering and SSH, but exclude WAN latency
and client painting. They are isolated events, not sustained frame-rate results.
Large colored frames still take 55–104 ms in this run, so CPU remains a constraint.
Repeated frame composition alone fell from 58/88 ms to 4.4/5.0 ms for the first
colored upward/downward drags. Cache pressure, cold rows and GC affect these figures;
the renderer remains opt-in.

Clipboard transfer is separate from repainting. This fixture copies 24,882 UTF-8
bytes, encoded as 33,185 OSC 52 bytes and measured as 33,220 encrypted SSH bytes.
With the example's encoding, copying N bytes costs `4 * ceil(N / 3) + 9` application
bytes before SSH overhead. The harness checks delivery of those bytes, not a real
terminal's acceptance of the clipboard request. These scrolling tests use static
output: new surface output or a resize currently clears selection.


### Reducing the implicit API (2026-10-14)

The integration now adds only one optional implicit callback:
`animation_state/2`. Attribute filtering is internal to Breeze's compositor
snapshot construction. Selection timers use the owning view's existing
`handle_info/2` and `Breeze.View.update_implicit/3`, through the VTerm helper
shown above. The generic implicit message callback and timer helper have been
removed. Automatic edge scrolling is opt-in; the demo enables it and forwards
the messages.

A separate internal focus fix makes asynchronous view messages invoke the
existing implicit `blur/1` handler when focus changes. Previously that path only
released mouse capture. This keeps timer cancellation consistent with keyboard
and mouse focus changes, without adding an implicit callback.

The same direct SSH harness compared the previous three-callback implementation
with this reduced API. Medians below use 18 individual edge drags per fixture
across three runs of each version. A control run omitted `animation_state/2`,
retaining full animation state, and measured six drags per fixture:

| Fixture | Three callbacks | One callback | Without projection |
| --- | ---: | ---: | ---: |
| Source text, 156×80 framed | 13.9 ms | 13.6 ms | 18.3 ms |
| Dense plain text, 400×120 | 35.4 ms | 38.0 ms | 81.0 ms |
| Dense colored text, 400×120 | 69.1 ms | 68.5 ms | 161.0 ms |

These measure input to the first output byte on loopback, excluding WAN latency
and client painting. The plain-text median was 2.6 ms slower after simplifying;
the other two were similar. Individual samples vary with caching and GC.
The one-row scenario explicitly passes the autoscroll option as a string because
Breeze's template handling omits boolean `false` component attributes, which
otherwise enabled the old default and invalidated that benchmark.

ANSI and encrypted SSH byte counts matched exactly between versions for every
individual action. The source-code hold still traversed 156 rows in about
3.0 seconds and sent 106,800 encrypted SSH bytes with the scroll renderer.
Dense held scrolling coalesces frames under load, so its frame count and total
traffic vary with scheduling; fixed-step payload comparisons isolate changes
to the renderer.

The retained callback has a measurable purpose: in the plain 400×120 fixture
with three screens of content and no active selection, the animation-state
portion of a snapshot is 688 bytes with projection versus 18,440,640 bytes without it. The compositor
keeps lightweight animation ticks independent of a view that may be busy,
while the view retains the full surface for selection and copying.

### Regression recheck (2026-10-14)

Compared the saved three-callback implementation with the current one-callback
working tree again. An initial pass was discarded after concurrent tests were
reported. The replacement runs alternated version order and sampled background
CPU activity every five seconds. No busy competing BEAM process was observed
during the individual edge-drag comparisons.

Direct loopback SSH, scroll renderer enabled in both versions, median time from
input to the first output byte. Each scrolling row uses 18 edge drags per version
across three runs; stationary selection uses ten output-producing actions across
two runs. These figures exclude WAN latency and client painting.

| Fixture/action | Three callbacks | One callback | Change |
| --- | ---: | ---: | ---: |
| Source, 156×80 framed, edge scrolling | 14.07 ms | 13.94 ms | -0.9% |
| Dense plain, 400×120, edge scrolling | 34.63 ms | 38.38 ms | +10.8% |
| Dense colored, 400×120, edge scrolling | 67.03 ms | 65.85 ms | -1.8% |
| Dense plain, 400×120, stationary selection/edit | 7.17 ms | 6.82 ms | -4.9% |
| Dense colored, 400×120, stationary selection/edit | 32.66 ms | 27.83 ms | -14.8% |

The dense plain-text slowdown appeared in all three run medians: 31.80/35.88/35.23
ms before versus 38.11/39.65/37.05 ms after. Its 95th percentile changed much less,
from 62.12 to 63.37 ms. This remains a small measured regression to investigate;
the rerun does not establish that the API reduction is performance-neutral.

All 177 paired stationary/scroll actions produced identical ANSI byte counts and
identical encrypted SSH byte counts with the scroll renderer. The comparison row
writer also produced identical ANSI sizes, with four SSH counts varying by only
16 bytes. All sessions passed display, cursor, selection-anchor and copied-text
checks applicable to their scenario.

Held-edge scrolling, median of two runs per version:

| Fixture | Rows traversed | Three callbacks | One callback |
| --- | ---: | ---: | ---: |
| Source, 156×80 framed | 156 | 3.023 s | 3.025 s |
| Dense plain, 400×120 | 240 | 4.493 s | 4.527 s |
| Dense colored, 400×120 | 240 | 5.314 s | 5.120 s |

Source holds sent exactly 106,800 encrypted SSH bytes in every run. Dense colored
holds varied from 568,740–1,200,388 bytes before to 569,336–2,110,208 bytes after,
with different frame coalescing. Some auxiliary runs also saw brief competing
BEAM activity. These hold totals do not establish a bandwidth regression or
improvement; the fixed-step comparisons above isolate the renderer's payloads.

The full-view typing/output benchmark at 270×100 with 2,000 prefilled lines used
30 warm-up interactions followed by 100 measured interactions, repeated three
times per version. The median of the run medians was 2.30 → 2.36 ms for snapshot
rendering and 2.34 → 2.40 ms for input/output/render combined. Input and output
handling were each 0.02 ms in both versions. Longer warm-up removed the transient
difference seen with the harness's default two warm-up interactions.

All 165 VTerm tests and the three focused Breeze snapshot/focus tests passed.
Production sources were unchanged throughout this benchmark run.

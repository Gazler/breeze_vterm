# Breeze VTerm

Virtual terminal components for Breeze applications.

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

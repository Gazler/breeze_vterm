defmodule Breeze.VTerm.Parser do
  @moduledoc false

  # Adapted from libvterm 0.3.3 src/parser.c (Paul Evans).
  # See THIRD_PARTY_NOTICES. This UTF-8-only subset discards string payloads,
  # bounds sequence storage, and emits events directly into an Elixir reducer.
  @limit 256
  @strings [:osc, :dcs, :apc, :pm, :sos]

  def feed(state, bytes, acc, emit), do: parse(state, bytes, acc, emit)

  defp parse(state, "", acc, _emit), do: {state, acc}

  # NUL/DEL never alter parsing; CAN/SUB cancel a sequence in any state.
  defp parse(state, <<c, rest::binary>>, acc, emit) when c in [0, 127],
    do: parse(state, rest, acc, emit)

  defp parse(_state, <<c, rest::binary>>, acc, emit) when c in [24, 26],
    do: parse(:ground, rest, emit.(:interrupt, acc), emit)

  defp parse(state, <<27, rest::binary>>, acc, emit) when state in @strings,
    do: parse({:string_escape, state}, rest, emit.(:interrupt, acc), emit)

  defp parse({:string_escape, state}, <<27, rest::binary>>, acc, emit),
    do: parse({:string_escape, state}, rest, acc, emit)

  defp parse(_state, <<27, rest::binary>>, acc, emit),
    do: parse({:escape, ""}, rest, emit.(:interrupt, acc), emit)

  defp parse(state, <<7, rest::binary>>, acc, emit) when state in @strings,
    do: parse(:ground, rest, acc, emit)

  defp parse({:string_escape, _}, <<?\\, rest::binary>>, acc, emit),
    do: parse(:ground, rest, acc, emit)

  # C0 controls execute without destroying the enclosing escape/CSI/string.
  defp parse(:sos, <<c, rest::binary>>, acc, emit) when c < 32,
    do: parse(:sos, rest, acc, emit)

  defp parse(state, <<c, rest::binary>>, acc, emit) when c < 32,
    do: parse(state, rest, emit.({:control, c}, acc), emit)

  # An ESC followed by a non-ST character aborts a control string. Unlike an
  # escape from ground, its final byte is not promoted to an 8-bit C1 control.
  defp parse({:string_escape, _}, <<c, rest::binary>>, acc, emit) when c in 0x30..0x7E,
    do: parse(:ground, rest, emit.({:escape, <<c>>}, acc), emit)

  defp parse({:string_escape, _}, bytes, acc, emit),
    do: parse({:escape, ""}, bytes, acc, emit)

  defp parse({:escape, ""}, <<c, rest::binary>>, acc, emit) when c in 0x40..0x5F do
    case c do
      ?[ -> parse({:csi, :leader, "", "", "", 0}, rest, acc, emit)
      ?] -> parse(:osc, rest, acc, emit)
      ?P -> parse(:dcs, rest, acc, emit)
      ?_ -> parse(:apc, rest, acc, emit)
      ?^ -> parse(:pm, rest, acc, emit)
      ?X -> parse(:sos, rest, acc, emit)
      ?\\ -> parse(:ground, rest, acc, emit)
      _ -> parse(:ground, rest, emit.({:control, c + 0x40}, acc), emit)
    end
  end

  defp parse({:escape, intermed}, <<c, rest::binary>>, acc, emit) when c in 0x20..0x2F do
    state =
      if byte_size(intermed) < @limit, do: {:escape, intermed <> <<c>>}, else: :discard_escape

    parse(state, rest, acc, emit)
  end

  defp parse({:escape, intermed}, <<c, rest::binary>>, acc, emit) when c in 0x30..0x7E,
    do: parse(:ground, rest, emit.({:escape, intermed <> <<c>>}, acc), emit)

  defp parse(:discard_escape, <<c, rest::binary>>, acc, emit) when c in 0x30..0x7E,
    do: parse(:ground, rest, acc, emit)

  defp parse({:csi, _, leader, params, intermed, _}, <<c, rest::binary>>, acc, emit)
       when c in 0x40..0x7E,
       do: parse(:ground, rest, emit.({:csi, leader, params, intermed, <<c>>}, acc), emit)

  defp parse({:csi, _, _, _, _, @limit}, bytes, acc, emit),
    do: parse(:discard_csi, bytes, acc, emit)

  defp parse({:csi, :leader, leader, params, intermed, n}, <<c, rest::binary>>, acc, emit)
       when c in 0x3C..0x3F,
       do: parse({:csi, :leader, leader <> <<c>>, params, intermed, n + 1}, rest, acc, emit)

  defp parse({:csi, stage, leader, params, intermed, n}, <<c, rest::binary>>, acc, emit)
       when stage in [:leader, :args] and c in 0x30..0x3B,
       do: parse({:csi, :args, leader, params <> <<c>>, intermed, n + 1}, rest, acc, emit)

  defp parse({:csi, _, leader, params, intermed, n}, <<c, rest::binary>>, acc, emit)
       when c in 0x20..0x2F,
       do: parse({:csi, :intermed, leader, params, intermed <> <<c>>, n + 1}, rest, acc, emit)

  defp parse({:csi, _, _, _, _, _}, bytes, acc, emit),
    do: parse(:discard_csi, bytes, acc, emit)

  defp parse(:discard_csi, <<c, rest::binary>>, acc, emit) when c in 0x40..0x7E,
    do: parse(:ground, rest, acc, emit)

  defp parse(:ground, bytes, acc, emit) do
    {text, rest} = take_text(bytes, bytes, 0)
    parse(:ground, rest, emit.({:text, text}, acc), emit)
  end

  # Unsupported strings, malformed escapes and oversized sequences retain no payload.
  defp parse(state, <<_, rest::binary>>, acc, emit), do: parse(state, rest, acc, emit)

  defp take_text(original, <<c, rest::binary>>, n) when c >= 32 and c != 127,
    do: take_text(original, rest, n + 1)

  defp take_text(original, rest, n), do: {binary_part(original, 0, n), rest}
end

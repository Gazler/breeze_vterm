System.put_env("BREEZE_VTERM_SKIP_RUN", "1")
Code.require_file("../examples/vterm.exs", __DIR__)

defmodule BreezeVTerm.Benchmark do
  alias Breeze.ChildServer

  @terminal %Termite.Terminal{size: %{width: 270, height: 100}}
  @console_id "fra-web-01"
  @call_timeout 60_000

  def run do
    iterations = int_env("ITERATIONS", 100)
    warmup_iterations = int_env("WARMUP_ITERATIONS", 2)
    prefill_lines = int_env("PREFILL_LINES", 20_000)
    line_width = int_env("LINE_WIDTH", 230)
    echo_bytes = System.get_env("ECHO_BYTES") || "x"
    profile_back_breeze? = truthy_env?("BACK_BREEZE_PROFILE")
    slow_render_us = int_env("SLOW_RENDER_MS", 0) * 1000
    child_process_flags = child_process_flags()

    {:ok, pid} =
      ChildServer.start(
        view: VTermExample,
        terminal: @terminal,
        start_opts: [start_shells: false],
        process_flags: child_process_flags,
        theme: Breeze.Theme.builtin(:gruvbox)
      )

    try do
      :ok = Application.ensure_all_started(:back_breeze) |> elem(0)
      BackBreeze.RenderCache.clear()
      BackBreeze.PreparedContentStore.clear()

      IO.puts("vterm_benchmark")
      IO.puts("  terminal: #{@terminal.size.width}x#{@terminal.size.height}")
      IO.puts("  prefill_lines: #{prefill_lines}")
      IO.puts("  line_width: #{line_width}")
      IO.puts("  iterations: #{iterations}")
      IO.puts("  warmup_iterations: #{warmup_iterations}")
      IO.puts("  child_process_flags: #{inspect(child_process_flags)}")
      IO.puts("")

      prefill = build_prefill(prefill_lines, line_width)
      {prefill_us, :ok} = timed(fn -> emit_output(pid, prefill) end)

      {warm_render_us, _profile, _back_breeze_profile, _process_delta} =
        render(pid, profile_back_breeze?)

      warmup_samples = warmup_interactions(pid, warmup_iterations, echo_bytes)

      IO.puts("setup")
      IO.puts("  prefill output: #{format_ms(prefill_us)}")
      IO.puts("  warm render: #{format_ms(warm_render_us)}")
      print_warmup_stats(warmup_samples)
      IO.puts("")

      samples =
        for index <- 1..iterations do
          {input_us, input_reply} =
            timed(fn ->
              dispatch_input(pid, echo_bytes)
            end)

          {output_us, :ok} = timed(fn -> emit_output(pid, echo_bytes) end)

          {render_us, profile, back_breeze_profile, process_delta} =
            render(pid, profile_back_breeze?)

          sample = %{
            index: index,
            input_us: input_us,
            output_us: output_us,
            render_us: render_us,
            total_us: input_us + output_us + render_us,
            input_invalidates?: invalidating_reply?(input_reply),
            profile: profile,
            back_breeze_profile: back_breeze_profile,
            process_delta: process_delta
          }

          if index == 1 or rem(index, max(div(iterations, 10), 1)) == 0 do
            IO.puts(
              "  #{String.pad_leading(Integer.to_string(index), 4)}/#{iterations} " <>
                "total=#{format_ms(sample.total_us)} " <>
                "input=#{format_ms(input_us)} " <>
                "output=#{format_ms(output_us)} " <>
                "render=#{format_ms(render_us)}"
            )
          end

          if slow_render_us > 0 and render_us >= slow_render_us do
            print_slow_sample(sample, profile_back_breeze?)
          end

          sample
        end

      IO.puts("")
      print_stats("input", Enum.map(samples, & &1.input_us))
      print_stats("output", Enum.map(samples, & &1.output_us))
      print_stats("render", Enum.map(samples, & &1.render_us))
      print_stats("total", Enum.map(samples, & &1.total_us))
      IO.puts("  input_invalidations: #{Enum.count(samples, & &1.input_invalidates?)}")

      IO.puts("")
      IO.puts("render profile avg")

      samples
      |> Enum.flat_map(& &1.profile)
      |> average_profile()
      |> Enum.take(8)
      |> Enum.each(fn {metric, us} ->
        IO.puts("  #{metric}: #{format_ms(us)}")
      end)

      if profile_back_breeze? do
        IO.puts("")
        IO.puts("back_breeze profile avg")

        samples
        |> Enum.map(& &1.back_breeze_profile)
        |> average_back_breeze_profile()
        |> Enum.take(12)
        |> Enum.each(fn {label, stat} ->
          IO.puts(
            "  #{inspect(label)}: total=#{format_ms(stat.total_us)} " <>
              "self=#{format_ms(stat.self_us)} count=#{Float.round(stat.count, 1)}"
          )
        end)
      end

      IO.puts("")
      IO.puts("caches")
      IO.puts("  render_cache_entries: #{BackBreeze.RenderCache.size()}")
      IO.puts("  prepared_content_entries: #{BackBreeze.PreparedContentStore.size()}")
      IO.puts("  erlang_memory_total: #{format_mb(:erlang.memory(:total))}")
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  defp emit_output(pid, bytes) do
    dispatch_info(pid, {:vterm_output, @console_id, bytes})
    dispatch_info(pid, :flush_vterm_output)
    :ok
  end

  defp render(pid, profile_back_breeze?) do
    scope = make_ref()
    Breeze.DebugProfiler.reset(scope)
    process_before = process_snapshot(pid)

    if profile_back_breeze? do
      BackBreeze.BenchProfile.enable_global!()
      BackBreeze.BenchProfile.reset_global!()
    end

    {us, {:ok, _acc, _box, _decorations}} =
      timed(fn ->
        GenServer.call(
          pid,
          {:render_snapshot,
           [
             terminal: @terminal,
             focused: "vterm",
             compact_snapshot: true,
             profile_scope: scope,
             profile_label: "vterm-benchmark"
           ]},
          @call_timeout
        )
      end)

    process_after = process_snapshot(pid)

    back_breeze_profile =
      if profile_back_breeze? do
        snapshot = BackBreeze.BenchProfile.snapshot_global()
        BackBreeze.BenchProfile.disable_global!()
        snapshot
      else
        %{}
      end

    {us, Breeze.DebugProfiler.snapshot(scope), back_breeze_profile,
     process_delta(process_before, process_after)}
  end

  defp dispatch_input(pid, input), do: ChildServer.dispatch_input(pid, input)

  defp dispatch_info(pid, message) do
    GenServer.call(pid, {:info, message, @terminal}, @call_timeout)
  end

  defp warmup_interactions(_pid, count, _echo_bytes) when count <= 0, do: []

  defp warmup_interactions(pid, count, echo_bytes) do
    for _index <- 1..count do
      {input_us, _input_reply} = timed(fn -> dispatch_input(pid, echo_bytes) end)
      {output_us, :ok} = timed(fn -> emit_output(pid, echo_bytes) end)
      {render_us, _profile, _back_breeze_profile, _process_delta} = render(pid, false)
      %{input_us: input_us, output_us: output_us, render_us: render_us}
    end
  end

  defp print_warmup_stats([]), do: :ok

  defp print_warmup_stats(samples) do
    IO.puts(
      "  warmup interactions: count=#{length(samples)} " <>
        "render_max=#{format_ms(samples |> Enum.map(& &1.render_us) |> Enum.max())}"
    )
  end

  defp invalidating_reply?({:noreply, _focused, true}), do: true
  defp invalidating_reply?({:stop, _focused, true}), do: true
  defp invalidating_reply?(_reply), do: false

  defp build_prefill(count, width) do
    Enum.map_join(1..count, "", fn index ->
      index
      |> Integer.to_string()
      |> then(&("bench line " <> &1 <> " "))
      |> String.pad_trailing(width, "x")
      |> Kernel.<>("\r\n")
    end)
  end

  defp average_profile(entries) do
    entries
    |> Enum.reject(&(&1.metric == :element_count))
    |> Enum.group_by(& &1.metric, & &1.value)
    |> Enum.map(fn {metric, values} -> {metric, average(values)} end)
    |> Enum.sort_by(fn {_metric, value} -> value end, :desc)
  end

  defp average_back_breeze_profile(samples) do
    sample_count = max(length(samples), 1)

    totals =
      Enum.reduce(samples, %{}, fn sample, acc ->
        Enum.reduce(sample, acc, fn {label, stat}, acc ->
          Map.update(
            acc,
            label,
            %{total_us: stat.total_us, count: stat.count},
            fn existing ->
              %{
                total_us: existing.total_us + stat.total_us,
                count: existing.count + stat.count
              }
            end
          )
        end)
      end)

    child_totals =
      Map.new(totals, fn {label, _stat} ->
        {label, direct_child_total(label, totals)}
      end)

    totals
    |> Enum.map(fn {label, stat} ->
      total_us = stat.total_us / sample_count
      count = stat.count / sample_count
      self_us = max(total_us - Map.get(child_totals, label, 0) / sample_count, 0)
      {label, %{total_us: total_us, self_us: self_us, count: count}}
    end)
    |> Enum.sort_by(fn {_label, stat} -> stat.self_us end, :desc)
  end

  defp print_slow_sample(sample, profile_back_breeze?) do
    IO.puts("")

    IO.puts(
      "slow sample #{sample.index}: render=#{format_ms(sample.render_us)} " <>
        "total=#{format_ms(sample.total_us)} " <>
        "memory_delta=#{format_mb(sample.process_delta.memory)} " <>
        "reductions_delta=#{sample.process_delta.reductions} " <>
        "minor_gcs_delta=#{sample.process_delta.minor_gcs}"
    )

    sample.profile
    |> Enum.reject(&(&1.metric == :element_count))
    |> Enum.sort_by(& &1.value, :desc)
    |> Enum.take(8)
    |> Enum.each(fn entry ->
      IO.puts("  #{entry.metric}: #{format_ms(entry.value)}")
    end)

    if profile_back_breeze? do
      sample.back_breeze_profile
      |> back_breeze_profile_rows()
      |> Enum.take(12)
      |> Enum.each(fn {label, stat} ->
        IO.puts(
          "  #{inspect(label)}: total=#{format_ms(stat.total_us)} " <>
            "max=#{format_ms(stat.max_us)} count=#{stat.count}"
        )
      end)
    end
  end

  defp back_breeze_profile_rows(profile) do
    profile
    |> Enum.map(fn {label, stat} -> {label, stat} end)
    |> Enum.sort_by(fn {_label, stat} -> stat.total_us end, :desc)
  end

  defp process_snapshot(pid) do
    info =
      pid
      |> Process.info([:garbage_collection, :memory, :reductions])
      |> Map.new()

    %{
      memory: Map.get(info, :memory, 0),
      reductions: Map.get(info, :reductions, 0),
      minor_gcs: info |> get_in([:garbage_collection, :minor_gcs]) |> Kernel.||(0)
    }
  end

  defp process_delta(before, after_snapshot) do
    %{
      memory: after_snapshot.memory - before.memory,
      reductions: after_snapshot.reductions - before.reductions,
      minor_gcs: after_snapshot.minor_gcs - before.minor_gcs
    }
  end

  defp direct_child_total({module, parent}, totals) do
    totals
    |> Enum.filter(fn
      {{^module, child}, _stat} -> direct_child?(parent, child)
      _entry -> false
    end)
    |> Enum.map(fn {_label, stat} -> stat.total_us end)
    |> Enum.sum()
  end

  defp direct_child_total(_label, _totals), do: 0

  defp direct_child?(:render_children, child)
       when child in [
              :grid_prepare_children,
              :flow_children,
              :flow_join,
              :flow_child_render
            ],
       do: true

  defp direct_child?(:flow_children, :flow_child_render), do: true
  defp direct_child?(:flow_join, {:combine_children, _count}), do: true
  defp direct_child?(_parent, _child), do: false

  defp print_stats(label, values) do
    sorted = Enum.sort(values)

    IO.puts(
      "  #{String.pad_trailing(label, 6)} " <>
        "avg=#{format_ms(average(values))} " <>
        "p50=#{format_ms(percentile(sorted, 0.50))} " <>
        "p95=#{format_ms(percentile(sorted, 0.95))} " <>
        "max=#{format_ms(Enum.max(values, fn -> 0 end))}"
    )
  end

  defp percentile([], _percentile), do: 0

  defp percentile(sorted, percentile) do
    index =
      sorted
      |> length()
      |> Kernel.*(percentile)
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)

    Enum.at(sorted, index)
  end

  defp average([]), do: 0
  defp average(values), do: Enum.sum(values) / length(values)

  defp timed(fun) do
    :timer.tc(fun)
  end

  defp format_ms(us) when is_integer(us) or is_float(us) do
    us
    |> Kernel./(1000)
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> Kernel.<>("ms")
  end

  defp format_mb(bytes) do
    bytes
    |> Kernel./(1024 * 1024)
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> Kernel.<>("MB")
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> int
          _ -> default
        end
    end
  end

  defp truthy_env?(name), do: System.get_env(name) in ["1", "true", "TRUE", "yes", "YES"]

  defp child_process_flags do
    defaults = VTermExample.child_process_flags()

    []
    |> maybe_put_flag(
      :min_heap_size,
      int_env("CHILD_MIN_HEAP_SIZE", Keyword.get(defaults, :min_heap_size, 0))
    )
    |> maybe_put_flag(:min_bin_vheap_size, int_env("CHILD_MIN_BIN_VHEAP_SIZE", 0))
    |> maybe_put_flag(:fullsweep_after, int_env("CHILD_FULLSWEEP_AFTER", 0))
  end

  defp maybe_put_flag(flags, _name, value) when value <= 0, do: flags
  defp maybe_put_flag(flags, name, value), do: Keyword.put(flags, name, value)
end

BreezeVTerm.Benchmark.run()

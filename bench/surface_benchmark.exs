alias Breeze.VTerm.Surface

iterations = String.to_integer(System.get_env("ITERATIONS", "1000"))
surface = Surface.new(cols: 120, rows: 40)
bulk = String.duplicate(String.duplicate("x", 118) <> "\r\n", 1000)

for {label, bytes, count} <- [
      {"prompt editing", "x\b \b", iterations},
      {"styled output", "\e[32mhello\e[0m world\r\n", iterations},
      {"bulk output", bulk, 10}
    ] do
  Surface.write(surface, bytes)

  samples =
    for _ <- 1..5 do
      :erlang.garbage_collect()
      {_, reductions_before} = Process.info(self(), :reductions)

      {us, _surface} =
        :timer.tc(fn ->
          Enum.reduce(1..count, surface, fn _, acc -> Surface.write(acc, bytes) end)
        end)

      {_, reductions_after} = Process.info(self(), :reductions)
      {us / count, (reductions_after - reductions_before) / count}
    end

  {us, reductions} = samples |> Enum.sort() |> Enum.at(2)
  IO.puts("#{label}: #{Float.round(us, 2)} us/write, #{round(reductions)} reductions/write")
end

defmodule BreezeVTerm.BenchBaseline do
  @moduledoc false
  @default_ref "f9acdcd008588c73a2af99d450b27f38f635452d"

  # Compile historical sources in a separate namespace. Both versions use the
  # same installed dependencies; neither the worktree nor its index is modified.
  def load(scope \\ :surface, ref \\ System.get_env("BASELINE_REF", @default_ref)) do
    root = Path.expand("../..", __DIR__)
    hash = git!(root, ["rev-parse", "--verify", "#{ref}^{commit}"]) |> String.trim()

    files =
      case scope do
        :surface -> ["surface"]
        :render -> ["surface", "selection", "implicit", "components"]
      end

    Enum.each(files, fn name ->
      path = "lib/breeze/vterm/#{name}.ex"

      root
      |> git!(["show", "#{hash}:#{path}"])
      |> String.replace("Breeze.VTerm", "BreezeVTerm.Baseline")
      |> Code.compile_string("#{hash}:#{path}")
    end)

    {BreezeVTerm.Baseline.Surface, hash}
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, _} -> raise "Cannot load pre-port baseline: #{output}"
    end
  end
end

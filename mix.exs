defmodule BreezeVTerm.MixProject do
  use Mix.Project

  def project do
    [
      app: :breeze_vterm,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:breeze, "~> 0.5.5"},
      {:file_system, "~> 1.1", only: :dev}
    ]
  end
end

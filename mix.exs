defmodule BroadwaySingularityFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :broadway_singularity_flow,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Broadway-compatible producer backed by Singularity Workflow orchestration for durability.",
      package: package(),
      dialyzer: [plt_add_deps: :transitive]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:broadway, "~> 1.0"},
      {:quantum_flow, path: "../singularity-workflows"},
      {:ecto_sql, "~> 3.10"}
    ]
  end

  defp package do
    [
      name: "broadway_singularity_flow",
      files: ~w(lib .formatter.exs mix.exs README.md),
      maintainers: ["Singularity-ng"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Singularity-ng/singularity-workflows"}
    ]
  end
end

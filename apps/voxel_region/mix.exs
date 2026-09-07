defmodule VoxelRegion.MixProject do
  use Mix.Project

  def project do
    [
      app: :voxel_region,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {VoxelRegion.Application, []}
    ]
  end

  defp deps do
    [
      {:data_service, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:mmo_contracts, in_umbrella: true},
      {:rustler, "~> 0.37.3"}
    ]
  end
end

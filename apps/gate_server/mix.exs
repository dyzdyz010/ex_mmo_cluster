defmodule GateServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :gate_server,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :observer_cli],
      mod: {GateServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:observer_cli, "~> 1.7"},
      {:mmo_contracts, in_umbrella: true},
      {:voxel_region, in_umbrella: true},
      {:beacon_server, in_umbrella: true},
      {:scene_server, in_umbrella: true, runtime: false},
      {:world_server, in_umbrella: true, runtime: false},
      {:auth_server, in_umbrella: true, only: :test},
      {:data_service, in_umbrella: true, runtime: false}
    ] ++ quic_deps()
  end

  defp quic_deps do
    case :os.type() do
      {:unix, :linux} ->
        [{:quicer, "== 0.4.3", compile: "bash #{Path.join(__DIR__, "tools/build_quicer.sh")}"}]
      _ -> []
    end
  end
end

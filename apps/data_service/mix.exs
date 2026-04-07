defmodule DataService.MixProject do
  use Mix.Project

  def project do
    [
      app: :data_service,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "config/config.exs",
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
      extra_applications: [:logger],
      mod: {DataService.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:data_init, in_umbrella: true},
      {:beacon_server, in_umbrella: true},
      {:poolboy, "~> 1.5.2"},
      {:memento, "~> 0.3.2"},
      {:bcrypt_elixir, "~> 3.0"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"}
    ]
  end
end

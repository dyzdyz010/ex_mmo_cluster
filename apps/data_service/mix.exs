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
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      xref: [exclude: [DataInit]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      applications: [:memento],
      extra_applications: [:logger],
      mod: {DataService.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:poolboy, "~> 1.5"},
      {:memento, "~> 0.3.2"},
      {:bcrypt_elixir, "~> 3.0"},
      {:data_init, in_umbrella: true}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true}
    ]
  end
end

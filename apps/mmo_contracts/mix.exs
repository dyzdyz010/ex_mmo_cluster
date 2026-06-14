defmodule MmoContracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :mmo_contracts,
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

  # 纯契约库:无监督树,只暴露类型与校验。
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end

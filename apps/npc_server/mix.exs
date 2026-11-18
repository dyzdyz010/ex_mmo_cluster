defmodule NpcServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :npc_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: [
        {:mmo_contracts, in_umbrella: true},
        {:data_service, in_umbrella: true},
        {:voxel_region, in_umbrella: true},
        {:scene_server, in_umbrella: true},
        {:world_server, in_umbrella: true},
        {:jason, "~> 1.4"},
        # 出站 HTTP（模型与 Hindsight）的唯一客户端，见 `NpcServer.Http` 与 Finch 决策稿。
        {:finch, "~> 0.25"}
      ]
    ]
  end

  def application do
    # 模型与长期记忆经 Finch（`NpcServer.Http`）出站；TLS 需要 :ssl。
    [extra_applications: [:logger, :ssl], mod: {NpcServer.Application, []}]
  end
end

defmodule Cluster.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    []
  end

  # Voxim 服务端唯一发布：单节点运行 World / Scene / Auth / Gate，多 Scene 拓扑由 `VOXIM_TOPOLOGY` 在本节点旁起
  # peer 节点。启动顺序由各 app 的运行时依赖决定（data_service → voxel_region → scene_server → world_server →
  # auth_server / gate_server）；`rel/overlays/bin/server` 先迁移数据库再启动。
  defp releases do
    [
      voxim_server: [
        include_executables_for: [:unix],
        include_erts: true,
        applications: [
          data_service: :permanent,
          voxel_region: :permanent,
          scene_server: :permanent,
          world_server: :permanent,
          auth_server: :permanent,
          gate_server: :permanent
        ]
      ]
    ]
  end
end

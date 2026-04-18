defmodule Cluster.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    []
  end

  # Root-level aliases usable from the umbrella root.
  defp aliases do
    [
      # Build all Phoenix assets for production. Runs each Phoenix app's
      # assets.deploy (tailwind --minify, esbuild --minify, phx.digest).
      "assets.deploy": [
        "cmd --app auth_server mix assets.deploy",
        "cmd --app visualize_server mix assets.deploy"
      ]
    ]
  end

  # Release definitions. MVP ships a single container/node that bundles
  # all maintained umbrella apps. Legacy Mnesia cluster apps
  # (data_store, data_contact) are intentionally excluded.
  defp releases do
    [
      ex_mmo_cluster: [
        include_executables_for: [:unix],
        include_erts: true,
        applications: [
          # Infra / discovery
          beacon_server: :permanent,
          # Data layer
          data_init: :permanent,
          data_service: :permanent,
          # Game logic
          world_server: :permanent,
          scene_server: :permanent,
          agent_manager: :permanent,
          agent_server: :permanent,
          # Edge
          gate_server: :permanent,
          auth_server: :permanent,
          visualize_server: :permanent
        ]
      ]
    ]
  end
end

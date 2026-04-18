defmodule DataService.Release do
  @moduledoc """
  Release-safe database helpers.

  Used from within a `mix release` package where `Mix` itself is not
  available. Typical invocation from the production container:

      /app/bin/ex_mmo_cluster eval 'DataService.Release.migrate()'
  """

  @app :data_service

  @doc "Run all pending Ecto migrations for every repo in this app."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Roll back `version` steps on `repo` (single repo form)."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end

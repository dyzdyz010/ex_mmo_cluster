defmodule Mix.Tasks.Db.Initialize do
  @moduledoc "Printed when the user requests `mix help echo`"
  @shortdoc "Initialize Mnesia database structure"
  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(_args) do
    Logger.info("Creating database...", ansi_color: :yellow)

    Node.start :"data_store1@127.0.0.1"

    Application.put_env(
      :mnesia,
      :dir,
      'priv/.mnesia/#{Mix.env()}/#{node()}'
    )
    :ok = DataInit.create_database()

    Logger.info("===Creationg database complete.===", ansi_color: :green)
  end
end

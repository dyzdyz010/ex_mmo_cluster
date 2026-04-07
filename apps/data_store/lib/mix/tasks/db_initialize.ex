defmodule Mix.Tasks.Db.Initialize do
  @moduledoc "Printed when the user requests `mix help echo`"
  @shortdoc "Initialize Mnesia database structure"
  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(_args) do
    Logger.info("Creating database...", ansi_color: :yellow)

    node_name = Application.get_env(:data_store, :node_name, :"data_store1@127.0.0.1")
    Node.start(node_name)

    Application.put_env(
      :mnesia,
      :dir,
      ~c"priv/.mnesia/#{Mix.env()}/#{node()}"
    )
    :ok = DataInit.create_database()

    Logger.info("===Creationg database complete.===", ansi_color: :green)
  end
end

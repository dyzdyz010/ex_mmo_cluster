defmodule Mix.Tasks.Db.Initialize do
  @moduledoc "Printed when the user requests `mix help echo`"
  @shortdoc "Initialize Mnesia database structure"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do

    result = DataInit.create_database([], :store)
    IO.inspect(result, ansi_color: :green)
  end
end

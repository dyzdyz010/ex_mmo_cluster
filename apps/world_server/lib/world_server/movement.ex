defmodule WorldServer.Movement do
  @moduledoc "Low-frequency routing to the explicitly deployed Scene and canonical World."

  @doc "Resolve one configured scene_id; no process discovery or local singleton inference."
  def route(scene_id) do
    case Map.fetch(Application.fetch_env!(:world_server, :movement_routes), scene_id) do
      {:ok, route} -> {:ok, route}
      :error -> {:error, :scene_unavailable}
    end
  end
end

defmodule SceneServer.AoiItemSup do
  @moduledoc """
  Dynamic supervisor for `SceneServer.Aoi.AoiItem` processes.
  """

  use DynamicSupervisor

  @doc "Starts the AOI item dynamic supervisor."
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc false
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

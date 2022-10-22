defmodule SceneServer.AoiSup do
  use Supervisor

  # defp poolboy_config() do
  #   [
  #     name: {:local, :aoi_worker},
  #     worker_module: SceneServer.Aoi.AoiWorker,
  #     size: 100,
  #     max_overflow: 10
  #   ]
  # end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.AoiManager, name: SceneServer.AoiManager},
      {SceneServer.AoiItemSup, name: SceneServer.AoiItemSup},
      # :poolboy.child_spec(:aoi_worker, poolboy_config())
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

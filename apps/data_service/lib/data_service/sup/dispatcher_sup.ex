defmodule DataService.DispatcherSup do
  use Supervisor

  defp poolboy_config() do
    [
      name: {:local, :worker},
      worker_module: DataService.Worker,
      size: 10,
      max_overflow: 6
    ]
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {DataService.Dispatcher, name: DataService.Dispatcher},
      :poolboy.child_spec(:worker, poolboy_config())
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

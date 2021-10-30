defmodule AgentServer.Agent do
  @moduledoc """
  玩家角色实例，负责玩家角色的各项属性状态
  """
  @behaviour GenServer
  require Logger

  @topic {:agent, __MODULE__}
  @scope :agent

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(connection, uid, opts \\ []) do
    GenServer.start_link(__MODULE__, [connection, uid], opts)
  end

  def init([connection]) do
    :pg.start_link(@scope)
    :pg.join(@scope, @topic, self())
    Logger.debug("New client connected.")
    {:ok, %{connection: connection}}
  end

  def handle_call(:character_list, _from, state) do
    list = [%{name: "Evigis", location: [0, 0, 0]}]
    {:reply, list, state}
  end

  def handle_call(:select_character, _from, state) do
    character = %{
      name: "Evigis",
      # 面板属性
      location: [0, 0, 0],
      rotation: [0, 0, 0],
      atk: 50,
      def: 100,
      ctr: 80,
      ctd: 100,
      # 基础属性
      memory: 25,
      comprehension: 25,
      concentration: 25,
      perception: 25,
      resilience: 25
    }

    Process.put(:name, character.name)


    {:reply, :ok, state}
  end
end

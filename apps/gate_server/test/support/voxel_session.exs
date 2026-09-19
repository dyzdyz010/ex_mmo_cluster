defmodule GateServer.TestSupport.VoxelSession do
  @moduledoc "只测试：体素 WS 组件测试的真实鉴权报文和明确的 Scene 接纳替身，不注入 Gate 会话。"
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]
  alias DataService.{Repo, Schema.Account, Schema.Character}
  alias GateServer.WsConnection

  defmodule Interface do
    @moduledoc "只测试：保留每个场景声明的 World 路由，Auth/Scene 接纳使用本机测试服务。"
    use GenServer
    @doc "启动显式测试路由。"
    def start_link(opts),
      do: GenServer.start_link(__MODULE__, Map.new(opts), name: GateServer.Interface)

    @impl true
    def init(opts),
      do: {:ok, Map.merge(%{auth_server: node(), scene_server: node(), world_server: nil}, opts)}

    @impl true
    def handle_call(service, _from, state)
        when service in [:auth_server, :scene_server, :world_server],
        do: {:reply, Map.fetch!(state, service), state}
  end

  defmodule Player do
    @moduledoc "只测试：Scene 接纳替身持有已授权档案中的出生点，支持正常退出。"
    use GenServer
    @doc "按接纳后的角色档案启动。"
    def start_link(profile), do: GenServer.start_link(__MODULE__, profile)
    @impl true
    def init(profile), do: {:ok, profile}
    @impl true
    def handle_call(:get_location, _from, state), do: {:reply, {:ok, state.position}, state}
    def handle_call(:get_next_input_seq, _from, state), do: {:reply, {:ok, 1}, state}
    def handle_call(:exit, _from, state), do: {:stop, :normal, {:ok, ""}, state}
  end

  defmodule PlayerManager do
    @moduledoc "只测试：通过正式 Scene.add_player 契约接收档案，不模拟移动或体素裁决。"
    use GenServer
    @doc "在当前测试监督树启动场景接纳替身。"
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: SceneServer.PlayerManager)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(
          {:add_player, cid, _connection, _timestamp, %{cid: cid} = profile},
          _from,
          state
        ),
        do: {:reply, Player.start_link(profile), state}
  end

  @doc "在独占测试库建立普通账户/角色，Scene 替身由当前测试监督树回收。"
  def setup do
    Repo.delete_all(Character)
    Repo.delete_all(Account)
    {:ok, _} = Application.ensure_all_started(:auth_server)
    start_supervised!(PlayerManager)

    account =
      Repo.insert!(%Account{
        id: System.unique_integer([:positive]),
        username: "tester",
        password: "pw",
        salt: "salt"
      })

    Repo.insert!(%Character{
      id: 42,
      account: account.id,
      name: "tester-character-42",
      position: %{"x" => 10.0, "y" => 20.0, "z" => 30.0}
    })

    :ok
  end

  @doc "通过真实 WS frame 入口鉴权和进场；验证接纳结果，不读取或改写私有会话。"
  def enter(pid) do
    if Process.whereis(GateServer.Interface) == nil, do: start_supervised!({Interface, []})

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims(source: "test")
      |> AuthServer.AuthWorker.issue_token()

    WsConnection.receive_frame(
      pid,
      <<0x05, 11::64-big, 6::16-big, "tester", byte_size(token)::16-big, token::binary>>
    )

    assert_receive {:gate_ws_send, auth}
    assert IO.iodata_to_binary(auth) == <<0x80, 11::64-big, 0>>
    WsConnection.receive_frame(pid, <<0x02, 12::64-big, 42::64-big>>)
    assert_receive {:gate_ws_send, enter}

    assert <<0x84, 12::64-big, 0, 10.0::float-64-big, 20.0::float-64-big, 30.0::float-64-big,
             1::32-big>> = IO.iodata_to_binary(enter)

    :ok
  end
end

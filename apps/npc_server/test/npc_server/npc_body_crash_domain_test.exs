defmodule NpcServer.NpcBodyCrashDomainTest do
  @moduledoc """
  只测试：崩溃域里的 `claim` 超时——它不能打死 Body，要折成 `npc_claim_failed` 并 1 秒后自己重试
  （见 `NpcServer.Application` 的“崩溃域”一节与 `NpcServer.Body.claim/1` 的注释）。

  被验证的责任主体是真实 `NpcServer.Body` 与它的执行进程；claims / Player 是替身（接缝同 `npc_body_cast_test`）：
  测试进程充当 claims，替身 Player 把收到的消息原样转回来。改动之前这里会以 `:timeout` 退出打死 Body——
  Body 在测试里是 `restart: :temporary` 的子进程，所以表现不是重启而是消失，断言因此用 `Process.alive?/1`
  与“之后还能不能正常就位”来钉。

  不证明：`BodySupervisor` 的重启强度（那条由 `npc_application_test` 从监督树状态直接断言）、世界调用超时
  （理由见文件末尾的注释）、真实 Scene / World 在超时之后是否还健康。
  """
  use ExUnit.Case, async: false
  alias NpcServer.Body

  @npc 9401
  @old %{scene_id: 1, session_epoch: 1}

  defmodule Route do
    def route(_scene_id),
      do:
        {:ok,
         %{scene_ref: nil, world_ref: Process.whereis(:npc_crash_domain_owner), scene_epoch: 1}}
  end

  # 只测试：把每个 Outcome 原样转给测试进程；自己不发命令。
  defmodule Relay do
    @behaviour NpcServer.Brain
    def init(%{owner: owner}), do: owner

    def handle_event({:outcome, outcome}, owner) do
      send(owner, {:outcome, outcome})
      {[], owner}
    end

    def handle_event(_event, owner), do: {[], owner}
  end

  setup do
    Process.register(self(), :npc_crash_domain_owner)
    :ok
  end

  test "claim 超时不打死 Body：记一行 npc_claim_failed，1 秒后自己重试并成功就位" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        body = start_body()

        # 第一次 claim：故意不回。`GenServer.call` 5 秒后超时，Body 必须还活着。
        assert_receive {:"$gen_call", first, {:claim, _scene, _route, %{id: @npc, kind: "npc"}}},
                       2_000

        assert Process.alive?(body)

        # 超时之后 1 秒重试：新的 call 到达，这次接受它。
        assert_receive {:"$gen_call", retried,
                        {:claim, _scene, _route, %{id: @npc, kind: "npc"}}},
                       9_000

        refute retried == first
        assert Process.alive?(body)

        player = stand_in()
        GenServer.reply(retried, {@old, {:ok, player}})

        # 就位之后照常工作：time_probe 说明会话真的接上了。
        assert_receive {:player, ^player, {:"$gen_cast", {:time_probe, @old, _}}}, 2_000
        assert Process.alive?(body)
      end)

    assert log =~ "npc_claim_failed"
  end

  # 世界调用超时（`{:error, :world_timeout}`）这一条没有在这里用例化：这条路要一个真的会卡住的 World 调用，
  # 而 NPC 走的世界读口（`World.magic_digest/1`、`material_snapshot` 一类）都是 300 秒上限（见
  # `apps/voxel_region/lib/voxel_region/world.ex`），造 5 秒超时得把整个 Scene / Player 换成会挂的替身，
  # 那测的就不是这一条改动本身了。它的契约由两处钉住：`session_call/4` 只把 `{:timeout, …}` 折成失败、
  # 其余退出照旧上抛（代码 + 注释一处），以及 `npc_body_cast_test` 里已有的“会话丢失 / 进程退出”分支。
  # 若将来真的要测，最省的做法是给 `Body` 注入一个会挂的 `Intent` 模块。

  defp start_body do
    start_supervised!(
      {Body,
       claims: self(),
       route_module: Route,
       scene_id: 1,
       cid: @npc,
       spawn: {0.5, 1.0, 0.5},
       brain: {Relay, %{owner: self()}}},
      restart: :temporary
    )
  end

  # 替身 Player：收到的一切原样转给测试进程；测试进程结束时随之退出。
  defp stand_in do
    owner = self()

    spawn(fn ->
      monitor = Process.monitor(owner)
      forward(owner, monitor)
    end)
  end

  defp forward(owner, monitor) do
    receive do
      {:DOWN, ^monitor, _, _, _} ->
        :ok

      message ->
        send(owner, {:player, self(), message})
        forward(owner, monitor)
    end
  end
end

Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcSettlerSoakTest do
  @moduledoc """
  只测试：Settler 无人值守浸泡（角色能力函数库设计稿 §11 I3 实跑、D-8）。默认排除，显式 `--only npc_soak` 才跑。
  与 npc_settler_test 的多轮用例同一夹具（`NpcServer.NpcWorld`：真实 World / Scene / Player / Body，LLM 关闭），
  外加一个 Test-only 拆除者：每隔一段时间用作者入口 `World.remove_prefab/2` 拆掉 NPC 最早的一座仍立着的石柱
  （作者拆除不退料），让建设者持续有活：重建 → 余额不够 → gather → 采石堆终会挖空，之后的停因应是 `exhausted`。

  时长与采样可配置（秒）：`NPC_SOAK_S`（缺省 1800）、`NPC_SOAK_SAMPLE_S`（缺省 300）、`NPC_SOAK_DEMOLISH_S`（缺省 120）。
  每个采样点打印一行：已放下的 prefab 数、已拆数、gather 挖掉的格数、按 reason 分类的拒绝、`npc_settler_idle` 分布、
  `npc_session_lost` 次数、Body 崩溃重启次数、LLM 请求数、余额、body_state 的 life 与 protein_g、BEAM 进程数与内存。
  判据（D-8）：Body 崩溃 0、`npc_session_lost` ≤ 2、LLM 请求 0；另断言余额守恒（供给 + 512 × 挖掉的格 − 1024 × 放下的石柱，
  作者拆除不退料）与任何时刻立着的 NPC 石柱不超过两座（不重复建）。body_state 取 Body 收到的身体视图（与 Observation 的
  `self.body_state` 同一份）；夹具没有 climate，身体不推进，首尾值应相同，只报告不断言。
  """
  use ExUnit.Case, async: false
  alias NpcServer.Brain.Tree
  alias NpcServer.Trees
  alias NpcServer.NpcWorld
  alias VoxelRegion.{Prefab, World}

  @npc 9101
  @supply 1324
  @pillar Prefab.encode(%{
            cells: [],
            macro_cells: [{{0, 0, 0}, 11}, {{0, 1, 0}, 11}],
            children: [],
            attachments: []
          })
  @sites [
    %{anchor_micro: [64, 512, 112], orientation: 0, stand: [8.5, 11.5]},
    %{anchor_micro: [96, 512, 112], orientation: 0, stand: [12.5, 11.5]},
    %{anchor_micro: [128, 512, 112], orientation: 0, stand: [16.5, 11.5]}
  ]
  @quarry %{11 => %{box: [[10, 64, 4], [13, 64, 6]], tool_id: 1}}
  @pile for x <- 10..13, z <- 4..6, do: {x, 64, z}

  defp env(name, default), do: String.to_integer(System.get_env(name, Integer.to_string(default)))

  @tag :npc_soak
  @tag timeout: :infinity
  test "a Settler left alone keeps building, gathering and resting without crashes, LLM calls or duplicate builds" do
    duration = env("NPC_SOAK_S", 1800) * 1000
    sample = env("NPC_SOAK_SAMPLE_S", 300) * 1000
    demolish = env("NPC_SOAK_DEMOLISH_S", 120) * 1000

    fixture = NpcWorld.start(prefab_access: true)
    world = fixture.world
    {:ok, _} = World.apply_edits(world, Enum.map([{16, 64, 14} | @pile], &{&1, 11}))
    publisher = NpcWorld.actor(4242, {0.0, 0.0, 0.0})
    {:ok, id} = World.publish_prefab(world, publisher, @pillar, "石柱")
    {:ok, _} = World.material_supply(world, @npc, "settler-soak", %{11 => @supply})

    # LLM 请求计数：技能与大脑若发模型请求都经 profile.request；Settler 不该有任何一次。
    llm = :counters.new(1, [])

    brain =
      {Tree,
       %{
         tree: &Trees.settler/1,
         definition: Base.encode16(id),
         sites: @sites,
         quarries: @quarry,
         revisit_ticks: 1_800,
         tools: %{1 => "镐"},
         skills: %{build: %{}, gather: %{}, travel: %{}},
         memory: NpcWorld.Memory,
         request: fn _endpoint, _body ->
           :counters.add(llm, 1, 1)
           {:error, :llm_disabled}
         end
       }}

    NpcWorld.assert_stands_within_reach(@sites, @quarry)
    NpcWorld.LogTap.attach()
    %{sup: sup, body: body} = NpcWorld.body(fixture, brain)

    # 入场时权威发一份身体视图；等到它再开始采样，首个采样点就有 body_state。
    NpcWorld.await(fn -> body_state(body) end)
    started = System.monotonic_time(:millisecond)
    Process.send_after(self(), :sample, 0)
    Process.send_after(self(), :demolish, demolish)
    Process.send_after(self(), :finish, duration)

    state = %{
      world: world,
      sup: sup,
      body: body,
      monitor: Process.monitor(body),
      started: started,
      sample: sample,
      demolish: demolish,
      llm: llm,
      # 已放下、还立着的实例（事务号 = birth，旧在前）。
      standing: [],
      placed: 0,
      demolished: 0,
      max_standing: 0,
      rejections: %{},
      idle: %{},
      session_lost: 0,
      # Player 进程异常退出（退出原因是错误元组，不是 :normal / :shutdown / :killed）：Body 会重新 claim、不计重启，
      # 只看 restarts 会把 Player 崩溃判成通过（2026-10-08 M3 的 CollisionUpdates 崩溃就曾这样假通过）。
      player_crashes: 0,
      restarts: 0,
      samples: []
    }

    state = soak(state)
    report(state)

    assert state.restarts == 0
    assert state.player_crashes == 0
    assert state.session_lost <= 2
    assert :counters.get(llm, 1) == 0
    assert state.max_standing <= 2
    mined = mined(world)
    assert NpcWorld.balance(world, @npc) == @supply + 512 * mined - 1024 * state.placed
  end

  defp soak(state) do
    receive do
      {:npc_log, line} ->
        soak(count(state, line))

      :sample ->
        Process.send_after(self(), :sample, state.sample)
        row = row(state)
        IO.puts("npc_soak_sample " <> inspect(row, limit: :infinity))
        soak(%{state | samples: state.samples ++ [row]})

      :demolish ->
        Process.send_after(self(), :demolish, state.demolish)

        case state.standing do
          [oldest | rest] ->
            {:ok, _} = World.remove_prefab(state.world, {oldest, 0})
            soak(%{state | standing: rest, demolished: state.demolished + 1})

          [] ->
            soak(state)
        end

      {:DOWN, ref, :process, _, _} when ref == state.monitor ->
        body =
          NpcWorld.await(fn ->
            pid = NpcWorld.current_body(state.sup)
            is_pid(pid) and pid != state.body and pid
          end)

        soak(%{state | body: body, monitor: Process.monitor(body), restarts: state.restarts + 1})

      :finish ->
        # 收尾前排空已到的日志，再取最后一个采样点。
        state = drain(state)
        row = row(state)
        IO.puts("npc_soak_sample " <> inspect(row, limit: :infinity))
        %{state | samples: state.samples ++ [row]}
    end
  end

  defp drain(state) do
    receive do
      {:npc_log, line} -> drain(count(state, line))
    after
      0 -> state
    end
  end

  defp count(state, line) do
    cond do
      line =~ "kind=voxel_prefab_place_v1 cid=#{@npc} " and line =~ "result=ok" ->
        [seq] = Regex.run(~r/result=ok seq=(\d+)/, line, capture: :all_but_first)
        standing = state.standing ++ [String.to_integer(seq)]

        %{
          state
          | standing: standing,
            placed: state.placed + 1,
            max_standing: max(state.max_standing, length(standing))
        }

      String.starts_with?(line, "character_intent") and line =~ "cid=#{@npc} " and
          line =~ "result=error" ->
        reject(state, line, ~r/reason=(\S+)/)

      String.starts_with?(line, "npc_intent_rejected") or
          String.starts_with?(line, "npc_move_rejected") ->
        reject(state, line, ~r/reason=(\S+)/)

      String.starts_with?(line, "npc_settler_idle") ->
        [reason] = Regex.run(~r/reason=(\S+)/, line, capture: :all_but_first)
        %{state | idle: Map.update(state.idle, reason, 1, &(&1 + 1))}

      String.starts_with?(line, "npc_session_lost") ->
        crash = if line =~ "reason={:player_down, {", do: 1, else: 0

        %{
          state
          | session_lost: state.session_lost + 1,
            player_crashes: state.player_crashes + crash
        }

      true ->
        state
    end
  end

  defp reject(state, line, pattern) do
    [reason] = Regex.run(pattern, line, capture: :all_but_first)
    %{state | rejections: Map.update(state.rejections, reason, 1, &(&1 + 1))}
  end

  defp mined(world),
    do: 12 - Enum.count(NpcWorld.cells(world, @pile), fn {_, row} -> row.material == 11 end)

  defp row(state),
    do: %{
      t_s: div(System.monotonic_time(:millisecond) - state.started, 1000),
      placed: state.placed,
      demolished: state.demolished,
      standing: length(state.standing),
      mined_cells: mined(state.world),
      balance: NpcWorld.balance(state.world, @npc),
      body_state: body_state(state.body),
      rejections: state.rejections,
      idle: state.idle,
      session_lost: state.session_lost,
      body_restarts: state.restarts,
      llm_requests: :counters.get(state.llm, 1),
      processes: :erlang.system_info(:process_count),
      memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1),
      process_memory_mb: Float.round(:erlang.memory(:processes) / 1_048_576, 1)
    }

  # Body 收到的身体视图（Session.BodyState 的 life / protein_g）；会话重连的间隙里可能还没有。
  defp body_state(body) do
    case :sys.get_state(body).body_state do
      nil -> nil
      view -> Map.take(view, [:life, :protein_g])
    end
  end

  defp report(state) do
    [first | _] = state.samples
    last = List.last(state.samples)

    IO.puts(
      "npc_soak_summary duration_s=#{last.t_s} placed=#{last.placed} demolished=#{last.demolished} " <>
        "mined_cells=#{last.mined_cells} balance=#{last.balance} session_lost=#{last.session_lost} " <>
        "body_state=#{inspect(first.body_state)}->#{inspect(last.body_state)} " <>
        "body_restarts=#{last.body_restarts} llm_requests=#{last.llm_requests} max_standing=#{state.max_standing} " <>
        "processes=#{first.processes}->#{last.processes} memory_mb=#{first.memory_mb}->#{last.memory_mb} " <>
        "process_memory_mb=#{first.process_memory_mb}->#{last.process_memory_mb} " <>
        "rejections=#{inspect(last.rejections)} idle=#{inspect(last.idle)}"
    )
  end
end

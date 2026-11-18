Code.require_file("npc_world.exs", __DIR__)
Code.require_file("reflection_fixtures.exs", __DIR__)

defmodule NpcServer.LifeFixtures do
  @moduledoc """
  只测试：Life 集成用例共用的替身、profile 与真实 World 动作（`npc_life_test.exs` 与 `npc_life_day_plan_integration_test.exs`）。
  替身只替 HTTP 适配器（`ReflectHindsight`）与写日记的函数（`reflect_profile/3`）；`damage/4` 经 World 正式入口做出
  “别人打掉我放的一格”的真实事务。
  """
  alias NpcServer.NpcWorld
  alias VoxelRegion.World

  defmodule ReflectHindsight do
    @moduledoc """
    只测试：反思用例的 Hindsight 替身（只替 HTTP 适配器模块）。认识固定一份。召回、建库、写入都把 bank 交给测试进程
    （经历库 `npc-life-<cid>` 与反思库 `npc-reflect-<cid>` 由此分得清）；召回按这一路的 types 回放 S1-X2 第 4 轮 Q_place
    那一次召回的真实条目（规范化后的形状，`NpcServer.ReflectionFixtures.recalled/1`）。
    `profile.life` 带 `archive_fails: true` 时，写进反思库返回适配器真实形状的超时失败（`Life.Hindsight` 的 `:timeout`）；
    带 `archive_crashes: true` 时，写进反思库直接抛错（反思槽在存档阶段崩溃）。
    召回的一次失败由测试进程控制（同 `npc_life_day_plan_integration_test.exs` 的 `RefusingStore`）：测试进程在同名 ETS 表里放下
    `{bank, 测试进程}` 之后，这个库的**下一次**召回返回适配器真实形状的超时失败（`Life.Hindsight` 的 `:timeout`，S1-R10 实跑里
    规划召回的失败就是它），并把 `{:recall_refused, bank}` 交给测试进程；其余召回照常回放。
    """
    alias NpcServer.ReflectionFixtures

    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "builder"}, metadata: %{}}}
    def refresh(config), do: models(config)
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 1}, usage: %{}}}

    def ensure_bank(config, name) do
      send(config.owner, {:ensure_bank, config.bank, name})
      {:ok, %{bank: config.bank}}
    end

    def retain(config, documents) do
      send(config.owner, {:retained, config.bank, documents})
      archive? = String.starts_with?(config.bank, "npc-reflect-")

      cond do
        archive? and config[:archive_crashes] == true -> raise "archive retain crashed"
        archive? and config[:archive_fails] == true -> {:error, :timeout}
        true -> {:ok, %{retained: length(documents), facts: 1}}
      end
    end

    def recall(config, description, _now_ms) do
      send(config.owner, {:recall, config.bank, description})

      case :ets.whereis(__MODULE__) != :undefined and :ets.take(__MODULE__, config.bank) do
        [{bank, test}] ->
          send(test, {:recall_refused, bank})
          {:error, :timeout}

        _ ->
          kind = if description[:types] == ["observation"], do: "observation", else: "raw"
          {:ok, %{results: ReflectionFixtures.recalled(kind), latency_ms: 1}}
      end
    end
  end

  @doc """
  开着反思的 profile：人格卡用 S1-T 的注册参数（`.demo/observe/npc-slice1-20261112/s1t/scripts/params-s1t.exs`）；
  写日记的函数把系统提示词与用户消息交给测试进程（`{:write, worker, system, user}`），由测试逐次给出应答
  （`{:reply, 应答}`；`{:exit, 原因}` 让写作函数在槽 worker 里退出）。`life_options` 并进 `profile.life`（Life 的时钟、替身开关）；
  `memory` 是 Life 的存储模块。
  """
  def reflect_profile(test, life_options, memory) do
    {:ok, card} =
      NpcServer.Persona.new(%{
        "traits" => %{
          "hardworking" => 8,
          "responsible" => 8,
          "thorough" => 7,
          "bold" => 7,
          "practical" => 7,
          "friendly" => 6
        },
        "personal" =>
          "Takes pride in the things he builds and is slow to forget a wrong done to him. " <>
            "Once his work is done he likes to spend his time at the plaza with the neighbours."
      })

    %{
      owner: test,
      memory: memory,
      who: "Garen, a builder",
      persona: card,
      # 写日记的接口只是让 Life 开反思；发送函数被替换，这个地址不会被请求。
      reflect: %{
        url: "http://127.0.0.1:9/v1/messages",
        key: NpcServer.Secret.wrap("test-key"),
        model: "reflect-test"
      },
      write_journal: fn system, user ->
        send(test, {:write, self(), system, user})

        receive do
          {:reply, reply} -> reply
          # 写作阶段崩溃：写日记的函数在反思槽 worker 里退出。
          {:exit, reason} -> exit(reason)
        end
      end,
      life:
        Map.merge(
          %{
            hindsight: ReflectHindsight,
            owner: test,
            poll_ms: 30,
            url: "http://life.test.invalid"
          },
          life_options
        )
    }
  end

  @doc """
  `npc` 先经 World 生产入口在 `cell` 放一格石料，再由另一角色（`npc + 10`，站在 (4.5, 65.5, 8.5)）用镐打它一下
  （先查询命中目标，再按它出手）。Life 读到的是“别人打了我放的东西”（`kind:event`）。`seq` 区分各次的请求号与补给。
  """
  def damage(world, npc, seq, cell) do
    {:ok, _} = World.material_supply(world, npc, "life-supply-#{seq}", %{11 => 512})
    actor = actor(npc)

    {:ok, _} =
      World.production_intent(world, actor, %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: 1,
        action: 1,
        coord: cell,
        tool_id: 1,
        material: 11
      })

    attacker = actor(npc + 10)
    {x, y, z} = cell

    query = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {x + 0.5 - 4.5, y + 0.5 - 65.5, z + 0.5 - 8.5},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    {:ok, target} = World.tool_intent(world, attacker, query)

    {:ok, _} =
      World.tool_intent(
        world,
        Map.merge(attacker, %{received_us: seq * 1_000_000, clock_node: node()}),
        Map.merge(
          query,
          Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
        )
        |> Map.put(:action, 1)
      )
  end

  @doc "角色替身（World 单元测试的那种，站在 (4.5, 65.5, 8.5)）：同一测试进程里同一角色只起一个。"
  def actor(cid) do
    actor = Process.get({:life_actor, cid}) || NpcWorld.actor(cid, {4.5, 65.5, 8.5})
    Process.put({:life_actor, cid}, actor)
    actor
  end
end

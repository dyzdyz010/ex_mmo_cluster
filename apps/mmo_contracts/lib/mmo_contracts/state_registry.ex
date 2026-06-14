defmodule MmoContracts.StateRegistry do
  @moduledoc """
  PERS-5 状态分类**清单的单一来源**(manifest-as-data)。

  登记主要状态持有者及其 `state_class`,作为"每个状态都已分类"的可审计依据(PERS-5:
  未分类禁止进入生产代码)。`holder` 以模块名(atom)登记,**不**产生对那些 app 的编译依赖
  (仅是 atom 字面量),故本契约库保持零 sibling 依赖。

  与 `MmoContracts.StateClassed` 配套:各持有者模块用 `use MmoContracts.StateClassed, class: ...`
  做**编译期**自声明;本清单做**集中登记**;迁移测试断言二者一致(梯队 0 step 0.5)。

  > 本清单随迁移推进**增量补全**。当前为种子集,覆盖四类各自的代表性持有者。
  """
  alias MmoContracts.StateClass

  @type entry :: %{
          holder: module(),
          state_class: StateClass.t(),
          app: atom(),
          spec: String.t(),
          note: String.t()
        }

  @entries [
    # —— durable_authoritative:成功确认前必须可恢复(AUTH-2/PERS-6)——
    %{
      holder: SceneServer.Voxel.Storage,
      state_class: :durable_authoritative,
      app: :scene_server,
      spec: "PERS-5/AUTH-2",
      note: "chunk hot truth;经 ChunkSnapshotStore 落库"
    },
    %{
      holder: DataService.Voxel.ChunkSnapshotStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/CELL-19",
      note: "chunk 权威快照;advisory_lock+FOR UPDATE+chunk_version CAS"
    },
    %{
      holder: DataService.Voxel.SceneObjectStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5",
      note: "prefab/object 资产持久化"
    },
    %{
      holder: DataService.Voxel.MapLedgerStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/CELL-23",
      note: "region 所有权目录/owner_epoch/lease 持久化"
    },
    %{
      holder: DataService.Voxel.WriteTokenStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/CELL-19/21",
      note: "lease 写令牌 fence(梯队1 step1.2 改 Postgres durable)"
    },
    %{
      holder: DataService.Voxel.RegionEpochStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/CELL-18/23",
      note: "owner_epoch 线性化分配器(梯队1 step1.3,消除 ANTI-32)"
    },
    %{
      holder: DataService.Voxel.CommandLog,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/AUTH-4/SEC-4",
      note: "命令 replay-protection 幂等日志(梯队1 step1.5)"
    },
    %{
      holder: DataService.Voxel.Outbox,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5/AUTH-9/10",
      note: "durable replication outbox(梯队3 step3.9,committed delta 可靠重投 + visibility_watermark)"
    },
    %{
      holder: WorldServer.Voxel.MapLedger,
      state_class: :durable_authoritative,
      app: :world_server,
      spec: "PERS-5/CELL-18/23",
      note: "区域所有权/lease/epoch 单写者目录(运行时态,持久化后端 MapLedgerStore)"
    },
    %{
      holder: WorldServer.Voxel.TransactionCoordinator,
      state_class: :durable_authoritative,
      app: :world_server,
      spec: "PERS-5/AUTH-10/12",
      note: "跨区事务状态;coordinator snapshot 持久化(saga/outbox 雏形)"
    },
    %{
      holder: SceneServer.Voxel.ObjectRegistry,
      state_class: :durable_authoritative,
      app: :scene_server,
      spec: "PERS-5/AUTH-11",
      note: "object/part 健康与销毁;经 SceneObjectStore 落库(梯队3 补 system_actor 信封)"
    },
    %{
      holder: DataService.Schema.Account,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5",
      note: "账户"
    },
    %{
      holder: DataService.Schema.Character,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5",
      note: "角色"
    },

    # —— runtime_authoritative:服务端裁决,checkpoint/input log 恢复(AUTH-15/PERS-12)——
    %{
      holder: SceneServer.PlayerCharacter,
      state_class: :runtime_authoritative,
      app: :scene_server,
      spec: "PERS-5/AUTH-15/PERS-12",
      note: "玩家移动权威态(固定 tick 积分);梯队1 补恢复声明"
    },
    %{
      holder: SceneServer.Combat.State,
      state_class: :runtime_authoritative,
      app: :scene_server,
      spec: "PERS-5/AUTH-15",
      note: "HP/死亡/respawn;进入最终结算须转 durable AUTH"
    },

    # —— derived:可重建,不持久化(PERS-1/3/7)——
    %{
      holder: SceneServer.Voxel.Field.FieldRegion,
      state_class: :derived,
      app: :scene_server,
      spec: "PERS-1/3",
      note: "物理场;解析弛豫+warm-up 重建;触发权威后果须经 AUTH-11"
    },
    %{
      holder: SceneServer.Voxel.Field.FieldLayer,
      state_class: :derived,
      app: :scene_server,
      spec: "PERS-1/3",
      note: "密集场数组;derived 不落盘"
    },
    %{
      holder: SceneServer.Voxel.SimulationTick,
      state_class: :derived,
      app: :scene_server,
      spec: "PERS-7/DET-2",
      note: "模拟 tick 调度态;确定性 output_hash 可重建"
    },

    # —— ephemeral:可丢失,禁止影响最终结算(PERS-8)——
    %{
      holder: SceneServer.Combat.EffectEvent,
      state_class: :ephemeral,
      app: :scene_server,
      spec: "PERS-8/AUTH-6",
      note: "无状态视觉 cue;不影响经济/资产/战斗最终裁决"
    }
  ]

  @doc "全部登记条目。"
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "按 state_class 过滤。"
  @spec by_class(StateClass.t()) :: [entry()]
  def by_class(class), do: Enum.filter(@entries, &(&1.state_class == class))

  @doc "登记的持有者模块列表。"
  @spec holders() :: [module()]
  def holders, do: Enum.map(@entries, & &1.holder)

  @doc "条目数。"
  @spec count() :: non_neg_integer()
  def count, do: length(@entries)

  @doc """
  校验清单完整性:每条 `state_class` 合法(PERS-5)、`holder` 无重复。失败 raise。
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(@entries, fn e -> StateClass.fetch!(e.state_class) end)

    holders = holders()
    dups = holders -- Enum.uniq(holders)

    if dups != [] do
      raise ArgumentError, "StateRegistry 重复登记 holder: #{inspect(Enum.uniq(dups))}"
    end

    :ok
  end
end

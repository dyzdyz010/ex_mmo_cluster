defmodule SceneServer.Voxel.Field.FieldProvisioner do
  @moduledoc """
  世界内容驱动场 provisioning 的统一契约。

  每个 provisioner 是一个**纯函数式探测器**:给定 chunk 的只读 truth context,回答
  「本 chunk 当前内容是否需要本场,需要的话起什么 region」。`ChunkProcess` 在块变更
  去抖后**一次 sweep** 遍历注册的 provisioner,对每个调 `detect/1` → ensure(active)
  或 release(inactive)。核心的 ensure/start/release/source_key 机制 `ChunkProcess`
  已通用,本契约只把「触发 + 探测 + region 规格」从电路硬编码里抽出来声明化。

  `electric_circuit` 是第一个 provisioner(闭合电路,行为逐字节保持自原 auto_circuit);
  `emergence`(`[light_propagation, reaction]`)、`thermal`(`[temperature_diffusion]`)
  随后。原则与初始集见
  `docs/2026-06-23-world-content-driven-field-provisioning.md`。
  """

  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Storage

  @typedoc "探测只读上下文:一次构建,sweep 内所有 provisioner 共享。"
  @type context :: %{
          storage: Storage.t(),
          projection: ParticipantProjection.t(),
          chunk_coord: {integer(), integer(), integer()},
          logical_scene_id: non_neg_integer()
        }

  @type detail :: %{optional(atom()) => term()}

  @typedoc """
  探测结果:
    * `{:active, region_attrs, detail}` —— 起 / 复用 region。`region_attrs` 不含
      `:source_key`(由 sweep 注入),含 `kernels` 等 `FieldRegion.new/1` 字段。
    * `{:inactive, reason, detail}` —— 无对应内容,释放本 chunk 的本场 source。
  `detail` 进遥测(各 provisioner 自定字段,如电路的 source_count/load_count)。
  """
  @type detection ::
          {:active, region_attrs :: map(), detail()}
          | {:inactive, reason :: atom(), detail()}

  @doc "本 chunk 内本场的稳定 source_key(同键幂等复用 / 释放)。"
  @callback source_key(context()) :: term()

  @doc "纯读 truth/projection 探测:active 起 region,inactive 释放。无副作用。"
  @callback detect(context()) :: detection()

  @doc "本 provisioner 的 `CliObserve` 事件名(各场保留独立遥测口径)。"
  @callback telemetry_event() :: String.t()

  @doc "便捷:`detect/1` 是否 active。subscribe / worker-expiry 重触发门控用。"
  @spec active?(module(), context()) :: boolean()
  def active?(provisioner, context) do
    match?({:active, _attrs, _detail}, provisioner.detect(context))
  end
end

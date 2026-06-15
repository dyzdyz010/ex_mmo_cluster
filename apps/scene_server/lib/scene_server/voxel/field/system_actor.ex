defmodule SceneServer.Voxel.Field.SystemActor do
  @moduledoc """
  派生→权威唯一提交桥(梯队3 step3.8,RULE-11 / AUTH-11 / RULE-15 / RULE-16)。

  局部规则(field kernel)产出的、会改 authoritative 状态的 `FieldEffect`(如
  `{:write_voxel_attribute, %{attribute: :temperature, ...}}`)**不再由 FieldTickWorker 直写
  ChunkProcess**;改为 `submit_field_effects/4` 提交本节点级 system_actor,由它:

  1. 把 effect 包成 `MmoContracts.Envelope.CandidateEffect`(FROZEN-5),`candidate_effect_id` 由
     **稳定输入派生**(cell_id + rule_id + rule_version + affected_object_id + quantized_condition_bucket,
     RULE-16,禁浮点原值/随机/墙钟)。
  2. **RULE-15 阈值锁存(去抖)**:per `latch_key = {cell, rule, object, attribute}` 追踪
     `last_committed_bucket`;候选的 `quantized_condition_bucket` 与上次相同 → 已 latch(幂等跳过,
     不重复写权威);bucket 变(跨量化阈)→ 提交并更新 latch。消除"逐格抖动反复翻转权威 truth"。
  3. **提交**(latch 命中首次):经现有 `ChunkProcess.apply_field_effects`(权威写执行器)落 truth。

  observe-only effect 不经本桥(本就不改权威,由 FieldTickWorker 直接 emit)。

  节点级单桥(GenServer)对齐 AUTH-11"system_actor 是 derived→authoritative 唯一入口";挂 VoxelSup。
  """

  use GenServer

  alias MmoContracts.Envelope.CandidateEffect
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkProcess

  # target value 量化分桶大小(单位同 attribute 的 target;温度=摄氏度)。量化提供阈值/滞回去抖。
  @default_bucket_size 5.0
  @rule_version 1
  @payload_version 1

  @type submit_result :: %{
          required(:results) => [{:committed | :latched, term()}],
          required(:committed_count) => non_neg_integer(),
          required(:latched_count) => non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  提交一批 field effect。`context` 需含 `:region_id` / `:chunk_coord` / `:kernel_id` /
  `:source_tick`。返回各效果的 latch 判定与提交摘要。
  """
  @spec submit_field_effects(GenServer.server(), pid(), [tuple()], map()) ::
          {:ok, submit_result()} | {:error, term()}
  def submit_field_effects(server \\ __MODULE__, chunk_pid, effects, context)
      when is_pid(chunk_pid) and is_list(effects) and is_map(context) do
    GenServer.call(server, {:submit, chunk_pid, effects, context})
  end

  @doc "CLI / 调试用快照(锁存条目数)。"
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc "清空锁存状态(test-only hatch)。"
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       bucket_size: Keyword.get(opts, :bucket_size, @default_bucket_size),
       # %{latch_key => last_committed_bucket}
       latches: %{}
     }}
  end

  @impl true
  def handle_call({:submit, chunk_pid, effects, context}, _from, state) do
    {to_commit, results, next_state} =
      Enum.reduce(effects, {[], [], state}, fn effect, {commit_acc, res_acc, st} ->
        case gate(effect, context, st) do
          {:commit, candidate, st2} ->
            {[effect | commit_acc], [{:committed, candidate_id(candidate)} | res_acc], st2}

          {:latched, candidate, st2} ->
            emit_latched(candidate, context)
            {commit_acc, [{:latched, candidate.candidate_effect_id} | res_acc], st2}
        end
      end)

    commit_effects = Enum.reverse(to_commit)
    commit_field_effects(chunk_pid, commit_effects, context)

    results = Enum.reverse(results)

    reply = %{
      results: results,
      committed_count: length(commit_effects),
      latched_count: Enum.count(results, &match?({:latched, _}, &1))
    }

    {:reply, {:ok, reply}, next_state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, %{latch_count: map_size(state.latches), bucket_size: state.bucket_size}, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | latches: %{}}}
  end

  # ---- 门控:candidate_effect 派生 + 阈值锁存 -------------------------------

  defp gate({:write_voxel_attribute, attrs}, context, state) when is_map(attrs) do
    if continuous_write?(attrs) do
      # 功能完善 · 反应层 R5b:**连续注入效果**(燃烧 heat_energy_joules / burn_progress add_delta
      # 累进)是每 tick 累加的,**绕去抖锁存**——否则同桶 latch 会让火不自维持。always commit。
      # (现有 conduction/discharge 连续 Joule 注热同受益此修正。)
      {:commit, nil, state}
    else
      bucket = quantized_bucket(attrs, state.bucket_size)
      latch_key = latch_key(attrs, context)
      candidate = build_candidate(latch_key, bucket, attrs, context, state)

      case Map.get(state.latches, latch_key) do
        ^bucket ->
          # 同量化分桶 → 已 latch,幂等跳过(不重复写权威)。
          {:latched, candidate, state}

        _other ->
          # 跨量化阈(或首次)→ 提交并更新 latch。
          {:commit, candidate, %{state | latches: Map.put(state.latches, latch_key, bucket)}}
      end
    end
  end

  # set_tag(加/减 tag):storage 层幂等(加已有/减不存在为 no-op),且规则 require/forbid 前置已门控
  # 发射 → always commit(不锁存)。
  defp gate({:set_tag, _attrs}, _context, state), do: {:commit, nil, state}

  # 功能完善 · 反应层 R2:材料转变(派生→权威)同经本桥。**复用 bucket 锁存**:bucket = to_material_id
  # (离散材料 id 即桶,无需量化);latch_key 的 attribute 维 = :material。同 {cell,macro,目标材料} 已提交
  # → latched 幂等跳过(防同 tick 重复转);目标变(水→蒸汽)→ 新桶提交。
  defp gate({:transform_material, attrs}, context, state) when is_map(attrs) do
    bucket = Map.get(attrs, :to_material_id)
    latch_key = transform_latch_key(attrs, context)
    candidate = build_candidate(latch_key, bucket, attrs, context, state)

    case Map.get(state.latches, latch_key) do
      ^bucket ->
        {:latched, candidate, state}

      _other ->
        {:commit, candidate, %{state | latches: Map.put(state.latches, latch_key, bucket)}}
    end
  end

  # 功能完善 · 反应层 R8:放电击穿伤害——持续电弧逐 tick 累损 health,**连续 always-commit**(同 heat/delta
  # 绕去抖锁存,否则同桶 latch 会让伤害停摆);ChunkProcess 端权威重校 health>0 + 归零毁块。
  defp gate({:damage_block, _attrs}, _context, state), do: {:commit, nil, state}

  # 非 write_voxel_attribute 的 field effect(如 unsupported action):**透传**给 ChunkProcess,
  # 由其执行器显式 reject(emit voxel_field_effect_rejected)——不静默吞掉(显式失败纪律)。
  defp gate(_other, _context, state), do: {:commit, nil, state}

  # 连续注入:带累加能量(heat_energy_joules)或累进 delta(burn_progress)的写 → 绕去抖锁存。
  defp continuous_write?(attrs) do
    is_number(Map.get(attrs, :heat_energy_joules)) or is_number(Map.get(attrs, :delta))
  end

  defp transform_latch_key(attrs, context) do
    {
      {Map.get(context, :region_id), Map.get(context, :chunk_coord)},
      Map.get(context, :kernel_id),
      Map.get(attrs, :macro_index),
      :material
    }
  end

  defp candidate_id(nil), do: nil
  defp candidate_id(%CandidateEffect{candidate_effect_id: id}), do: id

  defp latch_key(attrs, context) do
    {
      {Map.get(context, :region_id), Map.get(context, :chunk_coord)},
      Map.get(context, :kernel_id),
      Map.get(attrs, :macro_index),
      Map.get(attrs, :attribute)
    }
  end

  # 量化分桶:target value 按 bucket_size 量化(整数桶),提供阈值/滞回去抖。
  # RULE-16:禁浮点原值——只用量化整数桶进 candidate_effect_id。
  defp quantized_bucket(attrs, bucket_size) do
    value = condition_value(attrs)
    round(value / bucket_size)
  end

  # 取 effect 的条件量(目前温度:target_temperature_celsius / target_value)。
  defp condition_value(attrs) do
    cond do
      is_number(Map.get(attrs, :target_temperature_celsius)) ->
        attrs.target_temperature_celsius

      is_number(Map.get(attrs, :target_value)) ->
        attrs.target_value

      true ->
        0.0
    end
  end

  defp build_candidate(latch_key, bucket, attrs, context, _state) do
    CandidateEffect.new!(
      candidate_effect_id: candidate_effect_id(latch_key, bucket),
      rule_id: Map.get(context, :kernel_id),
      rule_version: @rule_version,
      affected_object_id: Map.get(attrs, :macro_index),
      quantized_condition_bucket: bucket,
      source_seq: Map.get(context, :source_tick, 0),
      latch_status: :latched,
      state_class: :runtime_authoritative,
      payload_version: @payload_version,
      payload: attrs
    )
  end

  # 稳定 candidate_effect_id(RULE-16):latch_key + quantized bucket 的确定性串。
  defp candidate_effect_id(latch_key, bucket) do
    {{cell_id, chunk_coord}, rule_id, object_id, attribute} = latch_key

    "ce:#{inspect(cell_id)}:#{inspect(chunk_coord)}:#{rule_id}:#{object_id}:#{attribute}:#{bucket}"
  end

  # ---- 提交执行(经 ChunkProcess 权威写) -----------------------------------

  defp commit_field_effects(_chunk_pid, [], _context), do: :ok

  defp commit_field_effects(chunk_pid, effects, context) do
    case ChunkProcess.apply_field_effects(chunk_pid, effects, context) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        CliObserve.emit("voxel_system_actor_commit_failed", fn ->
          %{
            region_id: Map.get(context, :region_id),
            chunk_coord: Map.get(context, :chunk_coord),
            kernel_id: Map.get(context, :kernel_id),
            effect_count: length(effects),
            reason: reason
          }
        end)

        {:error, reason}
    end
  rescue
    error ->
      CliObserve.emit("voxel_system_actor_commit_crashed", fn ->
        %{
          region_id: Map.get(context, :region_id),
          kernel_id: Map.get(context, :kernel_id),
          error: Exception.message(error)
        }
      end)

      {:error, :commit_crashed}
  end

  defp emit_latched(nil, _context), do: :ok

  defp emit_latched(%CandidateEffect{} = candidate, context) do
    CliObserve.emit("voxel_candidate_effect_latched", fn ->
      %{
        candidate_effect_id: candidate.candidate_effect_id,
        rule_id: candidate.rule_id,
        affected_object_id: candidate.affected_object_id,
        quantized_condition_bucket: candidate.quantized_condition_bucket,
        region_id: Map.get(context, :region_id),
        chunk_coord: Map.get(context, :chunk_coord)
      }
    end)
  end
end

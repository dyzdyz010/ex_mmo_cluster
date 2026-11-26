defmodule SceneServer.Movement.PlayerWire do
  @moduledoc """
  `SceneServer.Movement.Player` 的纯协议投影与流送窗口几何辅助。

  无进程、无可变状态：只负责把 Player 持有的权威快照、身体报告与碰撞域投影为
  `MmoContracts.Voxel` / `MmoContracts.Session` wire 结构体及 World 接触几何参数，
  所有时序与发送所有权仍归唯一 owner `SceneServer.Movement.Player`。
  """

  alias MmoContracts.{Session, Voxel}
  alias SceneServer.Body

  @type l0_coord :: {integer(), integer(), integer()}
  @type l0_box :: {l0_coord(), l0_coord()}
  @type vec3 :: {float(), float(), float()}
  @type window_domain :: %{
          l0_box: l0_box(),
          bounds: {vec3(), vec3()},
          travel: {vec3(), vec3()}
        }
  @type property_batch_stats :: %{
          states: non_neg_integer(),
          epochs: non_neg_integer(),
          body_bytes: non_neg_integer()
        }

  @doc "按快照的半开 L0 区域盒计算物理边界与内缩 1/4 tile 的合法行程盒。"
  @spec window_domain(%{l0_min: l0_coord(), l0_max_exclusive: l0_coord()}) :: window_domain()
  def window_domain(snapshot) do
    extent = Voxel.Payload.extent() - 2
    min = snapshot.l0_min |> Tuple.to_list() |> Enum.map(&(&1 * extent / 1)) |> List.to_tuple()

    max =
      snapshot.l0_max_exclusive
      |> Tuple.to_list()
      |> Enum.map(&(&1 * extent / 1))
      |> List.to_tuple()

    %{
      l0_box: {snapshot.l0_min, snapshot.l0_max_exclusive},
      bounds: {min, max},
      travel: {
        min |> Tuple.to_list() |> Enum.map(&(&1 + extent / 4)) |> List.to_tuple(),
        max |> Tuple.to_list() |> Enum.map(&(&1 - extent / 4)) |> List.to_tuple()
      }
    }
  end

  @doc "将碰撞域物理边界投影回半开 L0 区域盒，供增量属性批编码使用。"
  @spec property_box(%{bounds: {vec3(), vec3()}}) :: l0_box()
  def property_box(%{bounds: {low, high}}) do
    extent = Voxel.Payload.extent() - 2

    {low |> Tuple.to_list() |> Enum.map(&floor(&1 / extent)) |> List.to_tuple(),
     high |> Tuple.to_list() |> Enum.map(&floor(&1 / extent)) |> List.to_tuple()}
  end

  @doc "构建权威初始化的 `CanonicalBootstrap` 消息。"
  @spec canonical_bootstrap(
          Session.Identity.t(),
          non_neg_integer(),
          non_neg_integer(),
          map(),
          {vec3(), vec3()}
        ) :: Voxel.CanonicalBootstrap.t()
  def canonical_bootstrap(identity, content_version, revision, snapshot, travel) do
    %Voxel.CanonicalBootstrap{
      identity: identity,
      content_version: content_version,
      collision_revision: revision,
      transaction_seq: snapshot.transaction_seq,
      l0_min: snapshot.l0_min,
      l0_max_exclusive: snapshot.l0_max_exclusive,
      travel_min_m: elem(travel, 0),
      travel_max_exclusive_m: elem(travel, 1),
      regions: snapshot.regions
    }
  end

  @doc "构建流送碰撞窗口更新的 `CollisionWindow` 消息。"
  @spec collision_window(
          Session.Identity.t(),
          non_neg_integer(),
          non_neg_integer(),
          map(),
          non_neg_integer(),
          window_domain()
        ) :: Voxel.CollisionWindow.t()
  def collision_window(identity, content_version, apply_tick, snapshot, revision, domain) do
    %Voxel.CollisionWindow{
      identity: identity,
      apply_tick: apply_tick,
      content_version: content_version,
      collision_revision: revision,
      transaction_seq: snapshot.transaction_seq,
      l0_min: snapshot.l0_min,
      l0_max_exclusive: snapshot.l0_max_exclusive,
      travel_min_m: elem(domain.travel, 0),
      travel_max_exclusive_m: elem(domain.travel, 1),
      regions: snapshot.regions
    }
  end

  @doc "构建碰撞 chunk 生效通知 `CollisionApplied` 消息。"
  @spec collision_applied(
          Session.Identity.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [%{coord: l0_coord()}]
        ) :: Voxel.CollisionApplied.t()
  def collision_applied(identity, apply_tick, transaction_seq, collision_revision, chunks) do
    %Voxel.CollisionApplied{
      identity: identity,
      collision_revision: collision_revision,
      transaction_seq: transaction_seq,
      apply_tick: apply_tick,
      changed_chunks: Enum.map(chunks, & &1.coord)
    }
  end

  @doc "构建复活或信标传送的 `Relocate` 消息。"
  @spec relocate(Session.Identity.t(), non_neg_integer(), Session.State.t()) ::
          Voxel.Relocate.t()
  def relocate(identity, apply_tick, spawned_state) do
    %Voxel.Relocate{
      identity: identity,
      apply_tick: apply_tick,
      state: spawned_state
    }
  end

  @doc """
  构建属性批 `PropertyBatch` 消息及其可观测字节统计；输入不含 `:property_context` 时返回 `:skip`。
  """
  @spec property_batch(Session.Identity.t(), map(), boolean(), l0_box()) ::
          :skip | {:ok, Voxel.PropertyBatch.t(), property_batch_stats()}
  def property_batch(identity, value, complete, {low, high}) do
    case Map.fetch(value, :property_context) do
      :error ->
        :skip

      {:ok, context} ->
        rows = Map.get(value, :property_states, [])

        epochs =
          for {{x, y, z}, epoch} <- Enum.sort(Map.get(value, :epochs, %{})),
              into: <<>>,
              do: <<x::signed-32, y::signed-32, z::signed-32, epoch::64>>

        states =
          Enum.map(rows, fn row ->
            {:ok, bytes} = Voxel.Codec.encode({:voxel_property_state, row})
            IO.iodata_to_binary(bytes)
          end)

        message = %Voxel.PropertyBatch{
          identity: identity,
          transaction_seq: Map.get(value, :transaction_seq, Map.get(value, :seq)),
          l0_min: low,
          l0_max_exclusive: high,
          complete: if(complete, do: 1, else: 0),
          hp_enabled: if(context.hp_enabled, do: 1, else: 0),
          digest: context.digest,
          thermal_enabled: if(context.thermal_enabled, do: 1, else: 0),
          ambient_kelvin: context.ambient_kelvin,
          epochs: epochs,
          states: states,
          protection: Voxel.Codec.encode_protection(Map.get(value, :protection, %{})),
          semblances: Voxel.Codec.encode_semblances(Map.get(value, :semblances, %{})),
          casts: Voxel.Codec.encode_casts(Map.get(value, :casts, %{}))
        }

        stats = %{
          states: length(rows),
          epochs: div(byte_size(epochs), 20),
          body_bytes: byte_size(epochs) + Enum.sum(Enum.map(states, &byte_size/1))
        }

        {:ok, message, stats}
    end
  end

  @doc "将 `Body.report/2` 结果投影为可靠控制通道的 `Session.BodyState` 消息。"
  @spec body_state(Session.Identity.t(), map()) :: Session.BodyState.t()
  def body_state(identity, report) do
    %Session.BodyState{
      identity: identity,
      life: report.life,
      recoverable: report.recoverable,
      status: report.status,
      core_k: report.core_k,
      skin_k: report.skin_k,
      protein_g: report.protein_g,
      injuries:
        for(
          {tag, n, heal, left} <- report.injuries,
          do: %Session.BodyInjury{tag: tag, severity: n, heal: heal, remaining_s: left}
        )
    }
  end

  @doc "按角色当前位置、胶囊配置与身体热状态投影报给 World 的接触几何与导热参数。"
  @spec body_contact(vec3(), map(), Body.t(), map()) :: map()
  def body_contact({x, y, z}, profile, body, body_heat) do
    %{
      feet: {x, y - profile.half_height, z},
      height: 2 * profile.half_height,
      radius: profile.radius,
      skin_k: body.skin_k,
      capacity: Body.skin_capacity_j_per_k(),
      area: Body.params().area_m2,
      tissue_k: body.tissue_k + body_heat.tissue_j / Body.tissue_capacity_j_per_k(),
      tissue_capacity: Body.tissue_capacity_j_per_k(),
      tissue_g: Body.params().contact_tissue_m2 * Body.Thermo.contact_tissue_w_per_m2_k(body)
    }
  end
end

defmodule SceneServer.Voxel.DiffusionSimulatorTest do
  @moduledoc """
  Phase 5.F DiffusionSimulator unit tests.

  覆盖：
    1. simulator_id 由 attribute_name 派生
    2. 单 macro 热源 + 6 邻居 default → 中心降温 + 邻居升温 + 总热量守恒
    3. 稳态：所有 macro 同温 → 1 tick 后温度不变
    4. 绝热边界 (neighbor_lookup=nil)：边界 macro 变化 < 内部 macro
    5. deterministic：同 input → 同 output
    6. tick 返回 env_delta，含 macro_index + field_mask + temperature + source_hash
    7. moisture simulator instance：同算法 attribute_name="moisture" α=0.02

  本测试不依赖 ChunkProcess / DB，纯 Storage + DiffusionSimulator。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.DiffusionSimulator
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  describe "simulator_id/0 derivation" do
    test "temperature simulator id is :diffusion_temperature" do
      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}
      assert DiffusionSimulator.simulator_id_for(sim) == :diffusion_temperature
    end

    test "moisture simulator id is :diffusion_moisture" do
      sim = %DiffusionSimulator{attribute_name: "moisture", alpha: 0.02, dt: 0.1}
      assert DiffusionSimulator.simulator_id_for(sim) == :diffusion_moisture
    end
  end

  describe "DiffusionSimulator.tick/3 (single hot source)" do
    test "hot center cell cools, 6 neighbors warm up, total roughly conserved" do
      # storage with hot temperature at (1,1,1) and default elsewhere
      hot_center_coord = {1, 1, 1}
      hot_macro_index = Types.macro_index!(hot_center_coord)

      storage = build_storage_with_temperature(%{hot_macro_index => 1000})

      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(hot_macro_index, DirtyMacroBounds.reason_attribute_write())
        # Expand to include the 6 neighbors so simulator iterates over them.
        |> DirtyMacroBounds.add_macro({0, 1, 1}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({2, 1, 1}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 0, 1}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 2, 1}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 1, 0}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 1, 2}, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _next_state, %{cells_updated: cells, env_delta: env_delta}} =
               DiffusionSimulator.tick(nil, dirty, env, sim)

      assert cells >= 7

      # env_delta carries the macro-level updates
      assert is_map(env_delta)
      assert env_delta.chunk_coord == {0, 0, 0}
      ops = env_delta.ops
      assert is_list(ops) and length(ops) >= 7

      # Build a map of macro_index -> op for easy assertion.
      op_map = Map.new(ops, fn op -> {op.macro_index, op} end)

      hot_op = Map.fetch!(op_map, hot_macro_index)
      assert hot_op.field_mask == 0x01
      assert Map.has_key?(hot_op, :temperature)
      # Center cooled (was 1000)
      assert hot_op.temperature < 1000
      assert hot_op.temperature > 0
      assert is_integer(hot_op.source_hash)

      # Neighbors warmed up (were 0 default)
      neighbors = [
        Types.macro_index!({0, 1, 1}),
        Types.macro_index!({2, 1, 1}),
        Types.macro_index!({1, 0, 1}),
        Types.macro_index!({1, 2, 1}),
        Types.macro_index!({1, 1, 0}),
        Types.macro_index!({1, 1, 2})
      ]

      neighbor_temps =
        Enum.map(neighbors, fn idx ->
          op = Map.fetch!(op_map, idx)
          op.temperature
        end)

      Enum.each(neighbor_temps, fn t -> assert t > 0 end)

      # Total heat conservation (within rounding tolerance):
      # original total: 1000 (hot) + 6 * 0 = 1000
      # new total: hot_op.temperature + sum(neighbor_temps)
      new_total = hot_op.temperature + Enum.sum(neighbor_temps)
      # Allow ±10 for i16 rounding at α*dt = 0.005 step
      assert abs(new_total - 1000) <= 10
    end
  end

  describe "DiffusionSimulator.tick/3 (steady state)" do
    test "uniform default temperature stays unchanged after one tick" do
      storage = build_storage_with_temperature(%{})

      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro({3, 3, 3}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({4, 4, 4}, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _, %{env_delta: env_delta}} = DiffusionSimulator.tick(nil, dirty, env, sim)
      # All cells should be at 0 (uniform default), so either no ops or all 0 ops.
      Enum.each(env_delta.ops, fn op ->
        assert op.temperature == 0
      end)
    end
  end

  describe "DiffusionSimulator.tick/3 (adiabatic boundary)" do
    test "boundary macro at x=0 with neighbor_lookup=nil only exchanges with in-chunk neighbors" do
      # Hot source at corner (0,0,0): only 3 in-chunk neighbors visible
      # (1,0,0) / (0,1,0) / (0,0,1)
      corner_index = Types.macro_index!({0, 0, 0})
      storage = build_storage_with_temperature(%{corner_index => 1000})

      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(corner_index, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 0, 0}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({0, 1, 0}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({0, 0, 1}, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _, %{env_delta: env_delta}} = DiffusionSimulator.tick(nil, dirty, env, sim)

      op_map = Map.new(env_delta.ops, fn op -> {op.macro_index, op} end)
      corner_op = Map.fetch!(op_map, corner_index)
      # Corner cooled (had 3 absent neighbors with Neumann/insulating semantics).
      # corner: 1000 + α*dt * (3*0 + 3*"self" - 6*1000) = 1000 + 0.005 * (-3000) = 985
      # (Neumann absent neighbor = self → contributes self - self = 0)
      assert corner_op.temperature < 1000
      assert corner_op.temperature > 980

      # The total heat still conserved with the 3 visible neighbors (and the 3 absent
      # neighbors are no-op under Neumann fallback).
      neighbor_temps =
        [
          Types.macro_index!({1, 0, 0}),
          Types.macro_index!({0, 1, 0}),
          Types.macro_index!({0, 0, 1})
        ]
        |> Enum.map(fn idx -> Map.fetch!(op_map, idx).temperature end)

      new_total = corner_op.temperature + Enum.sum(neighbor_temps)
      # Adiabatic system: total conserved within rounding
      assert abs(new_total - 1000) <= 10
    end
  end

  describe "DiffusionSimulator.tick/3 (deterministic)" do
    test "same input → same env_delta ops byte-stable" do
      hot = Types.macro_index!({2, 2, 2})
      storage = build_storage_with_temperature(%{hot => 500})

      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(hot, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _, %{env_delta: delta1}} = DiffusionSimulator.tick(nil, dirty, env, sim)
      assert {:ok, _, %{env_delta: delta2}} = DiffusionSimulator.tick(nil, dirty, env, sim)
      assert delta1.ops == delta2.ops
    end

    test "source_hash differs across distinct macro_index but reproducible per cell" do
      hot1 = Types.macro_index!({2, 2, 2})
      hot2 = Types.macro_index!({3, 3, 3})

      storage = build_storage_with_temperature(%{hot1 => 500, hot2 => 700})

      sim = %DiffusionSimulator{attribute_name: "temperature", alpha: 0.05, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(hot1, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro(hot2, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _, %{env_delta: env_delta}} = DiffusionSimulator.tick(nil, dirty, env, sim)
      op_map = Map.new(env_delta.ops, fn op -> {op.macro_index, op} end)

      # Two distinct macro indices should produce different source_hash values
      # since macro_index is part of the hash.
      assert op_map[hot1].source_hash != op_map[hot2].source_hash
    end
  end

  describe "DiffusionSimulator.tick/3 (moisture instance)" do
    test "moisture simulator writes field_mask=0x02 with moisture field" do
      hot = Types.macro_index!({2, 2, 2})
      storage = build_storage_with_moisture(%{hot => 800})

      sim = %DiffusionSimulator{attribute_name: "moisture", alpha: 0.02, dt: 0.1}

      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(hot, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({1, 2, 2}, DirtyMacroBounds.reason_attribute_write())

      env = %{
        chunk_coord: {0, 0, 0},
        logical_scene_id: 1,
        lease_token: nil,
        storage: storage,
        neighbor_lookup: nil
      }

      assert {:ok, _, %{env_delta: env_delta}} = DiffusionSimulator.tick(nil, dirty, env, sim)
      assert length(env_delta.ops) >= 1

      Enum.each(env_delta.ops, fn op ->
        assert op.field_mask == 0x02
        assert Map.has_key?(op, :moisture)
        refute Map.has_key?(op, :temperature)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # Build a 16³ macro chunk storage where the given `temperatures` map
  # (macro_index → i16 raw) attaches a MacroEnvironmentSummary to those macro
  # cells; all others have no environment_index (default 0 → simulator reads
  # as default 0 i16).
  defp build_storage_with_temperature(temperatures) when is_map(temperatures) do
    build_storage_with_env(temperatures, :temperature)
  end

  defp build_storage_with_moisture(values) when is_map(values) do
    build_storage_with_env(values, :moisture)
  end

  defp build_storage_with_env(values, field) when is_map(values) do
    # Build the env summaries pool in stable order of macro_index ascending.
    indexed =
      values
      |> Map.to_list()
      |> Enum.sort_by(fn {idx, _v} -> idx end)

    summaries =
      Enum.map(indexed, fn {_idx, v} ->
        case field do
          :temperature -> MacroEnvironmentSummary.new(current_temperature: v, field_mask: 0x01)
          :moisture -> MacroEnvironmentSummary.new(current_moisture: v, field_mask: 0x02)
        end
      end)

    # Build 4096 macro headers, attaching environment_index for entries with summaries.
    indexed_with_env_idx =
      indexed
      |> Enum.with_index()
      |> Map.new(fn {{macro_idx, _v}, env_idx} -> {macro_idx, env_idx} end)

    macro_headers =
      for i <- 0..4095 do
        case Map.fetch(indexed_with_env_idx, i) do
          {:ok, env_idx} -> MacroCellHeader.empty(environment_index: env_idx)
          :error -> MacroCellHeader.empty()
        end
      end

    Storage.normalize!(%Storage{
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0},
      macro_headers: macro_headers,
      environment_summaries: summaries
    })
  end
end

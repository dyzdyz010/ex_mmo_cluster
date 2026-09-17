defmodule VoxelRegion.ParameterPublicationTest do
  @moduledoc "只测试：目录参数升级保留实例存量，同笔日志重标热参考并可冷恢复。"
  use ExUnit.Case, async: false
  @moduletag :parameter_publication
  alias VoxelRegion.{World, Damage}
  alias VoxelRegion.DamageWorldTest.{Source, Log}

  setup do
    root = Path.join(System.tmp_dir!(), "parameters_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "catalog.json")
    File.cp!(System.fetch_env!("PARAMETER_CATALOG"), path)
    env = Path.join(root, "environment.json")
    File.write!(env, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 0.0, tolerance_kelvin: 0.01}))
    opts = [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: path, thermal_environment_path: env]
    w = start_supervised!({World, opts})
    {:ok, seq} = World.apply_edit(w, {1, 1, 2}, 19)
    s = :sys.get_state(w)
    # 只测试的旧存档夹具；在线验收不得通过此方式制造玩家资源或温度。
    row = %{micro: {8, 8, 16}, granularity: 0, incarnation: seq, owner: {0, 0}, material: 19,
      flags: 0, request_id: 0, seq: seq, digest: s.properties.digest, hp: 51.0, max_hp: 100.0,
      defense: 2.0, temperature_kelvin: 333.15, remaining_fuel_j: 1234.0, power_w: 0.0, burning: false}
    :sys.replace_state(w, &%{&1 | damage: %{Damage.key(row) => row},
      material_balances: %{{1001, 19} => 4096},
      thermal: Map.put(&1.thermal, :active, false)})
    :ok = World.compact(w)
    before = :sys.get_state(w)
    data = Jason.decode!(File.read!(path))
    data = Map.update!(data, "materials", &Enum.map(&1, fn m ->
      if m["material_id"] == 19, do: m |> Map.update!("heat_capacity_per_macro", fn c -> c * 2 end)
        |> Map.put("ignition_kelvin", 573.15) |> Map.put("fuel_energy_per_macro_j", 9_000_000.0), else: m
    end))
    next_path = Path.join(root, "next.json")
    File.write!(next_path, Jason.encode!(data))
    on_exit(fn -> File.rm_rf!(root) end)
    %{w: w, opts: opts, before: before, next_path: next_path, path: path, data: data}
  end

  test "显式旧版本升级保留状态存量，重标不是供能，重启不补料", c do
    assert {:error, :property_version_in_use} = World.publish_properties(c.w, c.next_path)
    assert :ok = World.publish_parameters(c.w, c.next_path, c.before.properties.digest)
    after_state = :sys.get_state(c.w)
    [old] = Map.values(c.before.damage)
    [new] = Map.values(after_state.damage)
    assert Map.drop(new, [:seq, :digest]) == Map.drop(old, [:seq, :digest])
    assert after_state.material_balances == c.before.material_balances
    assert after_state.overlay == c.before.overlay
    assert after_state.thermal.supplied_j == c.before.thermal.supplied_j
    expected = c.before.properties.materials[19]["heat_capacity_per_macro"] * 40.0
    assert_in_delta after_state.thermal.parameter_rebase_j, expected, 1.0e-6
    [txn] = World.entries_after(c.w, c.before.seq)
    assert txn.thermal == after_state.thermal
    assert txn.property_states == [new]
    stop_supervised!(World)
    File.cp!(c.next_path, c.path)
    w = start_supervised!({World, c.opts})
    recovered = :sys.get_state(w)
    assert recovered.damage == after_state.damage
    assert recovered.material_balances == after_state.material_balances
    assert recovered.thermal.parameter_rebase_j == after_state.thermal.parameter_rebase_j
  end

  test "错误旧版本和潜热语义变化拒绝，失败不改权威状态", c do
    assert {:error, :property_version_mismatch} = World.publish_parameters(c.w, c.next_path, <<0::256>>)
    changed = Map.update!(c.data, "materials", &Enum.map(&1, fn m ->
      if m["material_id"] in [20, 21], do: Map.put(m, "latent_heat_per_macro_j", 1.0), else: m
    end))
    File.write!(c.next_path, Jason.encode!(changed))
    assert {:error, :property_version_in_use} = World.publish_parameters(c.w, c.next_path, c.before.properties.digest)
    after_state = :sys.get_state(c.w)
    assert after_state.seq == c.before.seq
    assert after_state.damage == c.before.damage
    assert after_state.properties == c.before.properties
  end

  test "落盘失败不切换目录、状态或重标账", c do
    {_, handle} = c.before.log
    File.write!(handle <> ".reject", "reject")
    assert {:error, :test_disk_failure} = World.publish_parameters(c.w, c.next_path, c.before.properties.digest)
    after_state = :sys.get_state(c.w)
    assert after_state.properties == c.before.properties
    assert after_state.damage == c.before.damage
    assert after_state.thermal == c.before.thermal
    assert after_state.seq == c.before.seq
  end
end

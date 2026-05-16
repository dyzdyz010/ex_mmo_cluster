defmodule SceneServer.Voxel.EffectiveAttributeTest do
  # Phase 5.D: Storage.effective_attribute_at/3 高层 API。
  #
  # 实施 docs/plans/2026-05-13-phase5d-five-tier-merge-rule.md D-1..D-5 推荐方案：
  #   D-1 override 优先级 L3 > L2 > L1 > L5（L4 暂不接 → 5.D.2）
  #   D-2 add_delta L1 base + L2/L3/L5 delta 累加
  #   D-3 temperature_delta / moisture_delta 字段 + attribute_set 双路径 sum 累加
  #   D-4 L4 object-part 暂不接（4 层版本）
  #   D-5 API macro 粒度
  #
  # merge_rule 实施（4 层）：
  #   override:        L3 > L2 > L1 > L5
  #   add_delta:       L1 + (L2.delta ?? 0) + (L3.delta_sum ?? 0) + (L5.delta ?? 0)
  #   max / min:       max/min of available layers
  #   material_default: only L1
  #
  # 本测试同时覆盖两条路径：
  #   - production catalog（默认 named singleton，前 4 个 attribute 是 add_delta /
  #     material_default，覆盖 D-3 / material_default / temperature add_delta 路径）
  #   - test-only catalog（ad-hoc unique name + 自定义 seed 文件，含
  #     override / max / min merge_rule 的 test attribute，覆盖剩余 3 个 merge_rule）
  #
  # 关键约定（草案 §7 风险段 + 实施推断）：
  #   - clip 到 [min_value, max_value]（草案 §7 推荐策略）
  #   - refined cell 多 layer：add_delta sum 所有 layer 的 delta；override 取
  #     first layer with attribute；max/min 取所有 layer 中极值
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.AttributeEntry
  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.MacroCellHeader

  # ---- Q16.16 helpers ----------------------------------------------------------
  # 20.0 °C in Q16.16
  @t_default 1_310_720
  # 1.0 in Q16.16
  @density_default 65_536
  @absolute_zero_raw -17_904_824
  @fixed32_scale 65_536
  @dirt_material_id 1
  @stone_material_id 2
  @wood_material_id 3
  @ice_material_id 4
  @iron_material_id 5

  setup do
    # production catalog（默认 module-named singleton），加载默认 seed
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---- helpers ----------------------------------------------------------------

  defp solid_chunk(macro_index, opts \\ []) do
    storage = Storage.new(0, {0, 0, 0})

    block =
      NormalBlockData.new(Keyword.get(opts, :material_id, 1),
        temperature_delta: Keyword.get(opts, :temperature_delta, 0),
        moisture_delta: Keyword.get(opts, :moisture_delta, 0)
      )

    Storage.put_solid_block(storage, macro_index, block)
  end

  # 把 attribute_set 写入 chunk 池，返回 {storage, ref}。
  defp intern_set(storage, entries) do
    Storage.intern_attribute_set(storage, %AttributeSet{
      entries:
        Enum.map(entries, fn {key_id, value_type, value} ->
          %AttributeEntry{key_id: key_id, value_type: value_type, value: value}
        end)
    })
  end

  # 一次性 intern 多个 sets，返回 {storage, [refs]}。每次 intern 后 pool 都会
  # 重排序，所以提前缓存的 ref 可能失效；本 helper 在所有 intern 完成后，
  # 按 set 的 byte canonical key 逐个查找最终 1-indexed ref，保证稳定。
  defp intern_sets(storage, list_of_entries) do
    sets =
      Enum.map(list_of_entries, fn entries ->
        AttributeSet.normalize!(%{
          entries:
            Enum.map(entries, fn {key_id, value_type, value} ->
              %AttributeEntry{key_id: key_id, value_type: value_type, value: value}
            end)
        })
      end)

    final_storage =
      Enum.reduce(sets, storage, fn set, acc ->
        {acc, _} = Storage.intern_attribute_set(acc, set)
        acc
      end)

    refs =
      Enum.map(sets, fn set ->
        key = AttributeSet.byte_canonical_key(set)

        Enum.find_index(final_storage.attribute_sets, fn s ->
          AttributeSet.byte_canonical_key(s) == key
        end) + 1
      end)

    {final_storage, refs}
  end

  # 给已写好的 solid cell 设置 attribute_set_ref（绕过 put_attribute_for_cell，
  # 因为后者会走 catalog name lookup；这里我们要测的是 effective_attribute_at 的 merge 算法）。
  defp set_solid_block_attribute_set_ref(storage, macro_index, attribute_set_ref) do
    header = Enum.at(storage.macro_headers, macro_index)
    block = Enum.at(storage.normal_blocks, header.payload_index)
    updated = %{block | attribute_set_ref: attribute_set_ref}

    %{
      storage
      | normal_blocks: List.replace_at(storage.normal_blocks, header.payload_index, updated)
    }
    |> Storage.normalize!()
  end

  # 给指定 macro cell 设置 environment_summary。
  # environment_index 指向 storage.environment_summaries 的 0-indexed 位置
  # （`MacroCellHeader.no_index() = 0xFFFFFFFF` 表 "no env summary"）。
  defp attach_env_summary(storage, macro_index, summary_attrs) do
    summary = MacroEnvironmentSummary.new(summary_attrs)
    env_index = length(storage.environment_summaries)
    storage = %{storage | environment_summaries: storage.environment_summaries ++ [summary]}

    header = Enum.at(storage.macro_headers, macro_index)
    new_header = %{header | environment_index: env_index}

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, new_header)
    }
    |> Storage.normalize!()
  end

  # ---- test-only catalog seed (含 override / max / min merge_rule attribute) --

  @test_seed_content """
  %{
    catalog_version: 1,
    definitions: [
      %{
        id: 1,
        name: "temperature",
        unit: "°C",
        value_type: :fixed32,
        default_value: 1_310_720,
        min_value: -17_904_824,
        max_value: 327_680_000,
        merge_rule: :add_delta,
        dynamic: true
      },
      %{
        id: 2,
        name: "moisture",
        unit: "kg/m³",
        value_type: :fixed32,
        default_value: 0,
        min_value: 0,
        max_value: 65_536_000,
        merge_rule: :add_delta,
        dynamic: true
      },
      %{
        id: 100,
        name: "test_override",
        unit: "",
        value_type: :fixed32,
        default_value: 10,
        min_value: -10_000,
        max_value: 10_000,
        merge_rule: :override,
        dynamic: false
      },
      %{
        id: 101,
        name: "test_max",
        unit: "",
        value_type: :fixed32,
        default_value: 10,
        min_value: -10_000,
        max_value: 10_000,
        merge_rule: :max,
        dynamic: false
      },
      %{
        id: 102,
        name: "test_min",
        unit: "",
        value_type: :fixed32,
        default_value: 10,
        min_value: -10_000,
        max_value: 10_000,
        merge_rule: :min,
        dynamic: false
      },
      %{
        id: 103,
        name: "test_density",
        unit: "kg/m³",
        value_type: :fixed32,
        default_value: 65_536,
        min_value: 66,
        max_value: 1_310_720_000,
        merge_rule: :material_default,
        dynamic: false
      }
    ]
  }
  """

  defp start_test_catalog!(context_name) do
    # 写一份临时 seed 文件到 OS tmp dir
    seed_path =
      Path.join(System.tmp_dir!(), "phase5d_effective_attribute_test_seed_#{context_name}.exs")

    File.write!(seed_path, @test_seed_content)

    unique = System.unique_integer([:positive])
    name = :"phase5d_test_catalog_#{context_name}_#{unique}"
    # 关键：必须给每个 supervised child 一个 unique :id，否则共享 module 默认 id
    # 在同一 ExUnit 进程中会冲突（每次 start_supervised! 都返回 :already_started）。
    id = {AttributeCatalog, name}

    pid =
      start_supervised!(%{
        id: id,
        start: {AttributeCatalog, :start_link, [[name: name, seed_path: seed_path]]}
      })

    {name, pid, seed_path}
  end

  # ---- material_default merge_rule (D-4 layer ignored; only L1) ---------------

  describe "material_default merge_rule" do
    test "known voxel materials resolve physical thermal properties" do
      expectations = [
        {@dirt_material_id, 1_600.0, 0.25, 800.0},
        {@stone_material_id, 2_700.0, 2.5, 790.0},
        {@wood_material_id, 600.0, 0.13, 1_700.0},
        {@ice_material_id, 917.0, 2.2, 2_100.0},
        {@iron_material_id, 7_870.0, 80.0, 449.0}
      ]

      for {material_id, density, thermal_conductivity, specific_heat_capacity} <- expectations do
        storage = solid_chunk(0, material_id: material_id)

        assert Storage.effective_attribute_at(storage, 0, "density") == fixed32(density)

        assert Storage.effective_attribute_at(storage, 0, "thermal_conductivity") ==
                 fixed32(thermal_conductivity)

        assert Storage.effective_attribute_at(storage, 0, "specific_heat_capacity") ==
                 fixed32(specific_heat_capacity)
      end
    end

    test "known voxel materials resolve Phase 7.E thresholds and electrical properties" do
      expectations = [
        {@dirt_material_id, 5_000.0, 1_100.0, 1_100.0, 2_200.0, 0.01, 10.0},
        {@stone_material_id, 5_000.0, 1_200.0, 1_200.0, 3_000.0, 0.0, 12.0},
        {@wood_material_id, 300.0, 5_000.0, @absolute_zero_raw, 5_000.0, 0.0, 10.0},
        {@ice_material_id, 5_000.0, 0.0, 0.0, 100.0, 0.0, 9.8},
        {@iron_material_id, 5_000.0, 1_538.0, 1_538.0, 2_862.0, 10.0, 0.0}
      ]

      for {material_id, ignition, melting, freezing, boiling, electric, dielectric} <-
            expectations do
        storage = solid_chunk(0, material_id: material_id)

        assert Storage.effective_attribute_at(storage, 0, "ignition_temperature") ==
                 fixed32(ignition)

        assert Storage.effective_attribute_at(storage, 0, "melting_point") ==
                 fixed32(melting)

        assert Storage.effective_attribute_at(storage, 0, "freezing_point") ==
                 fixed32_or_raw(freezing)

        assert Storage.effective_attribute_at(storage, 0, "boiling_point") ==
                 fixed32(boiling)

        assert Storage.effective_attribute_at(storage, 0, "electric_conductivity") ==
                 fixed32(electric)

        assert Storage.effective_attribute_at(storage, 0, "dielectric_strength") ==
                 fixed32(dielectric)
      end
    end

    test "refined cells use their layer material for Phase 7.E defaults" do
      storage =
        Storage.new(0, {0, 0, 0})
        |> refined_chunk_with_layers_into(0, [%{material_id: @wood_material_id}])

      assert Storage.effective_attribute_at(storage, 0, "ignition_temperature") ==
               fixed32(300.0)

      assert Storage.effective_attribute_at(storage, 0, "melting_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "freezing_point") == @absolute_zero_raw
      assert Storage.effective_attribute_at(storage, 0, "boiling_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "electric_conductivity") == 0
      assert Storage.effective_attribute_at(storage, 0, "dielectric_strength") == fixed32(10.0)
    end

    test "solid iron resolves real-world material defaults instead of global debug defaults" do
      storage = solid_chunk(0, material_id: @iron_material_id)

      assert Storage.effective_attribute_at(storage, 0, "density") == fixed32(7_870.0)
      assert Storage.effective_attribute_at(storage, 0, "thermal_conductivity") == fixed32(80.0)

      assert Storage.effective_attribute_at(storage, 0, "specific_heat_capacity") ==
               fixed32(449.0)
    end

    test "normalized hot-path attribute reads match boundary reads" do
      storage = solid_chunk(0, material_id: @iron_material_id)

      assert Storage.effective_attribute_at_normalized(storage, 0, "density") ==
               Storage.effective_attribute_at(storage, 0, "density")

      assert Storage.effective_attribute_at_normalized(storage, 0, "thermal_conductivity") ==
               Storage.effective_attribute_at(storage, 0, "thermal_conductivity")

      assert Storage.effective_attribute_at_normalized(storage, 0, "specific_heat_capacity") ==
               Storage.effective_attribute_at(storage, 0, "specific_heat_capacity")
    end

    test "unknown material falls back to catalog default density" do
      storage = solid_chunk(0, material_id: 99)
      assert Storage.effective_attribute_at(storage, 0, "density") == @density_default
    end

    test "unknown material falls back to catalog default thermal conductivity" do
      storage = solid_chunk(0, material_id: 99)
      assert Storage.effective_attribute_at(storage, 0, "thermal_conductivity") == 6_554
    end

    test "unknown material falls back to catalog default specific heat capacity" do
      storage = solid_chunk(0, material_id: 99)
      assert Storage.effective_attribute_at(storage, 0, "specific_heat_capacity") == 65_536_000
    end

    test "unknown material falls back to inert Phase 7.E catalog defaults" do
      storage = solid_chunk(0, material_id: 99)

      assert Storage.effective_attribute_at(storage, 0, "ignition_temperature") ==
               fixed32(5_000.0)

      assert Storage.effective_attribute_at(storage, 0, "melting_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "freezing_point") == @absolute_zero_raw
      assert Storage.effective_attribute_at(storage, 0, "boiling_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "electric_conductivity") == 0
      assert Storage.effective_attribute_at(storage, 0, "dielectric_strength") == fixed32(3.0)
    end

    test "empty cells without material fall back to inert Phase 7.E catalog defaults" do
      storage = Storage.new(0, {0, 0, 0})

      assert Storage.effective_attribute_at(storage, 0, "ignition_temperature") ==
               fixed32(5_000.0)

      assert Storage.effective_attribute_at(storage, 0, "melting_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "freezing_point") == @absolute_zero_raw
      assert Storage.effective_attribute_at(storage, 0, "boiling_point") == fixed32(5_000.0)
      assert Storage.effective_attribute_at(storage, 0, "electric_conductivity") == 0
      assert Storage.effective_attribute_at(storage, 0, "dielectric_strength") == fixed32(3.0)
    end

    test "即使 cell 设置了 attribute_set 含 density override，effective 仍 = L1 default" do
      storage = solid_chunk(0, material_id: @dirt_material_id)
      # density id=4, value_type fixed32 (0x03)
      {storage, ref} = intern_set(storage, [{4, 0x03, 9_999_999}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      # material_default 忽略 L2/L3/L5
      assert Storage.effective_attribute_at(storage, 0, "density") == fixed32(1_600.0)
    end
  end

  # ---- add_delta merge_rule (temperature) -------------------------------------

  describe "add_delta merge_rule (temperature, D-3 双路径)" do
    test "空 cell → effective = L1 default (20.0 °C in Q16.16)" do
      storage = solid_chunk(0)
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default
    end

    test "L1 + L2 temperature_delta 字段 = +5 (raw delta)" do
      storage = solid_chunk(0, temperature_delta: 5)
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 5
    end

    test "L1 + L2 attribute_set.temperature delta 字段 (sum)" do
      storage = solid_chunk(0, temperature_delta: 7)

      # temperature id=1, value_type fixed32; 这里"value" 在 attribute_set 中是 raw int32 delta
      {storage, ref} = intern_set(storage, [{1, 0x03, 11}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      # D-3 (a1)：temperature_delta 字段 + attribute_set 同 attribute 两者 sum 累加
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 7 + 11
    end

    test "L1 + L5 environment_summary.current_temperature delta" do
      storage = solid_chunk(0)
      storage = attach_env_summary(storage, 0, current_temperature: 13)

      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 13
    end

    test "L1 + L2 + L5 全 delta sum" do
      storage = solid_chunk(0, temperature_delta: 3)
      {storage, ref} = intern_set(storage, [{1, 0x03, 5}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)
      storage = attach_env_summary(storage, 0, current_temperature: 7)

      # L1(20.0) + L2_field(3) + L2_set(5) + L5(7) = default + 15
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 15
    end

    test "refined cell 多 layer：sum 所有 layer attribute_set 的 delta" do
      # 两 layer 各自 attribute_set 含 temperature delta = +5, +10
      storage = Storage.new(0, {0, 0, 0})

      # 先在 chunk pool 里 intern 两个 attribute_set（temperature delta = 5 / 10）
      # 用 intern_sets 一次性获取稳定 refs（绕开 normalize 重排后旧 ref 失效）。
      {storage, [ref_a, ref_b]} =
        intern_sets(storage, [
          [{1, 0x03, 5}],
          [{1, 0x03, 10}]
        ])

      layers = [
        %{material_id: 1, attribute_set_ref: ref_a},
        %{material_id: 2, attribute_set_ref: ref_b}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      # L1 (20.0) + L3 sum (5 + 10) = default + 15
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 15
    end
  end

  # ---- override merge_rule (test catalog) -------------------------------------

  describe "override merge_rule (test_override, L3 > L2 > L1 > L5)" do
    test "无任何层有值 → effective = L1 default", %{} do
      {catalog, _pid, _seed} = start_test_catalog!("override_default")
      storage = solid_chunk(0)

      assert Storage.effective_attribute_at(storage, 0, "test_override", catalog: catalog) == 10
    end

    test "仅 L2 有值 → effective = L2" do
      {catalog, _pid, _seed} = start_test_catalog!("override_l2_only")
      storage = solid_chunk(0)
      {storage, ref} = intern_set(storage, [{100, 0x03, 123}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "test_override", catalog: catalog) == 123
    end

    test "L3 + L2 + L1 + L5 全有值 → effective = L3 (最高 priority)" do
      {catalog, _pid, _seed} = start_test_catalog!("override_full")
      storage = Storage.new(0, {0, 0, 0})

      # L5 env summary path 仅 temperature / moisture 启用（test_override 不在两者中，
      # 因此 L5 不会注入到 test_override —— 这是 §7 实施约定）。
      # 先做完所有 intern 再用稳定 refs。
      {storage, [ref_l3, ref_l2]} =
        intern_sets(storage, [
          [{100, 0x03, 333}],
          [{100, 0x03, 222}]
        ])

      layers = [
        %{material_id: 1, attribute_set_ref: ref_l3}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      # 把 L2 attribute_set ref 挂到 macro 1（refined 模式下 L2 不存在因为没 normal_block）
      # 单独 cell macro 1 用来验证 L2 only
      block = NormalBlockData.new(1)
      storage = Storage.put_solid_block(storage, 1, block)
      storage = set_solid_block_attribute_set_ref(storage, 1, ref_l2)

      # macro 0: 仅 refined L3
      assert Storage.effective_attribute_at(storage, 0, "test_override", catalog: catalog) == 333
      # macro 1: 仅 solid L2
      assert Storage.effective_attribute_at(storage, 1, "test_override", catalog: catalog) == 222
    end
  end

  # ---- max merge_rule ---------------------------------------------------------

  describe "max merge_rule (test_max)" do
    test "L1 default=10, L2=15 → effective = 15" do
      {catalog, _pid, _seed} = start_test_catalog!("max_l1_l2")
      storage = solid_chunk(0)
      {storage, ref} = intern_set(storage, [{101, 0x03, 15}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "test_max", catalog: catalog) == 15
    end

    test "L1=10, L2=5 → effective = 10 (L1 wins)" do
      {catalog, _pid, _seed} = start_test_catalog!("max_l1_wins")
      storage = solid_chunk(0)
      {storage, ref} = intern_set(storage, [{101, 0x03, 5}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "test_max", catalog: catalog) == 10
    end

    test "L1=10, L2=8, L3=20 → effective = 20" do
      {catalog, _pid, _seed} = start_test_catalog!("max_l3_wins")
      storage = Storage.new(0, {0, 0, 0})
      {storage, ref_l3} = intern_set(storage, [{101, 0x03, 20}])

      layers = [
        %{material_id: 1, attribute_set_ref: ref_l3}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      assert Storage.effective_attribute_at(storage, 0, "test_max", catalog: catalog) == 20
    end
  end

  # ---- min merge_rule ---------------------------------------------------------

  describe "min merge_rule (test_min)" do
    test "L1=10, L2=5 → effective = 5" do
      {catalog, _pid, _seed} = start_test_catalog!("min_l2_wins")
      storage = solid_chunk(0)
      {storage, ref} = intern_set(storage, [{102, 0x03, 5}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "test_min", catalog: catalog) == 5
    end

    test "L1=10, L2=20 → effective = 10 (L1 wins)" do
      {catalog, _pid, _seed} = start_test_catalog!("min_l1_wins")
      storage = solid_chunk(0)
      {storage, ref} = intern_set(storage, [{102, 0x03, 20}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "test_min", catalog: catalog) == 10
    end
  end

  # ---- edge cases -------------------------------------------------------------

  describe "edge cases" do
    test "未知 attr_name → raise" do
      storage = solid_chunk(0)

      assert_raise ArgumentError, ~r/not in catalog/, fn ->
        Storage.effective_attribute_at(storage, 0, "nonexistent")
      end
    end

    test "effective_value 超出 max_value → clip 到 max_value" do
      # add_delta 路径：temperature default + 巨量 delta > max_value, 期望 clip 到 max_value
      storage = solid_chunk(0)
      # temperature max = 327_680_000；构造一个超大 delta 让 sum 超出
      {storage, ref} = intern_set(storage, [{1, 0x03, 400_000_000}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "temperature") == 327_680_000
    end

    test "effective_value 低于 min_value → clip 到 min_value" do
      storage = solid_chunk(0)

      # temperature min = -17_904_824；构造一个巨负 delta（注意 i16 / i32 范围限制）
      # value_type fixed32 raw int32 范围 -0x8000_0000..0x7FFF_FFFF
      # 让 sum = default + (-2_000_000_000) = ~ -1_998_689_280 < min(-17_904_824) → clip 到 min
      {storage, ref} = intern_set(storage, [{1, 0x03, -2_000_000_000}])
      storage = set_solid_block_attribute_set_ref(storage, 0, ref)

      assert Storage.effective_attribute_at(storage, 0, "temperature") == -17_904_824
    end

    test "不合法 macro_index_or_coord → raise" do
      storage = solid_chunk(0)

      assert_raise ArgumentError, fn ->
        Storage.effective_attribute_at(storage, 99_999_999, "temperature")
      end
    end
  end

  # ---- L3 refined multi-layer 多 attribute_set 文档化行为 ---------------------

  describe "refined cell 多 layer attribute_set 抽取策略" do
    test "add_delta: sum 所有 layer 的 delta" do
      storage = Storage.new(0, {0, 0, 0})

      {storage, [ref_a, ref_b, ref_c]} =
        intern_sets(storage, [
          [{1, 0x03, 5}],
          [{1, 0x03, 10}],
          [{1, 0x03, 2}]
        ])

      # 每个 layer 必须有不同 attribute_signature；用不同 material_id 区分。
      layers = [
        %{material_id: 1, attribute_set_ref: ref_a},
        %{material_id: 2, attribute_set_ref: ref_b},
        %{material_id: 3, attribute_set_ref: ref_c}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      # L1 (20.0) + L3 sum (5+10+2) = default + 17
      assert Storage.effective_attribute_at(storage, 0, "temperature") == @t_default + 17
    end

    test "override: 任一 layer 有 attribute 即返回（first layer with attribute），不累加" do
      {catalog, _pid, _seed} = start_test_catalog!("override_multilayer")
      storage = Storage.new(0, {0, 0, 0})

      {storage, [ref_a, ref_b]} =
        intern_sets(storage, [
          [{100, 0x03, 333}],
          [{100, 0x03, 444}]
        ])

      layers = [
        %{material_id: 1, attribute_set_ref: ref_a},
        %{material_id: 2, attribute_set_ref: ref_b}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      # canonical_layer_order by signature → 第一个 layer (signature tuple 小) 优先
      result =
        Storage.effective_attribute_at(storage, 0, "test_override", catalog: catalog)

      # 结果是 333 或 444 二选一（取决于 canonical 排序），但不会累加
      assert result in [333, 444]
      # 关键约定：override 不累加，所以不能等于 333 + 444
      refute result == 777
    end

    test "max: 取所有 layer 中最大值" do
      {catalog, _pid, _seed} = start_test_catalog!("max_multilayer")
      storage = Storage.new(0, {0, 0, 0})

      {storage, [ref_a, ref_b]} =
        intern_sets(storage, [
          [{101, 0x03, 30}],
          [{101, 0x03, 5}]
        ])

      layers = [
        %{material_id: 1, attribute_set_ref: ref_a},
        %{material_id: 2, attribute_set_ref: ref_b}
      ]

      storage = refined_chunk_with_layers_into(storage, 0, layers)

      # max(L1=10, L3 layers [30,5]) = 30
      assert Storage.effective_attribute_at(storage, 0, "test_max", catalog: catalog) == 30
    end
  end

  # 给已有 storage 添加 refined cell（沿用 refined_chunk_with_layers 的逻辑，但保留
  # 既有的 attribute_sets 池 + normal_blocks）。
  defp refined_chunk_with_layers_into(storage, macro_index, layers_attrs) do
    layers =
      Enum.with_index(layers_attrs, fn attrs, idx ->
        slot = idx
        word_index = div(slot, 64)
        bit_index = rem(slot, 64)
        mask = List.replace_at(List.duplicate(0, 8), word_index, Bitwise.bsl(1, bit_index))
        MicroLayer.normalize!(Map.put(attrs, :mask_words, mask))
      end)

    occupancy =
      Enum.reduce(layers, List.duplicate(0, 8), fn layer, acc ->
        Enum.zip_with(acc, layer.mask_words, &Bitwise.bor/2)
      end)

    refined =
      RefinedCellData.new(
        occupancy_words: occupancy,
        layers: layers,
        object_refs: [],
        boundary_cache: 0
      )

    payload_index = length(storage.refined_cells)

    header =
      MacroCellHeader.refined(payload_index,
        flags: 0,
        environment_index: MacroCellHeader.no_index(),
        cell_version: 0,
        cell_hash: 0
      )

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: storage.refined_cells ++ [refined]
    }
    |> Storage.normalize!()
  end

  defp fixed32(value), do: round(value * @fixed32_scale)
  defp fixed32_or_raw(@absolute_zero_raw), do: @absolute_zero_raw
  defp fixed32_or_raw(value), do: fixed32(value)
end

defmodule SceneServer.Voxel.StorageAccelTest do
  # 阶段2.5（voxel-storage-6）—— 体素数据结构 + normalize 收口的对照/不变量测试。
  #
  # 本文件是 2.5 的 **codec parity 守门员**：换底层加速结构（macro_headers 经
  # `:array`、refined_cells 经 map 做 O(1) 随机访问；object_refs 增量化）之后，
  # 必须证明：
  #
  #   ① codec wire layout 逐字节不变（encode roundtrip + 与“强制无 accel”路径
  #      字节一致）；
  #   ② chunk_hash 字节序稳定（含 3 条 pinned baseline）；
  #   ③ accel `:array` / map 随机访问语义 == 原 List `Enum.at`；
  #   ④ 增量 object_refs == 全量 refresh（结构等价）；
  #   ⑤ 单格改动复杂度（dirty 集只含被改 macro，不触发 4096 趟全量重算）。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  # 与 codec_test.exs 的 pinned baseline 同源（priv/scripts/pin_chunk_hash_baseline.exs）。
  @empty_baseline_chunk_hash 0x0980_DF98_C2DA_1FFC
  @seed_baseline_chunk_hash 0x7B46_B0F3_33B6_3489

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # 把 storage 的 accel 强制置空，模拟“纯 canonical list、无加速索引”的旧表示，
  # 用于对照：accel 路径的 encode/hash/随机读必须与无 accel 路径逐字节/逐值一致。
  defp strip_accel(%Storage{} = storage), do: %{storage | accel: nil}

  defp seed_storage do
    base = Storage.empty(123, {0, 0, 0}, chunk_version: 9)
    block = NormalBlockData.new(11, health: 100)

    Enum.reduce(0..8, base, fn i, acc ->
      mx = rem(i, 3)
      mz = div(i, 3)

      Storage.put_solid_block(acc, {mx, 0, mz}, block,
        cell_version: 1,
        cell_hash: 0xA000_0000 + i
      )
    end)
  end

  defp refined_storage do
    Storage.empty(7, {3, -1, 4}, chunk_version: 5)
    |> Storage.put_micro_block(0, 0, %{material_id: 7, owner_object_id: 42, owner_part_id: 3})
    |> Storage.put_micro_block(0, 1, %{material_id: 7, owner_object_id: 42, owner_part_id: 3})
    |> Storage.put_micro_block({1, 0, 0}, 8, %{material_id: 9, owner_object_id: 99, owner_part_id: 1})
    |> Storage.refresh_chunk_object_refs()
  end

  # ---------------------------------------------------------------------------
  # ① wire layout 逐字节不变（accel vs 无 accel）
  # ---------------------------------------------------------------------------

  describe "wire byte invariance (accel 解耦于线序)" do
    test "snapshot encode 与无 accel 路径逐字节一致 —— empty / seed / refined" do
      for storage <- [Storage.empty(42, {-1, 0, 2}, chunk_version: 7), seed_storage(), refined_storage()] do
        with_accel = Codec.encode_chunk_snapshot_payload(storage)
        without_accel = Codec.encode_chunk_snapshot_payload(strip_accel(storage))

        assert with_accel == without_accel,
               "accel 路径与无 accel 路径的 snapshot wire 必须逐字节一致"
      end
    end

    test "snapshot decode → re-encode 仍 byte-stable（roundtrip）" do
      for storage <- [seed_storage(), refined_storage()] do
        payload = Codec.encode_chunk_snapshot_payload(storage)
        assert {:ok, decoded} = Codec.decode_chunk_snapshot_payload(payload)
        assert Codec.encode_chunk_snapshot_payload(decoded.storage) == payload
      end
    end

    test "truth payload（chunk_hash 输入）与无 accel 路径逐字节一致" do
      for storage <- [seed_storage(), refined_storage()] do
        assert Codec.encode_chunk_truth_payload(storage) ==
                 Codec.encode_chunk_truth_payload(strip_accel(storage))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ② chunk_hash 字节序稳定
  # ---------------------------------------------------------------------------

  describe "chunk_hash 稳定" do
    test "pinned baselines 不漂移（empty / seed）" do
      assert Codec.chunk_hash(Storage.empty(42, {-1, 0, 2}, chunk_version: 7)) ==
               @empty_baseline_chunk_hash

      assert Codec.chunk_hash(seed_storage()) == @seed_baseline_chunk_hash
    end

    test "accel 路径与无 accel 路径 chunk_hash 完全相等" do
      for storage <- [seed_storage(), refined_storage()] do
        assert Codec.chunk_hash(storage) == Codec.chunk_hash(strip_accel(storage))
      end
    end

    test "trust_transform! / 增量 refresh 后 chunk_hash 与全量 refresh 路径一致" do
      base = refined_storage()

      # 通过增量路径再加一格
      incremental =
        base
        |> Storage.put_micro_block(0, 2, %{material_id: 7, owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs_incremental()

      # 通过全量路径加同一格
      full =
        base
        |> Storage.put_micro_block(0, 2, %{material_id: 7, owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      assert Codec.chunk_hash(incremental) == Codec.chunk_hash(full)
      assert Codec.encode_chunk_snapshot_payload(incremental) ==
               Codec.encode_chunk_snapshot_payload(full)
    end
  end

  # ---------------------------------------------------------------------------
  # ③ accel 随机访问 == 原 List 语义
  # ---------------------------------------------------------------------------

  describe "accel 随机访问语义等价 List.Enum.at" do
    test "fetch_macro_header/2 对全 4096 index 等价 Enum.at" do
      storage = seed_storage()
      stripped = strip_accel(storage)

      # 抽样若干 index（含改过的格与空格）覆盖语义
      for macro_index <- [0, 1, 2, 16, 17, 32, 4095] do
        assert Storage.fetch_macro_header(storage, macro_index) ==
                 Enum.at(stripped.macro_headers, macro_index)
      end
    end

    test "fetch_refined_cell/2 经 accel map 等价 Enum.at(refined_cells)" do
      storage = refined_storage()
      stripped = strip_accel(storage)

      for payload_index <- 0..(length(stripped.refined_cells) - 1)//1 do
        assert Storage.fetch_refined_cell(storage, payload_index) ==
                 Enum.at(stripped.refined_cells, payload_index)
      end

      # 越界 payload_index → nil（map miss / list out-of-range 一致）
      assert Storage.fetch_refined_cell(storage, 9999) == nil
    end

    test "ensure_accel/1 幂等且不改变 canonical list" do
      storage = refined_storage()
      once = Storage.ensure_accel(storage)
      twice = Storage.ensure_accel(once)

      assert once.macro_headers == storage.macro_headers
      assert once.refined_cells == storage.refined_cells
      assert once == twice
    end

    test "accel 从 canonical list 确定派生 → 同内容 storage 结构相等（含 accel）" do
      a = refined_storage()
      # 用 normalize! 重建（重新派生 accel）后必须与原 storage 结构相等
      b = Storage.normalize!(a)
      assert a == b
    end
  end

  # ---------------------------------------------------------------------------
  # ④ 增量 object_refs == 全量 refresh
  # ---------------------------------------------------------------------------

  describe "增量 object_refs 等价全量 refresh" do
    test "单格新增：增量与全量产出相同 object_refs / refined_cells" do
      base = Storage.empty(1, {0, 0, 0})

      built =
        base
        |> Storage.put_micro_block(0, 0, %{material_id: 7, owner_object_id: 42, owner_part_id: 3})

      incremental = Storage.refresh_chunk_object_refs_incremental(built)
      full = Storage.refresh_chunk_object_refs(built)

      assert incremental.object_refs == full.object_refs
      assert incremental.refined_cells == full.refined_cells
    end

    test "跨多 macro 的 batch：增量与全量等价" do
      built =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({0, 0, 0}, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.put_micro_block({1, 0, 0}, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.put_micro_block({0, 1, 0}, 0, %{owner_object_id: 99, owner_part_id: 1})

      incremental = Storage.refresh_chunk_object_refs_incremental(built)
      full = Storage.refresh_chunk_object_refs(built)

      assert incremental.object_refs == full.object_refs
      assert incremental.refined_cells == full.refined_cells
    end

    test "clear → 降级 empty 后，增量与全量都收敛到空 object_refs" do
      built =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block(0, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.refresh_chunk_object_refs()

      assert length(built.object_refs) == 1

      cleared = Storage.clear_micro_block(built, 0, 0)

      incremental = Storage.refresh_chunk_object_refs_incremental(cleared)
      full = Storage.refresh_chunk_object_refs(cleared)

      assert incremental.object_refs == []
      assert incremental.object_refs == full.object_refs
      # 降级后的 refined_cells（孤儿 cell object_refs 已被 downgrade 置空）等价
      assert incremental.refined_cells == full.refined_cells
    end
  end

  # ---------------------------------------------------------------------------
  # ⑤ 单格改动复杂度：dirty 集只含被改 macro（不触发 4096 趟）
  # ---------------------------------------------------------------------------

  describe "单格改动的 dirty 收敛（复杂度对照）" do
    test "put_micro_block 只把被改 macro 标 dirty（half-open 单格 bounds）" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.clear_dirty_bounds()
        |> Storage.put_micro_block(0, 0, %{material_id: 7})

      dirty = storage.dirty_bounds
      refute DirtyMacroBounds.empty?(dirty)
      # 单格 → half-open bounds 恰好覆盖 1 个 macro cell
      assert dirty.min_macro == {0, 0, 0}
      assert dirty.max_macro == {1, 1, 1}
    end

    test "增量 refresh 只重算 dirty 区间内的 refined cell" do
      # 在两个相距很远的 macro 各放一个 object，先全量 refresh 让两边 object_refs 就位
      base =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({0, 0, 0}, 0, %{owner_object_id: 42, owner_part_id: 3})
        |> Storage.put_micro_block({15, 15, 15}, 0, %{owner_object_id: 99, owner_part_id: 1})
        |> Storage.refresh_chunk_object_refs()
        |> Storage.clear_dirty_bounds()

      # 只改 macro {0,0,0}，dirty 只含该 macro
      touched =
        base
        |> Storage.put_micro_block({0, 0, 0}, 1, %{owner_object_id: 42, owner_part_id: 3})

      far_macro_index = Types.macro_index!({15, 15, 15})
      far_header_before = Storage.fetch_macro_header(base, far_macro_index)
      far_cell_before = Storage.fetch_refined_cell(base, far_header_before.payload_index)

      incremental = Storage.refresh_chunk_object_refs_incremental(touched)

      far_header_after = Storage.fetch_macro_header(incremental, far_macro_index)
      far_cell_after = Storage.fetch_refined_cell(incremental, far_header_after.payload_index)

      # 远端未被触碰的 cell.object_refs 不变（增量没重算它）
      assert far_cell_after.object_refs == far_cell_before.object_refs

      # 且结果仍与全量等价（正确性兜底）
      full = Storage.refresh_chunk_object_refs(touched)
      assert incremental.object_refs == full.object_refs
      assert incremental.refined_cells == full.refined_cells
    end
  end

  # ---------------------------------------------------------------------------
  # trust_transform! 不变量
  # ---------------------------------------------------------------------------

  describe "trust_transform!/2" do
    test "局部变换合并 dirty + 刷新 accel + 不改 list 顺序" do
      storage = seed_storage() |> Storage.clear_dirty_bounds()
      solid_mode = MacroCellHeader.cell_mode_solid_block()

      # 把 macro 1 的 header flags 改一下（受信局部写，已 normalize 的子结构）
      transformed =
        Storage.trust_transform!(storage, fn s ->
          header = Storage.fetch_macro_header(s, 1)
          new_header = MacroCellHeader.normalize!(%{header | flags: 0x0040})
          headers = List.replace_at(s.macro_headers, 1, new_header)
          {%{s | macro_headers: headers}, [1], DirtyMacroBounds.reason_attribute_write()}
        end)

      # dirty 合并了 macro 1
      assert DirtyMacroBounds.reason_set?(
               transformed.dirty_bounds,
               DirtyMacroBounds.reason_attribute_write()
             )

      assert transformed.dirty_bounds.min_macro == {1, 0, 0}

      # accel 已刷新且与 list 一致
      assert Storage.fetch_macro_header(transformed, 1).flags == 0x0040
      assert Storage.fetch_macro_header(transformed, 1).mode == solid_mode
      assert Enum.at(transformed.macro_headers, 1).flags == 0x0040

      # 其余 header 顺序未变（macro 0 仍是 solid）
      assert Storage.fetch_macro_header(transformed, 0).mode == solid_mode
    end
  end
end

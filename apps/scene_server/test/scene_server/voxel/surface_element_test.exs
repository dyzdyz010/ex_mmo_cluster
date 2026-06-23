defmodule SceneServer.Voxel.SurfaceElementTest do
  # 形态轨 · 表面元件层 M2:SurfaceElement struct 校验 + Storage 面槽旁路(零 occupancy)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceCatalog
  alias SceneServer.Voxel.SurfaceElement
  alias SceneServer.Voxel.Types

  defp rust_decal_id, do: SurfaceCatalog.surface_type_id(:rust_decal)

  describe "SurfaceElement 校验" do
    test "合法记录构造成功" do
      el =
        SurfaceElement.new(%{macro_index: 5, face: :x_pos, surface_type_id: rust_decal_id()})

      assert el.macro_index == 5
      assert el.face == :x_pos
      assert el.surface_type_id == rust_decal_id()
      assert el.attribute_set_ref == 0
      assert el.owner_actor_id == 0
    end

    test "sort_key = {macro_index, face_ordinal}" do
      el = SurfaceElement.new(%{macro_index: 7, face: :y_neg, surface_type_id: rust_decal_id()})
      assert SurfaceElement.sort_key(el) == {7, SurfaceCatalog.face_ordinal(:y_neg)}
    end

    test "拒绝越界 macro_index / 非法 face / 未知类型" do
      assert_raise ArgumentError, ~r/macro_index/, fn ->
        SurfaceElement.new(%{macro_index: 4096, face: :x_neg, surface_type_id: rust_decal_id()})
      end

      assert_raise ArgumentError, ~r/face/, fn ->
        SurfaceElement.new(%{macro_index: 0, face: :nope, surface_type_id: rust_decal_id()})
      end

      assert_raise ArgumentError, ~r/surface_type_id/, fn ->
        SurfaceElement.new(%{macro_index: 0, face: :x_neg, surface_type_id: 999})
      end
    end
  end

  describe "Storage 面槽旁路:put / get / clear" do
    test "put + surface_element_at 取回" do
      macro = Types.macro_index!({1, 0, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })

      el = Storage.surface_element_at(storage, macro, :x_pos)
      assert el.surface_type_id == rust_decal_id()
      assert Storage.surface_element_at(storage, macro, :x_neg) == nil
    end

    test "同 {macro,face} 覆盖(后写赢);不同面/格共存且 canonical 排序" do
      macro = Types.macro_index!({2, 0, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: SurfaceCatalog.surface_type_id(:frost)
        })
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :y_neg,
          surface_type_id: rust_decal_id()
        })
        |> Storage.put_surface_element(%{
          macro_index: 0,
          face: :z_pos,
          surface_type_id: rust_decal_id()
        })

      # 同面覆盖:x_pos 现为 frost。
      assert Storage.surface_element_at(storage, macro, :x_pos).surface_type_id ==
               SurfaceCatalog.surface_type_id(:frost)

      # 三个不同键共存。
      assert length(Storage.list_surface_elements(storage)) == 3

      # canonical 排序:按 {macro_index, face_ordinal}。
      keys = Enum.map(Storage.list_surface_elements(storage), &SurfaceElement.sort_key/1)
      assert keys == Enum.sort(keys)
    end

    test "clear 移除(清氧化/刮除路径)" do
      macro = Types.macro_index!({3, 0, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })

      assert Storage.surface_element_at(storage, macro, :x_pos) != nil

      cleared = Storage.clear_surface_element(storage, macro, :x_pos)
      assert Storage.surface_element_at(cleared, macro, :x_pos) == nil
      assert Storage.list_surface_elements(cleared) == []
    end

    test "surface_elements_at_macro 列某格全部面" do
      macro = Types.macro_index!({4, 0, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :y_pos,
          surface_type_id: rust_decal_id()
        })
        |> Storage.put_surface_element(%{
          macro_index: 0,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })

      assert length(Storage.surface_elements_at_macro(storage, macro)) == 2
    end
  end

  describe "零 occupancy 不变量(决策稿 D-2):表面元件不改宿主几何/邻接" do
    test "在空宏格放表面元件 → 宏格仍为 empty(不变实/不占体积)" do
      macro = Types.macro_index!({5, 0, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })

      header = Storage.macro_header_at(storage, macro)
      assert header.mode == MacroCellHeader.cell_mode_empty()
      assert storage.normal_blocks == []
      assert storage.refined_cells == []
    end

    test "在实心宏格放/清表面元件 → 宿主块与 mode 不变(贴面与本体正交)" do
      macro = Types.macro_index!({6, 0, 0})
      iron = SceneServer.Voxel.MaterialCatalog.material_id(:iron)

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_solid_block(macro, NormalBlockData.new(iron))

      before_header = Storage.macro_header_at(storage, macro)

      with_decal =
        Storage.put_surface_element(storage, %{
          macro_index: macro,
          face: :x_pos,
          surface_type_id: rust_decal_id()
        })

      after_header = Storage.macro_header_at(with_decal, macro)
      assert after_header.mode == before_header.mode
      assert after_header.mode == MacroCellHeader.cell_mode_solid_block()
      assert Storage.normal_block_at(with_decal, macro).material_id == iron

      # 清除贴面后本体依旧。
      cleared = Storage.clear_surface_element(with_decal, macro, :x_pos)
      assert Storage.normal_block_at(cleared, macro).material_id == iron

      assert Storage.macro_header_at(cleared, macro).mode ==
               MacroCellHeader.cell_mode_solid_block()
    end
  end

  describe "normalize! 幂等 + canonical" do
    test "重复 normalize 稳定" do
      macro = Types.macro_index!({1, 1, 0})

      storage =
        Storage.new(7, {0, 0, 0})
        |> Storage.put_surface_element(%{
          macro_index: macro,
          face: :z_neg,
          surface_type_id: rust_decal_id()
        })

      assert Storage.normalize!(storage) == storage
    end
  end
end

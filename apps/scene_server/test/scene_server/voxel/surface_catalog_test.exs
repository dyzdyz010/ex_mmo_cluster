defmodule SceneServer.Voxel.SurfaceCatalogTest do
  # 形态轨 · 表面元件层 M1:类型表(append-only)+ 面 ordinal 助手。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.SurfaceCatalog

  describe "面(face)ordinal(wire 稳定,与 ParticipantProjection face_rank 一致)" do
    test "6 个面,ordinal 0..5 双向一致" do
      assert SurfaceCatalog.faces() == [:x_neg, :x_pos, :y_neg, :y_pos, :z_neg, :z_pos]

      for face <- SurfaceCatalog.faces() do
        ordinal = SurfaceCatalog.face_ordinal(face)
        assert ordinal in 0..5
        assert SurfaceCatalog.face_from_ordinal(ordinal) == face
      end

      assert Enum.map(SurfaceCatalog.faces(), &SurfaceCatalog.face_ordinal/1) == [
               0,
               1,
               2,
               3,
               4,
               5
             ]
    end

    test "未知面 / 越界 ordinal 返回 nil;valid_face?" do
      assert SurfaceCatalog.face_ordinal(:nope) == nil
      assert SurfaceCatalog.face_from_ordinal(6) == nil
      assert SurfaceCatalog.valid_face?(:x_neg)
      refute SurfaceCatalog.valid_face?(:nope)
      refute SurfaceCatalog.valid_face?("x_neg")
    end
  end

  describe "表面类型表(append-only)" do
    test "名 ↔ id 双向一致" do
      for {name, id} <- SurfaceCatalog.surface_type_ids() do
        assert SurfaceCatalog.surface_type_id(name) == id
        assert SurfaceCatalog.surface_type_name(id) == name
        assert SurfaceCatalog.known_surface_type?(id)
      end
    end

    test "rust_decal:被动条件,被覆盖即隐,借 rust 属性参与物理(接 S4 皮相化)" do
      id = SurfaceCatalog.surface_type_id(:rust_decal)
      assert id == 1
      assert SurfaceCatalog.kind(id) == :condition
      assert SurfaceCatalog.visibility(id) == :hide_when_neighbor_occupied
      assert SurfaceCatalog.material(id) == :rust
    end

    test "torch:单面装置,始终可见,借 ember 材料参与热系统(heat_output)" do
      id = SurfaceCatalog.surface_type_id(:torch)
      assert SurfaceCatalog.kind(id) == :fixture
      assert SurfaceCatalog.visibility(id) == :always_visible
      assert SurfaceCatalog.material(id) == :ember
    end

    test "未知名 / 未知 id 返回 nil" do
      assert SurfaceCatalog.surface_type_id(:unobtanium) == nil
      assert SurfaceCatalog.surface_type_name(999) == nil
      refute SurfaceCatalog.known_surface_type?(999)
      assert SurfaceCatalog.definition(999) == nil
      assert SurfaceCatalog.kind(999) == nil
    end

    test "definition 返回完整字段" do
      defn = SurfaceCatalog.definition(SurfaceCatalog.surface_type_id(:frost))
      assert defn.name == :frost
      assert defn.kind == :condition
      assert defn.visibility == :hide_when_neighbor_occupied
      assert defn.material == :ice
    end
  end
end

defmodule SceneServer.Voxel.TagPhysicsTest do
  # 功能完善 · 正交架构 S3 Part A:声明式 tag → 物理属性(passability)绑定。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.TagPhysics

  setup do
    case start_supervised({TagCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "passable_tag_names 含 open(append-only 数据表)" do
    assert "open" in TagPhysics.passable_tag_names()
  end

  test "passable_tag_ids 解析 :open 名为运行时 id" do
    {:ok, open_id, _defn} = TagCatalog.lookup_by_name("open")
    assert MapSet.member?(TagPhysics.passable_tag_ids(), open_id)
  end

  test "带 :open tag 的格判定可通行" do
    {:ok, open_id, _defn} = TagCatalog.lookup_by_name("open")
    assert TagPhysics.passable?([open_id])
  end

  test "无 tag(空)= 不可通行(快路径)" do
    refute TagPhysics.passable?([])
  end

  test "只带非可通行 tag(如 :powered/:burning)不判定可通行" do
    {:ok, powered_id, _defn} = TagCatalog.lookup_by_name("powered")
    {:ok, burning_id, _defn} = TagCatalog.lookup_by_name("burning")
    refute TagPhysics.passable?([powered_id, burning_id])
  end

  test "混合 tag 中含 :open 即可通行" do
    {:ok, open_id, _defn} = TagCatalog.lookup_by_name("open")
    {:ok, powered_id, _defn} = TagCatalog.lookup_by_name("powered")
    assert TagPhysics.passable?([powered_id, open_id])
  end
end

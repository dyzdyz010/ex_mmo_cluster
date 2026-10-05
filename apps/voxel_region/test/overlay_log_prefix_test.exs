defmodule VoxelRegion.OverlayLogPrefixTest do
  @moduledoc "只测试：真实Db/File检查点替换前缀，保留计算期间已追加的完整事务后缀。"
  use ExUnit.Case, async: false
  alias VoxelRegion.OverlayLog

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "overlay-prefix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, cv: System.unique_integer([:positive])}
  end

  for backend <- [OverlayLog.Db, OverlayLog.File] do
    @backend backend
    test "#{inspect(backend)} replaces through P and reopens checkpoint plus exact tail", %{
      root: root,
      cv: cv
    } do
      backend = @backend
      handle = backend.open(root, cv)
      first = txn(1, 11)
      at_cut = txn(4, 19)
      tail = txn(5, 7)
      later = txn(6, 8)

      checkpoint = %{
        at_cut
        | material_balances: %{{7, 19} => 15},
          food_receipts: %{7 => %{4 => %{energy_j: 120.0}}}
      }

      for value <- [first, at_cut, tail, later], do: assert(:ok == backend.append(handle, value))

      assert :ok = backend.checkpoint(handle, checkpoint)
      assert backend.replay(backend.open(root, cv)) == [checkpoint, tail, later]

      # 再次压实同一P不重复保留旧checkpoint，之后追加仍按序重放。
      assert :ok = backend.checkpoint(handle, checkpoint)
      newest = txn(7, 9)
      assert :ok = backend.append(handle, newest)
      assert backend.replay(backend.open(root, cv)) == [checkpoint, tail, later, newest]
    end
  end

  test "File failed temporary write leaves the previous prefix and tail readable", %{
    root: root,
    cv: cv
  } do
    handle = OverlayLog.File.open(root, cv)
    before = [txn(1, 11), txn(4, 19), txn(5, 7)]
    for value <- before, do: OverlayLog.File.append(handle, value)

    # 只测试：用目录占住临时文件名，真实文件写入报错，不能先破坏旧日志。
    File.mkdir!(handle <> ".tmp")
    assert_raise File.Error, fn -> OverlayLog.File.checkpoint(handle, txn(4, 20)) end
    assert OverlayLog.File.replay(handle) == before
  end

  defp txn(seq, material) do
    %{
      seq: seq,
      entries: [%{seq: seq, coord: {-1, 2, 3}, material: material, coarse: []}],
      coarse: [],
      material_balances: %{{7, material} => seq},
      food_receipts: %{}
    }
  end
end

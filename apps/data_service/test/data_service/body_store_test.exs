defmodule DataService.BodyStoreTest do
  @moduledoc "只测试：真实 PostgreSQL 的身体快照、会话写入隔离与 Repo 重启恢复。"
  use ExUnit.Case, async: false

  alias DataService.{BodyStore, Repo}

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    # 每例独占角色，不清空其它测试或其它角色的存档。
    %{cid: System.unique_integer([:positive, :monotonic])}
  end

  test "首次取得写入权没有快照，同一会话再次取得时保留完整字节", %{cid: cid} do
    assert {:ok, nil} = BodyStore.claim(cid, 101)
    assert :ok = BodyStore.save(cid, 101, <<0, 255, 1, 0, 128>>)
    assert {:ok, <<0, 255, 1, 0, 128>>} = BodyStore.claim(cid, 101)
  end

  test "新会话取得旧快照后，旧会话不能重新取得或覆盖新快照", %{cid: cid} do
    assert {:ok, nil} = BodyStore.claim(cid, 100)
    assert :ok = BodyStore.save(cid, 100, "before-transfer")
    assert {:ok, "before-transfer"} = BodyStore.claim(cid, 200)
    assert :ok = BodyStore.save(cid, 200, "after-transfer")

    assert {:error, :stale_owner} = BodyStore.save(cid, 100, "late-old-owner")
    assert {:error, :stale_owner} = BodyStore.claim(cid, 100)
    assert {:ok, "after-transfer"} = BodyStore.claim(cid, 200)
  end

  test "未取得写入权的角色不能直接创建快照", %{cid: cid} do
    assert {:error, :stale_owner} = BodyStore.save(cid, 100, "unclaimed")
    assert {:ok, nil} = BodyStore.claim(cid, 100)
  end

  test "一个角色的接管与写入不改变另一个角色", %{cid: cid} do
    other = System.unique_integer([:positive, :monotonic])
    assert {:ok, nil} = BodyStore.claim(cid, 100)
    assert {:ok, nil} = BodyStore.claim(other, 100)
    assert :ok = BodyStore.save(cid, 100, "first-body")
    assert :ok = BodyStore.save(other, 100, "second-body")
    assert {:ok, "first-body"} = BodyStore.claim(cid, 200)
    assert :ok = BodyStore.save(cid, 200, "changed-first-body")
    assert {:ok, "second-body"} = BodyStore.claim(other, 100)
  end

  test "已提交的快照和写入代际在真实 Repo 重启后保留", %{cid: cid} do
    assert {:ok, nil} = BodyStore.claim(cid, 100, repo: Repo)
    assert :ok = BodyStore.save(cid, 100, <<255, 0, 17, 42>>, repo: Repo)
    previous = Process.whereis(Repo)

    assert :ok = Supervisor.terminate_child(DataService.Supervisor, Repo)
    assert {:ok, current} = Supervisor.restart_child(DataService.Supervisor, Repo)
    refute current == previous

    assert {:ok, <<255, 0, 17, 42>>} = BodyStore.claim(cid, 200, repo: Repo)
    assert {:error, :stale_owner} = BodyStore.save(cid, 100, "late-after-restart", repo: Repo)
    assert {:ok, <<255, 0, 17, 42>>} = BodyStore.claim(cid, 200, repo: Repo)
  end
end

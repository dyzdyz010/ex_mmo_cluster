defmodule SceneServer.Movement.PlayerRunningTest do
  @moduledoc """
  只测试：`Player.running?/1` 对本地与远端 pid 都给出判定，不抛异常。远端样本是按 Erlang 外部项格式
  （NEW_PID_EXT，tag 88，节点名为 SMALL_ATOM_UTF8_EXT）手写的一个不可达节点上的 pid：Scene 跑在 peer 节点、
  该节点已断开时 NPC Body 拿到的就是这种 pid。范围：不起真实 peer 节点，远端存活分支（`:erpc` 返回 true）不在此覆盖。
  """
  use ExUnit.Case, async: true
  alias SceneServer.Movement.Player

  # 不可达节点上的 pid：<<131, 88, 119, 名长, 名, id::32, serial::32, creation::32>>。
  defp unreachable_pid do
    name = "ghost@nohost"

    pid =
      :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, 1::32, 0::32, 0::32>>)

    assert node(pid) == :ghost@nohost
    pid
  end

  test "本地 pid 按存活判定；已断开节点上的 pid 视为已退出而不是抛 ArgumentError" do
    assert Player.running?(self())

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    refute Player.running?(dead)

    refute Player.running?(unreachable_pid())
  end
end

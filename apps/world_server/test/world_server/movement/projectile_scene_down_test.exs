defmodule WorldServer.Movement.ProjectileSceneDownTest do
  @moduledoc """
  只测试：World 恢复先于 Scene 启动时，重投已冻结的命中交付（真实后端 `WorldServer.Movement.Projectile`）。
  回归 2026-11-20：路由已部署但 Scene 进程未注册，`deliver/1` 调 Scene 以 noproc 退出，World 的异步采样随之崩溃。
  契约：Scene 未起 = 目标暂不可用，返回 `{:retry, :target_unavailable}`；World 保留冻结交付，下一节拍重投（不丢、不双投）。
  """
  use ExUnit.Case, async: false
  @moduletag :t0

  setup do
    previous = Application.get_env(:world_server, :movement_routes)

    Application.put_env(:world_server, :movement_routes, %{
      1 => %{scene_ref: {:voxim_scene_not_started, node()}, world_ref: self(), scene_epoch: 1}
    })

    on_exit(fn -> Application.put_env(:world_server, :movement_routes, previous) end)
  end

  test "Scene 未启动时重投冻结命中：返回 retry，不以 noproc 退出" do
    hit = %{
      key: {7, 3, 0},
      target: %{id: 2002, identity: :target, life_generation: 88},
      q_j: 100.0
    }

    assert [{{3, 0}, 0.25, {:delivered, {:retry, :target_unavailable}}}] =
             WorldServer.Movement.Projectile.poll(
               [{{3, 0}, %{age_s: 0.25, impact_delivery: hit}}],
               7
             )
  end
end

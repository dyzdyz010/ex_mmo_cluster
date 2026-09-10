defmodule SceneServer.Movement.RuntimeObservation do
  @moduledoc false
  alias SceneServer.Movement.{Scene, Player, Replication}
  # 测试在明确观察点等待真实 owner；生产 observe 不做同步等待。
  def observe(scene) do
    info = Scene.observe(scene)
    Enum.reduce(info.characters, %{info | characters: []}, fn cached, acc ->
      current = try do
        Player.observe(cached.player_pid)
      catch
        :exit, _ -> cached
      end
      acc = Enum.reduce([:physics_steps, :step_us, :old_identity, :rejected_inputs, :substitutions], acc, fn key, a ->
        Map.update!(a, key, &(&1 + Map.get(current, key, 0) - Map.get(cached, key, 0))) end)
      %{acc | characters: acc.characters ++ [current]}
    end)
    |> Map.put(:aoi, Replication.observe(info.replication_pid))
  end
  def player(scene, identity) do
    key = {__MODULE__, scene, identity}
    case Process.get(key) do
      nil ->
        pid = Scene.observe(scene).characters |> Enum.find(&(&1.identity == identity)) |> Map.fetch!(:player_pid)
        Process.put(key, pid)
        pid
      pid -> pid
    end
  end

end

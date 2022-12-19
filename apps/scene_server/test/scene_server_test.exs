defmodule SceneServerTest do
  use ExUnit.Case
  require Logger
  doctest SceneServer

  test "greets the world" do
    assert SceneServer.hello() == :world
  end

  test "character_data raw" do
    dev_attrs = %{"mmr"=> 20, "cph"=> 20, "cct"=> 20, "pct"=> 20, "rsl"=> 20}
    location = {1.0, 2.0, 3.0}
    {:ok, physys_ref} = SceneServer.Native.SceneOps.new_physics_system()
    {:ok, cdata_ref} = SceneServer.Native.SceneOps.new_character_data(0, "tuser", location, dev_attrs, physys_ref)
    {:ok, cd_raw} = SceneServer.Native.SceneOps.get_character_data_raw(cdata_ref, physys_ref)
    result = SceneServer.Native.SceneOps.movement_tick(cdata_ref, physys_ref)
    Logger.debug(inspect(cd_raw, pretty: true))
  end

  test "new_physics_system" do
    {:ok, physys_ref} = SceneServer.Native.SceneOps.new_physics_system()
    Logger.debug(inspect(physys_ref, pretty: true))
    assert is_reference(physys_ref)
  end
end

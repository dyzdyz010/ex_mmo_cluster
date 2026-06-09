defmodule Mix.Tasks.SceneServerNaturalPhenomenonObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SceneServer.CliObserve

  test "prints and logs a CLI-observable high-temperature combustion smoke" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-natural-phenomenon-observe-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    try do
      File.rm(observe_log)

      output =
        capture_io(fn ->
          Mix.Tasks.SceneServer.NaturalPhenomenonObserve.run([
            "--observe-log",
            observe_log,
            "--logical-scene-id",
            "86",
            "--coord",
            "0,0,0",
            "--target-temperature",
            "720",
            "--max-ticks",
            "4"
          ])
        end)

      assert output =~ "scene_natural_phenomenon_observe=ok"
      assert output =~ "logical_scene_id=86"
      assert output =~ "coord=0,0,0"
      assert output =~ "material=wood"
      assert output =~ "combustion_stage="
      assert output =~ "active_combustion=true"
      assert output =~ "observe_log=#{observe_log}"

      CliObserve.flush_path(observe_log)
      log = File.read!(observe_log)
      assert log =~ ~s(event="scene_natural_phenomenon_smoke_completed")
      assert log =~ ~s(event="voxel_combustion_ignited")
      assert log =~ "combustion_stage: :burning"
      assert log =~ "fuel_mass_kg_per_m3:"
      assert log =~ "smoke_density_percent:"
      assert log =~ "structural_integrity_percent:"
    after
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end
end

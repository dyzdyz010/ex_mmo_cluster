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
      assert output =~ "phenomenon=combustion"
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

  test "prints and logs a CLI-observable multi-material combustion spread smoke" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-combustion-spread-observe-#{System.unique_integer([:positive])}.log"
      )

    logical_scene_id = 86_300 + System.unique_integer([:positive])
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    try do
      File.rm(observe_log)

      output =
        capture_io(fn ->
          Mix.Tasks.SceneServer.NaturalPhenomenonObserve.run([
            "--scenario",
            "spread",
            "--observe-log",
            observe_log,
            "--logical-scene-id",
            Integer.to_string(logical_scene_id),
            "--coord",
            "0,0,0",
            "--target-temperature",
            "1000",
            "--max-ticks",
            "8"
          ])
        end)

      assert output =~ "scene_natural_phenomenon_observe=ok"
      assert output =~ "phenomenon=combustion"
      assert output =~ "scenario=spread"
      assert output =~ "logical_scene_id=#{logical_scene_id}"
      assert output =~ "spread_cell_count=5"
      assert output =~ ~r/spread_ignited_count=[4-9]/
      assert output =~ ~r/spread_residue_count=[4-9]/
      assert output =~ "spread_inert_count=1"
      assert output =~ "fast_fuel:dry_grass->empty"
      assert output =~ "ash_fuel:cloth->ash"
      assert output =~ "inert_control:stone->stone"
      assert output =~ "char_fuel:wood->charcoal"
      assert output =~ "observe_log=#{observe_log}"

      CliObserve.flush_path(observe_log)
      log = File.read!(observe_log)
      assert log =~ ~s(event="scene_natural_phenomenon_smoke_completed")
      assert log =~ ~s(event="scene_combustion_spread_cell_observed")
      assert log =~ ~s(event="voxel_combustion_ignited")
      assert log =~ "spread_residue_count:"
      assert log =~ "spread_inert_count: 1"
    after
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  test "prints and logs a CLI-observable corrosion smoke" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-corrosion-observe-#{System.unique_integer([:positive])}.log"
      )

    logical_scene_id = 86_700 + System.unique_integer([:positive])
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    try do
      File.rm(observe_log)

      output =
        capture_io(fn ->
          Mix.Tasks.SceneServer.NaturalPhenomenonObserve.run([
            "--phenomenon",
            "corrosion",
            "--observe-log",
            observe_log,
            "--logical-scene-id",
            Integer.to_string(logical_scene_id),
            "--coord",
            "0,0,0",
            "--moisture",
            "120",
            "--chemical-concentration",
            "45",
            "--max-ticks",
            "1"
          ])
        end)

      assert output =~ "scene_natural_phenomenon_observe=ok"
      assert output =~ "phenomenon=corrosion"
      assert output =~ "logical_scene_id=#{logical_scene_id}"
      assert output =~ "coord=0,0,0"
      assert output =~ "material=iron"
      assert output =~ "surface_state=corroding"
      assert output =~ "active_corrosion=true"
      assert output =~ "corrosion="
      assert output =~ "conductivity="
      assert output =~ "observe_log=#{observe_log}"

      CliObserve.flush_path(observe_log)
      log = File.read!(observe_log)
      assert log =~ ~s(event="scene_natural_phenomenon_smoke_completed")
      assert log =~ ~s(event="voxel_corrosion_advanced")
      assert log =~ "surface_state: :corroding"
      assert log =~ "active_corrosion: true"
      assert log =~ "corrosion_percent:"
      assert log =~ "electric_conductivity_ms_per_m:"
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

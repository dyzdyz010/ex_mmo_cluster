defmodule SceneServer.Movement.R7DemoConfigTest do
  use ExUnit.Case, async: true
  alias SceneServer.Movement.Scene

  test "authoritative coverage can contain the entire spawn Near and its collision margin" do
    source = Path.expand("../../../../../../Voxim/Docs/M1/fixtures/demo-config.json", __DIR__)
    config = source |> File.read!() |> Jason.decode!()
    config = Map.merge(config, %{
      "l0_min" => [-3, 4, -3], "l0_max_exclusive" => [4, 11, 4],
      "travel_min_m" => [-132, 304, -132], "travel_max_exclusive_m" => [196, 656, 196]
    })
    path = Path.join(System.tmp_dir!(), "r7_config_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm!(path) end)
    File.write!(path, Jason.encode!(config))
    parsed = Scene.load_config!(path)
    assert parsed.l0 == {{-3, 4, -3}, {4, 11, 4}}
    assert parsed.bounds == {{-192.0, 256.0, -192.0}, {256.0, 704.0, 256.0}}
    assert parsed.travel == {{-132.0, 304.0, -132.0}, {196.0, 656.0, 196.0}}

    # Enlarging coverage must not remove the real collision-coverage boundary check.
    File.write!(path, Jason.encode!(Map.put(config, "travel_max_exclusive_m", [300, 656, 196])))
    assert_raise MatchError, fn -> Scene.load_config!(path) end
  end
end

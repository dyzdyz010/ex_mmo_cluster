defmodule VoxelRegion.ThermalStaticPhaseTest do
  @moduledoc """
  Test-only: world-generated phase cells whose untouched default is not at the
  thermal rest state (natural snow at 273.15 K under a 293.15 K ambient) stay
  static canonical truth; a finite heat pulse next to them settles.

  Reproduces the 2026-09-23 Qinglan runaway: warmth reaching buried natural
  snow pinned it at 273.15 K, every contiguous snow cell and the terrain around
  it joined the active set, and it never settled.
  """
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.World

  @snow 4
  @dirt 7
  # Natural terrain: a 5x1x5 snow layer at y=0 with one dirt cell on top.
  @snow_cells for x <- 0..4, z <- 0..4, do: {x, 0, z}
  @dirt_cell {2, 1, 2}

  defmodule NaturalSource do
    @moduledoc "Test-only: world-generation stand-in returning the fixed natural terrain at level 0."
    @extent 66
    def open(opts), do: {:ok, %{root: Keyword.fetch!(opts, :root)}}
    def content_version(_), do: 123
    def world_dir(s), do: s.root
    def generated(_), do: 0
    def ensure(_, _, _), do: :ok

    def read(_s, level, region) do
      cells =
        if level == 0 and region == {0, 0, 0} do
          natural =
            Map.new(for(x <- 0..4, z <- 0..4, do: {{x, 0, z}, 4}) ++ [{{2, 1, 2}, 7}])

          for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>> do
            <<Map.get(natural, {lx - 1, ly - 1, lz - 1}, 0)::16-little>>
          end
        else
          :binary.copy(<<0, 0>>, @extent * @extent * @extent)
        end

      bytes = Payload.encode(%Payload{level: level, region: region, cells: cells}, %{}, 0, 123)
      {:ok, h} = Codec.decode_payload_header(bytes)
      {:ok, bytes, h}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "thermal_static_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    # The playable catalog Qinglan runs (combustion retune + tool 19): real snow phase and dirt parameters.
    catalog =
      Path.expand(
        "../../../../Voxim/Content/Voxel/Properties/Playable/Published/4b2c6abeaec3818e2203a0b95e3ee03f1cf1aed6bf796c5f33ab41001eb641ed.json",
        __DIR__
      )

    prefab = Path.join(root, "prefabs")
    File.mkdir_p!(prefab)
    # DA_ThermalEnvironment values at the time of the fix: 293.15 K, h = 10 W/(m² K), tolerance 0.01 K (the hand-computed
    # exit time below uses 0.01 K; production is 1 K since 2026-09-23 and still excludes 20 K-off natural snow).
    pulse = Path.join(root, "pulse.json")

    File.write!(
      pulse,
      Jason.encode!(%{
        classification: "Test-only",
        ambient_kelvin: 293.15,
        environment_w_per_m2_k: 10.0,
        tolerance_kelvin: 0.01,
        emissivity: 0.0,
        view_range_cells: 8,
        source_macro: Tuple.to_list(@dirt_cell),
        power_w: 1000.0,
        energy_j: 10_000.0
      })
    )

    opts = [source: NaturalSource, log: VoxelRegion.TestSupport.Log, root: root, observer: self(),
      property_catalog_path: catalog, prefab_catalog_path: prefab, name: nil]
    w = start_supervised!({World, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    %{w: w, pulse: pulse}
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [], {{-2, -2, -2}, {8, 4, 8}})

  # Real World commits until the domain settles or `until` simulated seconds pass.
  # A manual commit also re-arms the owner's 500 ms timer, so elapsed time can
  # overshoot a target; expectations are therefore evaluated at the observed time.
  defp run_until(w, until) do
    state = observe(w)

    if not state.thermal.active or state.thermal.elapsed_s >= until - 1.0e-9 do
      state
    else
      send(w, :thermal_commit)
      run_until(w, until)
    end
  end

  # Lumped model of the only thermal node (the dirt cell): C = 11000 J/K, five
  # air faces (the bottom touches snow), h = 10 W/(m² K), so tau = C/(h A) = 220 s.
  # The 1 kW source runs 10 s: dT(10) = P/(h A) (1 - e^(-10/tau)) = 0.88874 K,
  # then dT(t) = dT(10) e^(-(t-10)/tau), below the 0.01 K tolerance at 997.2 s.
  defp model_excess(t), do: 0.88874 * :math.exp(-(t - 10.0) / 220.0)

  defp rows(state), do: Map.values(state.damage)

  test "a heat pulse beside natural snow settles and never rewrites the snow", c do
    assert :ok = World.thermal_experiment(c.w, c.pulse)
    snow = MapSet.new(@snow_cells)

    warm = run_until(c.w, 600.0)
    assert Enum.all?(rows(warm), &(VoxelRegion.Damage.macro(&1) not in snow)),
      "natural snow must stay untouched canonical truth, got #{Enum.count(rows(warm), &(&1.material == @snow))} snow rows"
    assert warm.thermal.active
    [dirt] = Enum.filter(rows(warm), &(&1.material == @dirt))
    t = warm.thermal.elapsed_s
    assert t >= 600.0 and t < 990.0
    assert_in_delta (dirt.temperature_kelvin - 293.15) / model_excess(t), 1.0, 1.0e-3

    settled = run_until(c.w, 1200.0)
    refute settled.thermal.active
    # Deactivation is decided at the end of a 0.5 s commit: the first one past 997.2 s,
    # allowing one commit either way for the explicit 50 ms integration.
    assert settled.thermal.elapsed_s >= 996.5 and settled.thermal.elapsed_s <= 998.0
    assert Enum.all?(rows(settled), &(VoxelRegion.Damage.macro(&1) not in snow))
    # Energy ledger: supplied heat is either lost to air or still stored in the dirt cell.
    [dirt] = Enum.filter(rows(settled), &(&1.material == @dirt))
    assert dirt.temperature_kelvin - 293.15 <= 0.01
    assert_in_delta settled.thermal.supplied_j, 10_000.0, 1.0e-6
    assert_in_delta settled.thermal.supplied_j + settled.thermal.environment_j,
      11_000.0 * (dirt.temperature_kelvin - 293.15), 1.0e-3
  end
end

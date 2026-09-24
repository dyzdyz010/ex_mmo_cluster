defmodule VoxelRegion.ThermalDomainEquivalenceTest do
  @moduledoc """
  Test-only: the incrementally maintained thermal domain (grown seeds, cached node defaults) and the fixed
  wall-clock commit cadence must leave the physics bit-identical. A 118-cell wooden house burns on open grass
  through the real World commit path, once on the radiation-tuned catalog 5be2e8c7 with the Test-only radiation
  environment (eps 0.9) and once on the earlier catalog fbd4f301 with the eps 0 environment (where the house also
  overheats and is removed by heat damage). Every observed commit's state digest (all property rows' temperature,
  HP, fuel and burning flag, plus the energy ledger) must equal the digest recorded on master 2c4038e7 before the
  change, which rebuilt the domain from scratch in every kernel round.
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Actor

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @grass 1
  @wood 19
  @box {{-2, -2, -2}, {10, 8, 10}}

  defmodule NullLog do
    @moduledoc "Test-only: log stand-in that keeps nothing; this test never restarts the World."
    def open(dir, _), do: dir
    def replay(_), do: []
    def append(_, _), do: :ok
    def checkpoint(_, _), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "thermal_equivalence_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(c, digest, environment) do
    catalog = Path.join(c.root, "properties.json")
    File.cp!(Path.join(@fixtures, digest <> ".json"), catalog)
    env = Path.join(c.root, "environment.json")
    File.cp!(Path.join(@fixtures, environment), env)
    w = start_supervised!({World, [source: VoxelRegion.TestSupport.Source, log: NullLog, root: c.root, observer: self(),
      name: nil, property_catalog_path: catalog, thermal_environment_path: env, production_materials: [15, @wood]]})
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{15 => 10_000_000})
    w
  end

  # The fire_furnace_production_test house: 7x4x7, walls and roof one cell thick, door 1x2 and one window.
  defp house do
    for x <- 0..6, y <- 1..4, z <- 0..6, x in [0, 6] or z in [0, 6] or y == 4,
        {x, y, z} not in [{3, 1, 0}, {3, 2, 0}, {6, 2, 3}], do: {{x, y, z}, @wood}
  end

  defp ignite(w) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {6.5, 1.5, -4.0},
      tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
    q = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0, tool_id: 9, direction: {0.0, 0.0, 1.0},
      micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, t} = World.tool_intent(w, a, q)
    r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material])) |> Map.put(:action, 1)
    {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: 1_000_000, clock_node: node()}), r)
  end

  defp digest(s) do
    rows =
      s.damage
      |> Enum.map(fn {key, t} ->
        {key, Map.get(t, :temperature_kelvin), t.hp, Map.get(t, :remaining_fuel_j), Map.get(t, :burning)}
      end)
      |> Enum.sort()

    ledger = Map.take(s.thermal, [:supplied_j, :environment_j, :combustion_j, :combustion_removed_j, :removed_j,
      :discarded_fuel_j, :fuel_initialized_j, :elapsed_s])

    :crypto.hash(:sha256, :erlang.term_to_binary({rows, Enum.sort(ledger)})) |> Base.encode16(case: :lower)
  end

  # Timer and manual commits both advance exactly 0.5 s; every observed post-commit state is keyed by elapsed time.
  defp run(w, until, trace \\ %{}) do
    send(w, :thermal_commit)
    s = VoxelRegion.TestSupport.observe(w, [], @box)
    trace = Map.put(trace, s.thermal.elapsed_s, digest(s))
    if s.thermal.elapsed_s >= until or not s.thermal.active, do: trace, else: run(w, until, trace)
  end

  defp burn(c, digest, environment) do
    w = start(c, digest, environment)
    {:ok, _} = World.apply_edits(w, (for x <- -1..7, z <- -1..7, do: {{x, 0, z}, @grass}) ++ house())
    ignite(w)
    run(w, 600.0)
  end

  defp assert_recorded(trace, recorded, label) do
    observed = for {elapsed, digest} <- trace, Map.has_key?(recorded, elapsed), do: {elapsed, digest}
    for {elapsed, digest} <- Enum.sort(trace), rem(trunc(elapsed * 2), 20) == 0,
      do: IO.puts("THERMAL_DIGEST #{label} #{inspect(elapsed)} #{digest}")
    assert length(observed) >= div(map_size(recorded), 2)
    for {elapsed, digest} <- observed, do: assert({elapsed, digest} == {elapsed, recorded[elapsed]})
  end

  # Recorded on master 2c4038e7 (full domain rebuild in every kernel round), every 10 s of simulated time.
  @radiation %{
    10.0 => "77aaec307398b91b44cc8a5ddd7399b9f5fcd1716f895f137499e61a7a22e6bf",
    20.0 => "ded51dff4ea6c442cde7bcf26526385356cc07459a8e22fb2f010be253fb398c",
    30.000000000000004 => "a75dec7ba61d80459ac5ce7b9aae28ada7dec11363b90fcbb2103ae14e8f64a4",
    40.00000000000001 => "4281bdf1a903ba6a114f171f9337f6bb61bbc1d4b097cb7b5b5881987f141749",
    50.000000000000014 => "986efc0ab0369e54e0ccd0bbbe0ba4839af42283928c2240544ee1090f5a818b",
    60.000000000000014 => "c952742635d6f3368e7b82e20d745b0a1a11b312261236846e8e231192abb104",
    70.00000000000001 => "7ec0fdb56429cdb20a287bdc423a612547c08a9d4b1f257a5d52ac623fa856ef",
    80.0 => "f1c0bd6603c8f23bfaf41a0c56364a884754a623402e96011b27779b498f1faf",
    90.49999999999999 => "e53dccbe9f519e54d1267cd52f72f650fa9b181bb6f5fc28126a60aa953ac7b2",
    100.49999999999999 => "366059b2eeb346793843992490782c153b4b66eeeadb2388aeada98f3fdd91e6",
    110.49999999999999 => "fa794a1b907653b6d945ed580d0c94b0a7a87221d559f3a3931cf730a365f509",
    120.49999999999997 => "ac19b946d5aa049f4447980666da29f6f987af88796688202753a2cf048adde3",
    130.49999999999991 => "f8de70498c002030268aed9a9018801a40410a0578757ae9a86e5fb8ed78aae0",
    420.0000000000002 => "7acffc9c6acdf5fed029b7d0ecf5ffcce40d541b2bc63402294b7fb026e91a04",
    430.0000000000002 => "8f644516f8c1b658bab50f5fba658b94d48f6ff2ff54f23d6091643b0289de77",
    440.0000000000002 => "0e6cfb5ee0f7d4729c947318b711125cf06742226c5000d453db5d56fc386aa3",
    450.0000000000002 => "617df71fe40b4db8d5a3689b79e1e43e144b3c3177f1b1c475e539e7c04fb376",
    460.0000000000002 => "1d7c030363d75d8aa0523fb7c1634a78db209967307654194530dd7bad92d4b0",
    470.0000000000002 => "6742e1926682a69ee52c482023686d3df75c30e9cfde1376c16e26bd6399ded6",
    480.0000000000002 => "abf26354f9e9ef80af2b61fb22186351bac392f36888f82ab3670ec9e67f36cb",
    490.0000000000002 => "dc9519a312aca067a52688c8f5627313e161b6beafb55caf0cc26dbdaab1aa57",
    500.0000000000002 => "368bdfc0d8747e99409f2f6c93d62deb8121700e6796be6b5f7ab49991d61f77",
    510.0000000000002 => "557a1937fc67bdee245334823ca09b112c87d72fcda66b175a4d49e0edee212c",
    520.0000000000002 => "e133c177241e06692c44f27353fe6e986cdbcdac79d8f8522a512ba1e4fd9d5c",
    530.0000000000002 => "e38ed7649be2372516965ad3c04b60963cbc15bedc6a83ad1280a4c1c237df67",
    540.0000000000002 => "57c508039ef0f939a142859c9d7854391bffcb294d4879b102039e24f5d1be5b",
    550.0000000000002 => "f455b3c559912670ea3fc59352566c5f0661941325c6e57289257ff4b7eb4b48",
    560.0000000000002 => "50e6462b3be369e37ca7a2e8a5f516194d1787fdb649724dcb8a7419f2c63595",
    570.0000000000002 => "9cedcdca5cf50d9e79af65fa6e09ddf25ca93d7cfeda5d713af80fdaccca1288",
    590.0000000000002 => "38fe1e69686847936f41fce5d75aa57d71da17694e7988521a05694082094b91",
    600.0000000000002 => "9e8c56ec909fd9a08f5cc1f863a2057bb553fca8b7af9a0de84d0e5b9db0ffc5"
  }

  @zero %{
    10.000000000000002 => "cf6e4841e6f06b9089c512ec5c2c4b10a72d62e75a8c5f8cec99dd62c5e458c9",
    20.000000000000004 => "d7cfc60a906d5172d83ea7b5c7f8d8b8650cb3e1b5e75c164d4fbe3180df52cd",
    30.000000000000004 => "1c51dd2b0e21da842c75fc406c07d171e1d45eb2786cdeefb9a9af5d8f7b705e",
    40.0 => "888e970dd139f00c3e971725f4106ee2d4a1bdf666a0eb1e648b4e770c359eff",
    50.0 => "801ac88c0728368e8ead7759f04966f77fd2df56184ad635214bdaaaecfbf12c",
    60.0 => "073e5ea2ae249123afd30e4758e5f68160ebc78a7dd97e576ef603e0643cb9db",
    70.0 => "8d509717b1bd84628ccbf8acc8ae1e685a8787da2e268dedeb787e6578802792",
    80.0 => "4a6c8a3068df2b2179a1e521b89e45c522fd440f0192f00d3e6a32dbed383cb7",
    90.0 => "03f76d85f9975c9368307b107169182f59402c05db9ce6d7651a64c7371da40e",
    100.49999999999999 => "6acdb62e3869d04ec6196f721c2790e7a0c0cc496d6cf35b75f282fb02fc24f0",
    110.49999999999999 => "2e5bb386a494c84a03438acdc4f1a1b21cfb3e593b61d3f683877cdd083313c2",
    120.49999999999997 => "cc8ff7e2041fc995b6e3653dba7621beaa3698fd958b40796913ea426933f973",
    130.49999999999997 => "e2250b1c64b7249455c3e7c8668af6ffd73b98de17639c03f2be7f0cacb0720c",
    140.49999999999997 => "aaf724ad14d18592d633494f9c01e30c0d11b37abc3541fef16c4aba28fa36e9",
    150.49999999999997 => "164cc324fb677fdafc8298d76b56e371ffe0cbe1fc0c72dae04366633ad0f792",
    160.00000000000014 => "b3b5ae1a851ee535cdbb1cf69760a80bb620269f07de61e7ffd2bf897d6b4327",
    170.0000000000002 => "3680799ee2519619bd1eee68e32c91bb95d6873ec3851597a9c3c7157b866000",
    180.00000000000028 => "036fa6ff3873fde7d75aae0ec22dcd8826d2bcd750e314ece072eca9bd22f2d5",
    190.00000000000028 => "67507f2c3e8f8170770fe3191cfbbfa5d075397282bf1140f64429a918a19798",
    200.0000000000003 => "db1cf591925423910b82d31b86e32499c56e73b90ab22f8f8f1859de3ccec2a6"
  }

  test "radiation catalog, eps 0.9: a burning house matches the full-rebuild digests commit by commit", c do
    trace = burn(c, "5be2e8c79d8789a29aa17e023294c8aafbff51ff4b8c07a945035dbfcf91fe57", "environment-radiation.json")
    assert_recorded(trace, @radiation, :radiation)
  end

  test "earlier catalog, eps 0: a burning house matches the full-rebuild digests commit by commit", c do
    trace = burn(c, "fbd4f30106f1cecbd5ea73cb361b7e19058a531420fbaf86998ad89f43f6ba70", "environment.json")
    assert_recorded(trace, @zero, :zero)
  end
end

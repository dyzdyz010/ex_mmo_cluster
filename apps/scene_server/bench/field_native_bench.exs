# Field native backend benchmark.
#
# Compares the production Rustler-backed Field kernels against their Elixir
# reference backends on the same Field-side inputs. This isolates pure field
# math after authority/runtime state has already been normalized.
#
# Run with:
#   cd apps/scene_server
#   ITERATIONS=5000 mix run bench/field_native_bench.exs

alias SceneServer.Voxel.{NormalBlockData, Storage, Types}

alias SceneServer.Voxel.Field.{
  ElectricField,
  FieldRegion,
  KernelContext,
  ParticipantProjection,
  TemperatureField
}

alias SceneServer.Voxel.Field.Kernels.{
  ConductionPathKernel,
  ElectricPotentialKernel,
  TemperatureDiffusionKernel
}

iterations =
  System.get_env("ITERATIONS", "5000")
  |> String.to_integer()
  |> max(1)

measure = fn fun ->
  for _ <- 1..50, do: fun.()

  samples =
    for _ <- 1..iterations do
      {us, _result} = :timer.tc(fun)
      us
    end

  sorted = Enum.sort(samples)
  total = Enum.sum(samples)
  count = length(samples)
  p50 = Enum.at(sorted, div(count, 2))
  p95 = Enum.at(sorted, min(count - 1, trunc(Float.ceil(count * 0.95)) - 1))
  p99 = Enum.at(sorted, min(count - 1, trunc(Float.ceil(count * 0.99)) - 1))

  %{
    avg: total / count,
    p50: p50,
    p95: p95,
    p99: p99,
    max: List.last(sorted)
  }
end

print_pair = fn label, native, elixir ->
  speedup =
    if native.avg > 0 do
      elixir.avg / native.avg
    else
      0.0
    end

  IO.puts("[#{label}]")

  IO.puts(
    "  native avg=#{Float.round(native.avg, 2)}us p50=#{native.p50}us p95=#{native.p95}us p99=#{native.p99}us max=#{native.max}us"
  )

  IO.puts(
    "  elixir avg=#{Float.round(elixir.avg, 2)}us p50=#{elixir.p50}us p95=#{elixir.p95}us p99=#{elixir.p99}us max=#{elixir.max}us"
  )

  IO.puts("  avg_speedup=#{Float.round(speedup, 2)}x")
  IO.puts("")
end

build_conduction_region = fn region_id, source, aabb ->
  FieldRegion.new(%{
    region_id: region_id,
    chunk_coord: {0, 0, 0},
    aabb: aabb,
    kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
    source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
  })
end

measure_conduction = fn scenario, backend ->
  %{region: region, context: context, projection: projection, target: target} = scenario

  opts = %{
    target_macro_index: target,
    participant_projection: projection,
    path_backend: backend
  }

  measure.(fn -> ConductionPathKernel.tick(region, context, opts) end)
end

short_source = Types.macro_index!({0, 1, 0})
short_target = Types.macro_index!({3, 1, 0})

short_storage =
  Storage.new(7, {0, 0, 0})
  |> Storage.put_solid_block({0, 1, 0}, NormalBlockData.new(5))
  |> Storage.put_solid_block({3, 1, 0}, NormalBlockData.new(5))
  |> Storage.put_solid_block({1, 1, 0}, NormalBlockData.new(3))
  |> Storage.put_solid_block({2, 1, 0}, NormalBlockData.new(3))
  |> Storage.put_solid_block({0, 0, 0}, NormalBlockData.new(5))
  |> Storage.put_solid_block({1, 0, 0}, NormalBlockData.new(5))
  |> Storage.put_solid_block({2, 0, 0}, NormalBlockData.new(5))
  |> Storage.put_solid_block({3, 0, 0}, NormalBlockData.new(5))

wide_source = Types.macro_index!({0, 0, 0})
wide_target = Types.macro_index!({15, 15, 0})

wide_storage =
  Enum.reduce(for(x <- 0..15, y <- 0..15, do: {x, y, 0}), Storage.new(7, {0, 0, 0}), fn coord,
                                                                                        acc ->
    Storage.put_solid_block(acc, coord, NormalBlockData.new(5))
  end)

conduction_scenarios = [
  %{
    name: "conduction_short_detour",
    region: build_conduction_region.(17, short_source, {{0, 0, 0}, {3, 1, 0}}),
    context:
      KernelContext.new(
        build_conduction_region.(17, short_source, {{0, 0, 0}, {3, 1, 0}}),
        7,
        short_storage,
        dt_ms: 100
      ),
    projection: ParticipantProjection.build(short_storage),
    target: short_target
  },
  %{
    name: "conduction_wide_plane",
    region: build_conduction_region.(18, wide_source, {{0, 0, 0}, {15, 15, 0}}),
    context:
      KernelContext.new(
        build_conduction_region.(18, wide_source, {{0, 0, 0}, {15, 15, 0}}),
        7,
        wide_storage,
        dt_ms: 100
      ),
    projection: ParticipantProjection.build(wide_storage),
    target: wide_target
  }
]

temperature_source = Types.macro_index!({3, 3, 3})

temperature_storage =
  Storage.new(7, {0, 0, 0})
  |> Storage.put_solid_block(temperature_source, NormalBlockData.new(5))
  |> Storage.put_solid_block({4, 3, 3}, NormalBlockData.new(5))

temperature_region =
  FieldRegion.new(%{
    region_id: 19,
    chunk_coord: {0, 0, 0},
    aabb: {{0, 0, 0}, {7, 7, 7}},
    kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
    source_points: [
      %{
        macro_index: temperature_source,
        field_type: :temperature,
        source_mode: :impulse,
        value: 800.0
      }
    ]
  })

measure_temperature = fn backend ->
  measure.(fn ->
    TemperatureField.tick(temperature_region, temperature_storage,
      diffusion_time_scale: 20_000.0,
      ambient_loss_per_second: 0.08,
      temperature_backend: backend
    )
  end)
end

electric_source = Types.macro_index!({0, 0, 0})

electric_region =
  FieldRegion.new(%{
    region_id: 20,
    chunk_coord: {0, 0, 0},
    aabb: {{0, 0, 0}, {15, 15, 0}},
    kernels: [%{id: :electric_potential, module: ElectricPotentialKernel}],
    source_points: [
      %{
        macro_index: electric_source,
        field_type: :electric_potential,
        value: 100.0
      }
    ]
  })

electric_storage =
  for(x <- 0..15, y <- 0..15, do: {x, y, 0})
  |> Enum.reduce(Storage.new(7, {0, 0, 0}), fn coord, acc ->
    Storage.put_solid_block(acc, coord, NormalBlockData.new(5))
  end)

measure_electric = fn backend ->
  measure.(fn ->
    ElectricField.tick(electric_region, electric_storage, electric_backend: backend)
  end)
end

IO.puts("=== Field native backend vs Elixir reference ===")
IO.puts("iterations=#{iterations}")
IO.puts("")

Enum.each(conduction_scenarios, fn scenario ->
  print_pair.(
    scenario.name,
    measure_conduction.(scenario, :native),
    measure_conduction.(scenario, :elixir)
  )
end)

print_pair.(
  "temperature_sparse_diffusion",
  measure_temperature.(:native),
  measure_temperature.(:elixir)
)

print_pair.(
  "electric_potential_plane",
  measure_electric.(:native),
  measure_electric.(:elixir)
)

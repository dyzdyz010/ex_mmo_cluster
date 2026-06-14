defmodule SceneServer.Voxel.Field.NativeBackend do
  @moduledoc """
  Field-layer native computation backend.

  This module is the public Field-side facade for pure, chunk-local Rustler
  field kernels. It owns backend selection, fallback policy, and request
  encoding. It may freeze read-only Storage-derived facts into DTOs, but it
  does not own Storage/FieldRegion lifecycle, FieldLayer mutation, truth writes,
  or observe effects.
  """

  alias SceneServer.Native.FieldKernel
  alias SceneServer.Voxel.Field.{FieldLayer, ParticipantProjection}
  alias SceneServer.Voxel.Field.NativeBackend.ConductionPathInput
  alias SceneServer.Voxel.Field.NativeBackend.DischargePathInput
  alias SceneServer.Voxel.Field.NativeBackend.ElectricPotentialInput
  alias SceneServer.Voxel.Field.NativeBackend.TemperatureDiffusionInput
  alias SceneServer.Voxel.Storage

  @type aabb :: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}
  @type backend :: :native | :elixir
  @type fallback(result) :: (-> {:ok, result} | {:error, atom()})

  @doc """
  Finds an electric conduction path through a read-only participant projection.

  `opts[:backend]` chooses `:native` or `:elixir`; `opts[:fallback]` is invoked
  for explicit Elixir backend selection or when native code is unavailable.
  Native domain errors such as `:frontier_exhausted` are returned as-is.
  """
  @spec find_conduction_path(
          ParticipantProjection.t(),
          aabb(),
          0..4095,
          0..4095,
          number(),
          FieldLayer.t(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, [0..4095]}
          | {:error,
             :source_not_conductive
             | :target_not_conductive
             | :frontier_exhausted
             | :unreachable
             | :native_unavailable
             | :native_disabled
             | atom()}
  def find_conduction_path(
        %ParticipantProjection{} = projection,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        %FieldLayer{} = ionization_layer,
        max_frontier,
        opts \\ []
      ) do
    fallback = Keyword.get(opts, :fallback)

    case backend_opt(Keyword.get(opts, :backend, :native)) do
      :elixir ->
        run_fallback(fallback, :native_disabled)

      :native ->
        request =
          ConductionPathInput.new(
            projection,
            aabb,
            source_macro_index,
            target_macro_index,
            source_value,
            ionization_layer,
            max_frontier
          )

        case call_native_conduction_path(request) do
          {:error, :native_unavailable} -> run_fallback(fallback, :native_unavailable)
          result -> result
        end
    end
  end

  @doc """
  Finds a dielectric-breakdown discharge path through a read-only storage snapshot.

  `opts[:backend]` chooses `:native` or `:elixir`; `opts[:fallback]` is invoked
  for explicit Elixir backend selection or when native code is unavailable.
  Native domain errors such as `:frontier_exhausted` and `:no_discharge_path`
  are returned as-is.
  """
  @spec find_discharge_path(
          Storage.t(),
          aabb(),
          0..4095,
          0..4095,
          number(),
          FieldLayer.t(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, [0..4095]}
          | {:error,
             :frontier_exhausted | :no_discharge_path | :native_unavailable | :native_disabled}
  def find_discharge_path(
        %Storage{} = storage,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        %FieldLayer{} = ionization_layer,
        max_frontier,
        opts \\ []
      ) do
    fallback = Keyword.get(opts, :fallback)

    case backend_opt(Keyword.get(opts, :backend, :native)) do
      :elixir ->
        run_fallback(fallback, :native_disabled)

      :native ->
        request =
          DischargePathInput.new(
            storage,
            aabb,
            source_macro_index,
            target_macro_index,
            source_value,
            ionization_layer,
            max_frontier
          )

        case call_native_discharge_path(request) do
          {:error, :native_unavailable} -> run_fallback(fallback, :native_unavailable)
          result -> result
        end
    end
  end

  @doc """
  原地演化温度层一格扩散步(梯队2 step2.7c,BND-1)。

  场层本体常驻 Rust `ResourceArc`;`diffuse_temperature_sim` 直读 active 缓冲(旧)、Rust 内双缓冲、
  原地写 `layer.cell_sim`。Elixir 不再 apply delta。返回 `:ok`(layer 句柄已被 mutate)。
  """
  @spec diffuse_temperature(
          FieldLayer.t(),
          aabb(),
          [0..4095],
          Storage.t() | nil,
          number(),
          number(),
          number(),
          number()
        ) :: :ok
  def diffuse_temperature(
        %FieldLayer{} = layer,
        aabb,
        candidate_indices,
        storage,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters
      ) do
    request =
      TemperatureDiffusionInput.new(
        aabb,
        candidate_indices,
        storage,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters
      )

    FieldKernel.diffuse_temperature_sim(
      layer.cell_sim,
      request.candidates,
      request.aabb,
      request.thermal_properties,
      request.diffusion_seconds,
      request.ambient_dt_seconds,
      request.ambient_loss_per_second,
      request.cell_size_meters
    )
  end

  @doc """
  原地演化电势 + ionization 两层一 tick(梯队2 step2.7c,BND-1)。

  potential / ionization 本体常驻 Rust;`propagate_electric_potential_sim` 读 ionization 句柄、
  merge 写 potential 句柄、clear+写 ionization 句柄。返回 `:ok`(两 layer 句柄已被 mutate)。
  """
  @spec propagate_electric_potential(
          FieldLayer.t(),
          FieldLayer.t(),
          [map()],
          aabb(),
          ParticipantProjection.t()
        ) :: :ok
  def propagate_electric_potential(
        %FieldLayer{} = potential_layer,
        %FieldLayer{} = ionization_layer,
        source_points,
        aabb,
        %ParticipantProjection{} = projection
      )
      when is_list(source_points) do
    request = ElectricPotentialInput.new(source_points, aabb, projection)

    FieldKernel.propagate_electric_potential_sim(
      potential_layer.cell_sim,
      ionization_layer.cell_sim,
      request.sources,
      request.entries,
      request.aabb
    )
  end

  defp call_native_conduction_path(%ConductionPathInput{} = request) do
    FieldKernel.find_conduction_path(
      request.entries,
      request.aabb,
      request.source_macro_index,
      request.target_macro_index,
      request.source_value,
      request.ionization_cells,
      request.max_frontier
    )
  rescue
    ErlangError -> {:error, :native_unavailable}
    UndefinedFunctionError -> {:error, :native_unavailable}
  end

  defp call_native_discharge_path(%DischargePathInput{} = request) do
    FieldKernel.find_discharge_path(
      request.cells,
      request.aabb,
      request.source_macro_index,
      request.target_macro_index,
      request.source_value,
      request.ionization_cells,
      request.max_frontier
    )
  rescue
    ErlangError -> {:error, :native_unavailable}
    UndefinedFunctionError -> {:error, :native_unavailable}
  end

  defp run_fallback(fallback, _reason) when is_function(fallback, 0), do: fallback.()
  defp run_fallback(_fallback, reason), do: {:error, reason}

  defp backend_opt(value) when value in [:elixir, "elixir"], do: :elixir
  defp backend_opt(_value), do: :native
end

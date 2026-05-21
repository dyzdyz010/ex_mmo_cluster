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
  Computes one sparse temperature diffusion step.

  The return value is a list of `{macro_index, delta_from_temperature_baseline}`
  updates. Elixir owns applying those deltas back into the `FieldLayer`.
  """
  @spec diffuse_temperature(
          FieldLayer.t(),
          aabb(),
          [0..4095],
          Storage.t() | nil,
          number(),
          number(),
          number(),
          number(),
          keyword()
        ) :: {:ok, [{0..4095, float()}]} | {:error, :native_unavailable | :native_disabled}
  def diffuse_temperature(
        %FieldLayer{} = layer,
        aabb,
        candidate_indices,
        storage,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters,
        opts \\ []
      ) do
    fallback = Keyword.get(opts, :fallback)

    case backend_opt(Keyword.get(opts, :backend, :native)) do
      :elixir ->
        run_fallback(fallback, :native_disabled)

      :native ->
        request =
          TemperatureDiffusionInput.new(
            layer,
            aabb,
            candidate_indices,
            storage,
            diffusion_seconds,
            ambient_dt_seconds,
            ambient_loss_per_second,
            cell_size_meters
          )

        case call_native_temperature_diffusion(request) do
          {:error, :native_unavailable} -> run_fallback(fallback, :native_unavailable)
          result -> result
        end
    end
  end

  @doc """
  Propagates electric potential and ionization for one chunk-local field tick.

  The return value is `%{potential_cells: cells, ionization_cells: cells}`.
  Elixir owns clearing and applying those cells back into `FieldLayer`s.
  """
  @spec propagate_electric_potential(
          [map()],
          aabb(),
          FieldLayer.t(),
          ParticipantProjection.t(),
          keyword()
        ) ::
          {:ok, %{potential_cells: [{0..4095, float()}], ionization_cells: [{0..4095, float()}]}}
          | {:error, :native_unavailable | :native_disabled}
  def propagate_electric_potential(
        source_points,
        aabb,
        %FieldLayer{} = ionization_layer,
        %ParticipantProjection{} = projection,
        opts \\ []
      )
      when is_list(source_points) do
    fallback = Keyword.get(opts, :fallback)

    case backend_opt(Keyword.get(opts, :backend, :native)) do
      :elixir ->
        run_fallback(fallback, :native_disabled)

      :native ->
        request =
          ElectricPotentialInput.new(
            source_points,
            aabb,
            ionization_layer,
            projection
          )

        case call_native_electric_potential(request) do
          {:error, :native_unavailable} -> run_fallback(fallback, :native_unavailable)
          result -> result
        end
    end
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

  defp call_native_temperature_diffusion(%TemperatureDiffusionInput{} = request) do
    {:ok,
     FieldKernel.diffuse_temperature(
       request.cells,
       request.candidates,
       request.aabb,
       request.thermal_properties,
       request.diffusion_seconds,
       request.ambient_dt_seconds,
       request.ambient_loss_per_second,
       request.cell_size_meters
     )}
  rescue
    ErlangError -> {:error, :native_unavailable}
    UndefinedFunctionError -> {:error, :native_unavailable}
  end

  defp call_native_electric_potential(%ElectricPotentialInput{} = request) do
    {potential_cells, ionization_cells} =
      FieldKernel.propagate_electric_potential(
        request.sources,
        request.entries,
        request.aabb,
        request.ionization_cells
      )

    {:ok, %{potential_cells: potential_cells, ionization_cells: ionization_cells}}
  rescue
    ErlangError -> {:error, :native_unavailable}
    UndefinedFunctionError -> {:error, :native_unavailable}
  end

  defp run_fallback(fallback, _reason) when is_function(fallback, 0), do: fallback.()
  defp run_fallback(_fallback, reason), do: {:error, reason}

  defp backend_opt(value) when value in [:elixir, "elixir"], do: :elixir
  defp backend_opt(_value), do: :native
end

defmodule SceneServer.Voxel.DirtyMacroBounds do
  @moduledoc """
  Half-open local macro bounds for dirty chunk work.

  The bounds identify the smallest local macro range that needs follow-up work
  such as persistence, mesh rebuild, or rule simulation. This metadata is not
  part of the canonical chunk content hash.
  """

  alias SceneServer.Voxel.Types

  defstruct min_macro: {0, 0, 0},
            max_macro: {0, 0, 0},
            reason_flags: 0

  @type bound_coord :: {0..16, 0..16, 0..16}

  @type t :: %__MODULE__{
          min_macro: bound_coord(),
          max_macro: bound_coord(),
          reason_flags: 0..0xFFFF
        }

  @doc "Builds empty dirty bounds."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Builds and validates half-open local macro dirty bounds."
  @spec new(term(), term(), keyword()) :: t()
  def new(min_macro, max_macro, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:min_macro, min_macro)
    |> Map.put(:max_macro, max_macro)
    |> normalize!()
  end

  @doc "Normalizes dirty bounds from a struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = bounds) do
    bounds
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    {min_macro, max_macro} =
      Types.normalize_local_macro_aabb!(
        fetch(attrs, :min_macro, {0, 0, 0}),
        fetch(attrs, :max_macro, {0, 0, 0})
      )

    %__MODULE__{
      min_macro: min_macro,
      max_macro: max_macro,
      reason_flags: uint16!(fetch(attrs, :reason_flags, 0))
    }
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint16!(value) when is_integer(value) and value >= 0 and value <= 0xFFFF, do: value

  defp uint16!(value) do
    raise ArgumentError, "expected reason_flags u16, got: #{inspect(value)}"
  end
end

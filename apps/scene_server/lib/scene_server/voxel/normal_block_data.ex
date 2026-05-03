defmodule SceneServer.Voxel.NormalBlockData do
  @moduledoc """
  Fixed v1 payload for a normal solid block occupying one full macro cell.

  The wire representation is exactly 20 bytes and all multibyte fields are
  encoded big-endian by `SceneServer.Voxel.Codec`.
  """

  defstruct material_id: 0,
            state_flags: 0,
            health: 0,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0

  @type t :: %__MODULE__{
          material_id: 0..0xFFFF,
          state_flags: 0..0xFFFF_FFFF,
          health: 0..0xFFFF,
          temperature_delta: -0x8000..0x7FFF,
          moisture_delta: -0x8000..0x7FFF,
          attribute_set_ref: 0..0xFFFF_FFFF,
          tag_set_ref: 0..0xFFFF_FFFF
        }

  @doc "Builds and validates normal-block payload data."
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(material_id, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:material_id, material_id)
    |> normalize!()
  end

  @doc "Normalizes a normal-block struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = block) do
    block
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      material_id: uint!(fetch(attrs, :material_id, 0), 16, :material_id),
      state_flags: uint!(fetch(attrs, :state_flags, 0), 32, :state_flags),
      health: uint!(fetch(attrs, :health, 0), 16, :health),
      temperature_delta: int!(fetch(attrs, :temperature_delta, 0), 16, :temperature_delta),
      moisture_delta: int!(fetch(attrs, :moisture_delta, 0), 16, :moisture_delta),
      attribute_set_ref: uint!(fetch(attrs, :attribute_set_ref, 0), 32, :attribute_set_ref),
      tag_set_ref: uint!(fetch(attrs, :tag_set_ref, 0), 32, :tag_set_ref)
    }
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint!(value, bits, label) when is_integer(value) do
    max = trunc(:math.pow(2, bits)) - 1

    if value < 0 or value > max do
      raise ArgumentError, "#{label} value #{value} outside u#{bits}"
    end

    value
  end

  defp uint!(value, bits, label) do
    raise ArgumentError, "expected #{label} u#{bits}, got: #{inspect(value)}"
  end

  defp int!(value, bits, label) when is_integer(value) do
    min = -trunc(:math.pow(2, bits - 1))
    max = trunc(:math.pow(2, bits - 1)) - 1

    if value < min or value > max do
      raise ArgumentError, "#{label} value #{value} outside i#{bits}"
    end

    value
  end

  defp int!(value, bits, label) do
    raise ArgumentError, "expected #{label} i#{bits}, got: #{inspect(value)}"
  end
end

defmodule SceneServer.Voxel.MacroEnvironmentSummary do
  @moduledoc """
  Sparse environment summary for one macro cell.

  Scene-side rule simulation can attach these records only where the default
  temperature or moisture model needs a per-cell override or cached current
  value.
  """

  defstruct default_temperature: 0,
            default_moisture: 0,
            current_temperature: 0,
            current_moisture: 0,
            field_mask: 0,
            source_hash: 0

  @type t :: %__MODULE__{
          default_temperature: -0x8000..0x7FFF,
          default_moisture: -0x8000..0x7FFF,
          current_temperature: -0x8000..0x7FFF,
          current_moisture: -0x8000..0x7FFF,
          field_mask: 0..0xFFFF,
          source_hash: 0..0xFFFF_FFFF
        }

  @doc "Builds and validates an environment summary."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts
    |> Map.new()
    |> normalize!()
  end

  @doc "Normalizes an environment summary struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = summary) do
    summary
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      default_temperature: int!(fetch(attrs, :default_temperature, 0), 16, :default_temperature),
      default_moisture: int!(fetch(attrs, :default_moisture, 0), 16, :default_moisture),
      current_temperature: int!(fetch(attrs, :current_temperature, 0), 16, :current_temperature),
      current_moisture: int!(fetch(attrs, :current_moisture, 0), 16, :current_moisture),
      field_mask: uint!(fetch(attrs, :field_mask, 0), 16, :field_mask),
      source_hash: uint!(fetch(attrs, :source_hash, 0), 32, :source_hash)
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

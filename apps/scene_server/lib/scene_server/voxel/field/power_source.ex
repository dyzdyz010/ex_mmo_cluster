defmodule SceneServer.Voxel.Field.PowerSource do
  @moduledoc """
  Runtime descriptor for an electric field's power source.

  `PowerSource` is not a circuit simulator and does not mutate voxel truth. It
  records what kind of supply is driving an electric field request so the
  field runtime can distinguish stable DC, oscillating AC, and one-shot pulse
  sources before later budget and gameplay-effect slices consume that policy.
  """

  @type output_mode :: :dc | :ac | :pulse

  @type t :: %__MODULE__{
          owner_ref: term(),
          output_mode: output_mode(),
          voltage: float(),
          current_limit_amps: float() | nil,
          frequency_hz: float() | nil,
          energy_budget_joules: float() | nil
        }

  defstruct owner_ref: nil,
            output_mode: :dc,
            voltage: 120.0,
            current_limit_amps: nil,
            frequency_hz: nil,
            energy_budget_joules: nil

  @doc "Normalizes user/runtime input into a bounded electric power-source descriptor."
  @spec normalize(keyword() | map()) :: t()
  def normalize(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = opts_map(attrs)

    output_mode =
      normalize_output_mode(
        fetch_any(attrs, [:output_mode, :power_output_mode, :source_output_mode], nil),
        attrs
      )

    %__MODULE__{
      owner_ref: fetch_any(attrs, [:owner_ref], nil),
      output_mode: output_mode,
      voltage:
        non_negative_float(
          fetch_any(
            attrs,
            [:voltage, :source_voltage, :power_voltage, :source_potential, :source_value],
            120.0
          )
        ),
      current_limit_amps:
        normalize_optional_non_negative_float(
          fetch_any(attrs, [:current_limit_amps, :current_limit, :power_current_limit_amps], nil)
        ),
      frequency_hz:
        normalize_optional_non_negative_float(
          fetch_any(attrs, [:frequency_hz, :power_frequency_hz], nil)
        ),
      energy_budget_joules:
        normalize_optional_non_negative_float(
          fetch_any(attrs, [:energy_budget_joules, :source_energy_budget_joules], nil)
        )
    }
  end

  @doc "Returns a JSON/log-safe summary map."
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = source), do: Map.from_struct(source)

  defp normalize_output_mode(nil, attrs) do
    case normalize_source_mode(fetch_any(attrs, [:source_mode], :persistent)) do
      :impulse -> :pulse
      :persistent -> :dc
    end
  end

  defp normalize_output_mode(value, _attrs) when value in [:dc, :ac, :pulse], do: value

  defp normalize_output_mode(value, _attrs) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "dc" -> :dc
      "direct" -> :dc
      "direct_current" -> :dc
      "direct-current" -> :dc
      "ac" -> :ac
      "alternating" -> :ac
      "alternating_current" -> :ac
      "alternating-current" -> :ac
      "pulse" -> :pulse
      "impulse" -> :pulse
      "discharge" -> :pulse
      _other -> :dc
    end
  end

  defp normalize_output_mode(_value, _attrs), do: :dc

  defp normalize_source_mode(value) when value in [:impulse, :persistent], do: value

  defp normalize_source_mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "impulse" -> :impulse
      "pulse" -> :impulse
      "persistent" -> :persistent
      _other -> :persistent
    end
  end

  defp normalize_source_mode(_value), do: :persistent

  defp opts_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp opts_map(attrs) when is_map(attrs), do: attrs

  defp fetch_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, fn key ->
      cond do
        Map.has_key?(map, key) ->
          {:found, Map.fetch!(map, key)}

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          {:found, Map.fetch!(map, Atom.to_string(key))}

        true ->
          nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp non_negative_float(value) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value) when is_float(value) and value >= 0, do: value

  defp non_negative_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0.0
    end
  end

  defp non_negative_float(_value), do: 0.0

  defp normalize_optional_non_negative_float(nil), do: nil
  defp normalize_optional_non_negative_float(value), do: non_negative_float(value)
end

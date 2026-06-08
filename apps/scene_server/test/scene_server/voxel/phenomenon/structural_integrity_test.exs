defmodule SceneServer.Voxel.Phenomenon.StructuralIntegrityTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Phenomenon.StructuralIntegrity

  test "damage effects write integrity and emit collapse candidate only on threshold crossing" do
    macro_index = 7

    effects =
      StructuralIntegrity.damage_effects(macro_index, 3, 52.0, 48.0,
        reason: :combustion_integrity_loss,
        threshold_percent: 50.0,
        context: %{stage: :burning}
      )

    assert {:write_voxel_attribute,
            %{attribute: :structural_integrity, macro_index: ^macro_index, raw_value: raw}} =
             Enum.find(effects, fn
               {:write_voxel_attribute, %{attribute: :structural_integrity}} -> true
               _other -> false
             end)

    assert raw == fixed32(48.0)

    assert {:emit_observe, "voxel_structural_collapse_candidate", fields} =
             Enum.find(effects, fn
               {:emit_observe, "voxel_structural_collapse_candidate", _fields} -> true
               _other -> false
             end)

    assert fields.reason == :combustion_integrity_loss
    assert fields.stage == :burning
    assert fields.structural_integrity_before_percent == 52.0
    assert fields.structural_integrity_after_percent == 48.0
    assert fields.structural_failure_threshold_percent == 50.0

    already_failed =
      StructuralIntegrity.damage_effects(macro_index, 3, 40.0, 35.0,
        reason: :combustion_integrity_loss,
        threshold_percent: 50.0
      )

    refute Enum.any?(already_failed, fn
             {:emit_observe, "voxel_structural_collapse_candidate", _fields} -> true
             _other -> false
           end)
  end

  test "damage effects clamp structural integrity into the percentage range" do
    assert [{:write_voxel_attribute, %{raw_value: 0}}] =
             StructuralIntegrity.damage_effects(1, 3, 0.5, -5.0,
               reason: :test,
               threshold_percent: 1.0
             )

    assert [{:write_voxel_attribute, %{raw_value: raw}}] =
             StructuralIntegrity.damage_effects(1, 3, 90.0, 120.0,
               reason: :test,
               threshold_percent: 1.0
             )

    assert raw == fixed32(100.0)
  end

  defp fixed32(value), do: round(value * 65_536)
end

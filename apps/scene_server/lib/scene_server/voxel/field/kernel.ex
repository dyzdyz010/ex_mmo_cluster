defmodule SceneServer.Voxel.Field.Kernel do
  @moduledoc """
  Behaviour for region-local field evolution.

  Phase 7.A makes kernel specs the region creation truth source. A region's
  `field_types` value is derived from kernel `required_layers/1` and then used
  as a cached wire/layer declaration for `0x73`.

  A kernel may update existing region layers and return effects. The worker
  handles observe-only effects locally; authoritative voxel/object mutations
  must be dispatched to the chunk authority and may be rejected there.
  """

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}

  @type effect ::
          {:emit_observe, String.t(), map()}
          | {:write_voxel_attribute, map()}
          | {atom(), map()}
  @type tick_result ::
          {:cont, FieldRegion.t(), [effect()]}
          | {:done, FieldRegion.t(), [effect()]}

  @callback kernel_id() :: atom()
  @callback required_layers(opts :: map()) :: [FieldRegion.field_type()]
  @callback tick(FieldRegion.t(), KernelContext.t(), opts :: map()) :: tick_result()
end

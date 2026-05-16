defmodule SceneServer.Voxel.Field.Kernel do
  @moduledoc """
  Behaviour for region-local field evolution.

  Phase 7.A makes kernel specs the region creation truth source. A region's
  `field_types` value is derived from kernel `required_layers/1` and then used
  as a cached wire/layer declaration for `0x73`.

  A kernel may update existing region layers and return future-facing effects,
  but broad side effects are not executed by the worker in this phase.
  """

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}

  @type effect :: term()
  @type tick_result ::
          {:cont, FieldRegion.t(), [effect()]}
          | {:done, FieldRegion.t(), [effect()]}

  @callback kernel_id() :: atom()
  @callback required_layers(opts :: map()) :: [FieldRegion.field_type()]
  @callback tick(FieldRegion.t(), KernelContext.t(), opts :: map()) :: tick_result()
end

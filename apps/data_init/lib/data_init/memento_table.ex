defmodule DataInit.MementoTable do
  @moduledoc """
  Local wrapper for `Memento.Table` definitions.

  Memento 0.3.2 builds query bases through `Range.new(count, 1)`, which emits
  an Elixir 1.19 descending-range warning at compile time. This wrapper keeps
  the same table metadata shape while using an explicit `//-1` range.
  """

  alias Memento.Table.Definition

  @doc false
  defmacro __using__(opts) do
    opts = Macro.expand(opts, __CALLER__)

    quote bind_quoted: [opts: opts] do
      Definition.validate_options!(opts)

      @table_attrs Keyword.fetch!(opts, :attributes)
      @table_type Keyword.get(opts, :type, :set)
      @table_opts Definition.build_options(opts)

      @query_map Definition.build_map(@table_attrs)
      @query_base DataInit.MementoTable.build_base(__MODULE__, @table_attrs)

      @info %{
        meta: Memento.Table,
        type: @table_type,
        attributes: @table_attrs,
        options: @table_opts,
        query_base: @query_base,
        query_map: @query_map,
        primary_key: hd(@table_attrs),
        size: length(@table_attrs)
      }

      defstruct Definition.struct_fields(@table_attrs)
      def __info__, do: @info
    end
  end

  @doc false
  def build_base(module, attributes) when is_atom(module) and is_list(attributes) do
    placeholders =
      for index <- length(attributes)..1//-1 do
        :"$#{index}"
      end

    List.to_tuple([module | placeholders])
  end
end

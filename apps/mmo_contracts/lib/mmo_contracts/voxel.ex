defmodule MmoContracts.Voxel do
  @moduledoc "现行体素 wire 的值类型；坐标、版本和字节含义保持 G0 冻结定义，世界状态不在此库。"
  @type coord :: {integer(), integer(), integer()}
  @type skins :: {pos_integer(), tuple()}
  @type coarse :: %{
          level: non_neg_integer(),
          cell: coord(),
          material: non_neg_integer(),
          skins: skins()
        }
  @type entry ::
          %{
            seq: non_neg_integer(),
            coord: coord(),
            material: non_neg_integer(),
            coarse: [coarse()]
          }
          | %{seq: non_neg_integer(), payload: binary()}
  @type transaction :: %{seq: non_neg_integer(), entries: [entry()], coarse: [coarse()]}
end

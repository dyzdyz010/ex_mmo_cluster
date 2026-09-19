defmodule MmoContracts.Voxel.Skins do
  @moduledoc "六面表皮值的唯一规范形；不执行 LOD reduction。"

  @doc "六面都等于 material 的均匀表皮。"
  def uniform(material),
    do:
      {1,
       {{material, nil}, {material, nil}, {material, nil}, {material, nil}, {material, nil},
        {material, nil}}}

  @doc "收拢均匀贴图，得到唯一表皮值表示。"
  def canonical({ext, faces}) do
    faces =
      faces
      |> Tuple.to_list()
      |> Enum.map(&canonical_face/1)

    if Enum.all?(faces, fn {_, t} -> t == nil end),
      do: {1, List.to_tuple(faces)},
      else: {ext, List.to_tuple(faces)}
  end

  @doc "Canonical form of one face, shared by value and packed-record encoding."
  def canonical_face({id, nil}), do: {id, nil}

  def canonical_face({id, texels}) do
    if texels == :binary.copy(<<id>>, byte_size(texels)), do: {id, nil}, else: {id, texels}
  end

  @doc "六面是否都等于 material，决定稀疏记录省略。"
  def trivial?({1, faces}, material),
    do: Enum.all?(Tuple.to_list(faces), fn {id, _} -> id == material end)

  def trivial?(_, _), do: false
end


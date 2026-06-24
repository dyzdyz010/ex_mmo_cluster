defmodule SceneServer.Voxel.Field.ParticipantProjection do
  @moduledoc """
  Read-only field participant projection derived from voxel/object truth.

  This module is the boundary between chunk/refined/prefab truth and field
  kernels. Kernels consume projection facts such as electric face connectivity
  instead of querying prefab or object registries directly.

  The first slice implements electric projection only:

    * solid conductive macro cells expose all six faces as one connected body;
    * refined macro cells derive connectivity from conductive micro components;
    * adjacent macro cells only conduct when shared-face micro contacts overlap;
    * empty/non-conductive cells expose no electric faces.
  """

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  @fixed32_scale 65_536.0
  @min_channel_conductivity 1.0
  @faces [:x_neg, :x_pos, :y_neg, :y_pos, :z_neg, :z_pos]

  defstruct chunk_version: 0,
            material_catalog_version: 0,
            entries: %{}

  @type face :: :x_neg | :x_pos | :y_neg | :y_pos | :z_neg | :z_pos
  @type contact :: {non_neg_integer(), non_neg_integer()}
  @type electric_role :: :conductor | :source | :load
  # C4b 深半导体:`conduct_dir` 为 nil 表示普通双向导体;`{in_face, out_face}` 表示二极管——
  # 该 cell 只在 anode(in_face)→cathode(out_face)轴向参与导通(2 端器件,只 in/out 两面导电)。
  # 正偏/反偏由电路分析按"离电源跳数"判定(forward = in_face 侧更近电源),反偏的二极管被剪断。
  # `gate` 为 nil = 非门控;`%{base_face, threshold}` = 三极管——只 main(collector/emitter)两面
  # 导电,主通路通断由 base_face 邻接控制网络是否被 ≥threshold 电源驱动决定(电路分析门控剪断)。
  @type electric_component :: %{
          faces: MapSet.t(face()),
          face_contacts: %{optional(face()) => MapSet.t(contact())},
          roles: MapSet.t(electric_role()),
          conduct_dir: nil | {face(), face()},
          gate: nil | %{base_face: face(), threshold: float()}
        }
  @type entry :: %{
          electric: %{
            conductive_faces: MapSet.t(face()),
            face_connections: MapSet.t({face(), face()}),
            face_contacts: %{optional(face()) => MapSet.t(contact())},
            components: [electric_component()],
            conductivity: float(),
            dielectric_strength: float(),
            roles: MapSet.t(electric_role()),
            object_refs: [{non_neg_integer(), non_neg_integer()}]
          }
        }
  @type t :: %__MODULE__{
          chunk_version: non_neg_integer(),
          material_catalog_version: non_neg_integer(),
          entries: %{optional(non_neg_integer()) => entry()}
        }

  @doc "Builds a projection for the current chunk storage snapshot."
  @spec build(Storage.t()) :: t()
  def build(%Storage{} = storage) do
    storage = Storage.normalize!(storage)

    entries =
      storage.macro_headers
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {header, macro_index}, acc ->
        case build_entry(storage, header) do
          nil -> acc
          entry -> Map.put(acc, macro_index, entry)
        end
      end)

    %__MODULE__{
      chunk_version: storage.chunk_version,
      material_catalog_version: 0,
      entries: entries
    }
  end

  @doc "Returns true when a macro cell has any electric conductive face."
  @spec electric_conductive_cell?(t(), non_neg_integer()) :: boolean()
  def electric_conductive_cell?(%__MODULE__{} = projection, macro_index) do
    projection
    |> electric_faces(macro_index)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  @doc "Returns true when a macro face has at least one conductive micro contact."
  @spec electric_face_conductive?(t(), non_neg_integer(), face()) :: boolean()
  def electric_face_conductive?(%__MODULE__{} = projection, macro_index, face)
      when face in @faces do
    projection
    |> electric_faces(macro_index)
    |> MapSet.member?(face)
  end

  @doc """
  Returns conductive micro contacts exposed on a macro face.

  Contact coordinates are expressed in that face's two local axes:

    * `:x_neg` / `:x_pos` use `{y, z}`;
    * `:y_neg` / `:y_pos` use `{x, z}`;
    * `:z_neg` / `:z_pos` use `{x, y}`.
  """
  @spec electric_face_contacts(t(), non_neg_integer(), face()) :: MapSet.t(contact())
  def electric_face_contacts(%__MODULE__{} = projection, macro_index, face)
      when face in @faces do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{face_contacts: face_contacts}} ->
        Map.get(face_contacts, face, MapSet.new())

      _other ->
        MapSet.new()
    end
  end

  @doc """
  Returns exit-face contacts reachable from a given entry face and contact set.

  `:source` is a virtual entry that can inject into any conductive component in
  the macro cell. Physical entries are constrained to the conductive component
  that actually owns at least one of the incoming shared-face contacts.
  """
  @spec electric_reachable_face_contacts(
          t(),
          non_neg_integer(),
          face() | :source,
          MapSet.t(contact()),
          face()
        ) :: MapSet.t(contact())
  def electric_reachable_face_contacts(
        %__MODULE__{} = projection,
        macro_index,
        :source,
        _entry_contacts,
        exit_face
      )
      when exit_face in @faces do
    projection
    |> electric_components(macro_index)
    |> Enum.filter(fn component -> MapSet.member?(component.faces, exit_face) end)
    |> union_component_contacts(exit_face)
  end

  def electric_reachable_face_contacts(
        %__MODULE__{} = projection,
        macro_index,
        entry_face,
        entry_contacts,
        exit_face
      )
      when entry_face in @faces and exit_face in @faces do
    entry_contacts = ensure_contact_set(entry_contacts)

    projection
    |> electric_components(macro_index)
    |> Enum.filter(fn component ->
      MapSet.member?(component.faces, entry_face) and
        MapSet.member?(component.faces, exit_face) and
        contact_sets_overlap?(
          Map.get(component.face_contacts, entry_face, MapSet.new()),
          entry_contacts
        )
    end)
    |> union_component_contacts(exit_face)
  end

  @doc """
  Returns shared electric contacts that can transfer into a neighboring macro.

  The two macro cells may come from the same projection or from two different
  chunk projections. This keeps same-chunk and cross-chunk contact semantics on
  one API: the current cell must be able to reach the outgoing face from the
  actual entry contacts, and the neighbor must expose overlapping contacts on
  the opposite incoming face.
  """
  @spec electric_contact_transfer(
          t(),
          non_neg_integer(),
          face() | :source,
          MapSet.t(contact()),
          face(),
          t(),
          non_neg_integer(),
          face()
        ) :: MapSet.t(contact())
  def electric_contact_transfer(
        %__MODULE__{} = current_projection,
        current_macro_index,
        entry_face,
        entry_contacts,
        exit_face,
        %__MODULE__{} = neighbor_projection,
        neighbor_macro_index,
        neighbor_entry_face
      )
      when exit_face in @faces and neighbor_entry_face in @faces do
    current_projection
    |> electric_reachable_face_contacts(
      current_macro_index,
      entry_face,
      entry_contacts,
      exit_face
    )
    |> MapSet.intersection(
      electric_face_contacts(neighbor_projection, neighbor_macro_index, neighbor_entry_face)
    )
  end

  @doc """
  Returns true when electric current can move through a macro cell.

  `:source` is a virtual entry face used by source cells. It can exit through
  any conductive face without requiring an incoming physical face.
  """
  @spec electric_faces_connected?(t(), non_neg_integer(), face() | :source, face()) :: boolean()
  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, :source, exit_face)
      when exit_face in @faces do
    electric_face_conductive?(projection, macro_index, exit_face)
  end

  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, face, face)
      when face in @faces do
    electric_face_conductive?(projection, macro_index, face)
  end

  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, entry_face, exit_face)
      when entry_face in @faces and exit_face in @faces do
    projection
    |> electric_connections(macro_index)
    |> MapSet.member?(connection_key(entry_face, exit_face))
  end

  @doc "Reads an electric projection attribute in normalized float units."
  @spec electric_attribute(t(), non_neg_integer(), String.t(), float()) :: float()
  def electric_attribute(%__MODULE__{} = projection, macro_index, attr_name, fallback)
      when is_binary(attr_name) and is_number(fallback) do
    case Map.get(projection.entries, macro_index) do
      %{electric: electric} ->
        case attr_name do
          "electric_conductivity" -> electric.conductivity
          "dielectric_strength" -> electric.dielectric_strength
          _other -> fallback * 1.0
        end

      _other ->
        fallback * 1.0
    end
  end

  @doc "Returns object/part targets carried by the electric projection for a macro cell."
  @spec electric_object_refs(t(), non_neg_integer()) :: [
          %{owner_object_id: non_neg_integer(), owner_part_id: non_neg_integer()}
        ]
  def electric_object_refs(%__MODULE__{} = projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{object_refs: object_refs}} ->
        Enum.map(object_refs, fn {owner_object_id, owner_part_id} ->
          %{owner_object_id: owner_object_id, owner_part_id: owner_part_id}
        end)

      _other ->
        []
    end
  end

  @doc "Returns semantic electric roles exposed by a projected macro cell."
  @spec electric_roles(t(), non_neg_integer()) :: MapSet.t(electric_role())
  def electric_roles(%__MODULE__{} = projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{roles: roles}} -> roles
      _other -> MapSet.new()
    end
  end

  @doc "Returns true when a macro cell has a projected electric role."
  @spec electric_role?(t(), non_neg_integer(), electric_role()) :: boolean()
  def electric_role?(%__MODULE__{} = projection, macro_index, role)
      when role in [:conductor, :source, :load] do
    projection
    |> electric_roles(macro_index)
    |> MapSet.member?(role)
  end

  @doc "Returns conductive electric subcomponents for a projected macro cell."
  @spec electric_components(t(), non_neg_integer()) :: [electric_component()]
  def electric_components(%__MODULE__{} = projection, macro_index) do
    lookup_electric_components(projection, macro_index)
  end

  defp build_entry(storage, %MacroCellHeader{} = header) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        build_solid_entry(storage, header)

      header.mode == MacroCellHeader.cell_mode_refined() ->
        build_refined_entry(storage, header)

      true ->
        nil
    end
  end

  defp build_solid_entry(storage, %MacroCellHeader{} = header) do
    case Enum.at(storage.normal_blocks, header.payload_index) do
      %NormalBlockData{material_id: material_id, state_flags: state_flags} ->
        conductivity = material_float(material_id, "electric_conductivity", 0.0)
        dielectric_strength = material_float(material_id, "dielectric_strength", 3.0)

        cond do
          conductivity < @min_channel_conductivity ->
            nil

          # C4b:二极管——2 端器件,只 in/out 两面导电,带 conduct_dir 供电路分析判正/反偏。
          MaterialCatalog.diode_material?(material_id) ->
            build_diode_solid_entry(material_id, state_flags, conductivity, dielectric_strength)

          # C4b:三极管——只 main(collector/emitter)两面导电 + gate{base_face,threshold},
          # 主通路通断由 base 控制网络是否被 ≥threshold 电源驱动决定(电路分析门控)。
          MaterialCatalog.transistor_material?(material_id) ->
            build_transistor_solid_entry(
              material_id,
              state_flags,
              conductivity,
              dielectric_strength
            )

          true ->
            electric_entry(
              MapSet.new(@faces),
              all_face_connections(),
              all_face_contacts_by_face(),
              [
                %{
                  faces: MapSet.new(@faces),
                  face_contacts: all_face_contacts_by_face(),
                  roles: electric_roles_for_material(material_id),
                  conduct_dir: nil,
                  gate: nil
                }
              ],
              conductivity,
              dielectric_strength,
              electric_roles_for_material(material_id),
              []
            )
        end

      _other ->
        nil
    end
  end

  # C4b 二极管 solid 投影:每格 anode→cathode 朝向来自 state_flags bits[0..2](0=用材料
  # conduction_axis 默认轴),只暴露 in/out 两面导电 + conduct_dir 标记。正偏/反偏不在此判定
  # (投影无电源上下文),交 CircuitComponentAnalysis 按离电源跳数定向 + 反偏剪断。
  defp build_diode_solid_entry(material_id, state_flags, conductivity, dielectric_strength) do
    {in_face, out_face} = diode_faces(material_id, state_flags)
    faces = MapSet.new([in_face, out_face])
    full_contacts = all_contacts()

    face_contacts =
      Map.new(@faces, fn face ->
        if face == in_face or face == out_face do
          {face, full_contacts}
        else
          {face, MapSet.new()}
        end
      end)

    roles = electric_roles_for_material(material_id)

    component = %{
      faces: faces,
      face_contacts: face_contacts,
      roles: roles,
      conduct_dir: {in_face, out_face},
      gate: nil
    }

    electric_entry(
      faces,
      add_face_connections(faces, MapSet.new()),
      face_contacts,
      [component],
      conductivity,
      dielectric_strength,
      roles,
      []
    )
  end

  # C4b 三极管 solid 投影:main(collector/emitter)轴来自 state_flags bits[0..2](0=用材料
  # conduction_axis 默认轴,无则 +x),base 面来自 bits[6..8](0=取首个非主轴面)。只 main 两面
  # 导电(base 是传感输入、不入导电图)+ gate{base_face,threshold},通断交电路分析门控。
  defp build_transistor_solid_entry(material_id, state_flags, conductivity, dielectric_strength) do
    {main_a, main_b} = transistor_main_faces(material_id, state_flags)
    base_face = transistor_base_face(state_flags, main_a, main_b)
    threshold = material_float(material_id, "base_threshold", 0.0)
    faces = MapSet.new([main_a, main_b])
    full_contacts = all_contacts()

    face_contacts =
      Map.new(@faces, fn face ->
        if face == main_a or face == main_b do
          {face, full_contacts}
        else
          {face, MapSet.new()}
        end
      end)

    roles = electric_roles_for_material(material_id)

    component = %{
      faces: faces,
      face_contacts: face_contacts,
      roles: roles,
      conduct_dir: nil,
      gate: %{base_face: base_face, threshold: threshold}
    }

    electric_entry(
      faces,
      add_face_connections(faces, MapSet.new()),
      face_contacts,
      [component],
      conductivity,
      dielectric_strength,
      roles,
      []
    )
  end

  # 三极管 main 轴:同二极管轴码(方向无关,取 2 面)。
  defp transistor_main_faces(material_id, state_flags) do
    code =
      case band(state_flags, 0b111) do
        0 -> MaterialCatalog.default_attribute_value(material_id, "conduction_axis", 0)
        per_cell -> per_cell
      end

    case code do
      c when c in 1..6 -> diode_code_faces(c)
      _other -> {:x_neg, :x_pos}
    end
  end

  # base 面:state_flags bits[6..8] 面序号(1..6=x_neg..z_pos);0 取首个非主轴面。
  defp transistor_base_face(state_flags, main_a, main_b) do
    case band(bsr(state_flags, 6), 0b111) do
      0 -> Enum.find(@faces, fn face -> face != main_a and face != main_b end)
      ordinal -> face_from_ordinal(ordinal)
    end
  end

  defp face_from_ordinal(1), do: :x_neg
  defp face_from_ordinal(2), do: :x_pos
  defp face_from_ordinal(3), do: :y_neg
  defp face_from_ordinal(4), do: :y_pos
  defp face_from_ordinal(5), do: :z_neg
  defp face_from_ordinal(6), do: :z_pos
  defp face_from_ordinal(_other), do: :z_pos

  # 二极管导通方向码 → {in_face(anode), out_face(cathode)}。码 1..6 = +x/-x/+y/-y/+z/-z
  # (current 流向 = anode→cathode)。state_flags bits[0..2] 优先;为 0 用材料 conduction_axis
  # 默认(raw 枚举,非定点——直接取 default_attribute_value 不除 scale)。
  defp diode_faces(material_id, state_flags) do
    code =
      case band(state_flags, 0b111) do
        0 -> MaterialCatalog.default_attribute_value(material_id, "conduction_axis", 0)
        per_cell -> per_cell
      end

    diode_code_faces(code)
  end

  defp diode_code_faces(1), do: {:x_neg, :x_pos}
  defp diode_code_faces(2), do: {:x_pos, :x_neg}
  defp diode_code_faces(3), do: {:y_neg, :y_pos}
  defp diode_code_faces(4), do: {:y_pos, :y_neg}
  defp diode_code_faces(5), do: {:z_neg, :z_pos}
  defp diode_code_faces(6), do: {:z_pos, :z_neg}
  # 越界/0 回退 +x(惰性安全:仍是合法 2 端二极管,不至于变诡异多面体)。
  defp diode_code_faces(_other), do: {:x_neg, :x_pos}

  defp all_contacts do
    MapSet.new(for first_axis <- 0..7, second_axis <- 0..7, do: {first_axis, second_axis})
  end

  defp build_refined_entry(storage, %MacroCellHeader{} = header) do
    case Enum.at(storage.refined_cells, header.payload_index) do
      %RefinedCellData{} = cell ->
        conductive_slots = conductive_slots(cell.layers)

        components =
          conductive_slots
          |> connected_components()
          |> Enum.map(&electric_component(&1, cell.layers))

        conductive_faces = components |> Enum.map(& &1.faces) |> union_face_sets()

        face_connections =
          components |> Enum.map(& &1.faces) |> Enum.reduce(MapSet.new(), &add_face_connections/2)

        face_contacts = merge_component_contacts(components)

        if MapSet.size(conductive_faces) > 0 do
          electric_entry(
            conductive_faces,
            face_connections,
            face_contacts,
            components,
            refined_conductivity(cell.layers),
            refined_dielectric_strength(cell.layers),
            components |> Enum.map(& &1.roles) |> Enum.reduce(MapSet.new(), &MapSet.union/2),
            refined_object_refs(cell.layers)
          )
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp electric_entry(
         faces,
         connections,
         face_contacts,
         components,
         conductivity,
         dielectric_strength,
         roles,
         object_refs
       ) do
    %{
      electric: %{
        conductive_faces: faces,
        face_connections: connections,
        face_contacts: face_contacts,
        components: components,
        conductivity: conductivity,
        dielectric_strength: dielectric_strength,
        roles: roles,
        object_refs: object_refs
      }
    }
  end

  defp electric_faces(projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{conductive_faces: faces}} -> faces
      _other -> MapSet.new()
    end
  end

  defp electric_connections(projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{face_connections: connections}} -> connections
      _other -> MapSet.new()
    end
  end

  defp lookup_electric_components(projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{components: components}} -> components
      _other -> []
    end
  end

  defp conductive_slots(layers) do
    layers
    |> Enum.filter(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "electric_conductivity", 0.0) >= @min_channel_conductivity
    end)
    |> Enum.flat_map(&layer_slots/1)
    |> MapSet.new()
  end

  defp layer_slots(%MicroLayer{mask_words: mask_words}) do
    mask_words
    |> Enum.with_index()
    |> Enum.flat_map(fn {word, word_index} ->
      if word == 0 do
        []
      else
        for bit <- 0..63, band(word, bsl(1, bit)) != 0 do
          word_index * 64 + bit
        end
      end
    end)
  end

  defp connected_components(slots) do
    slots
    |> MapSet.to_list()
    |> do_connected_components(slots, [])
  end

  defp do_connected_components([], _remaining, acc), do: acc

  defp do_connected_components([slot | rest], remaining, acc) do
    if MapSet.member?(remaining, slot) do
      {component, remaining} = flood_component([slot], remaining, MapSet.new())
      rest = Enum.filter(rest, &MapSet.member?(remaining, &1))
      do_connected_components(rest, remaining, [component | acc])
    else
      do_connected_components(rest, remaining, acc)
    end
  end

  defp flood_component([], remaining, component), do: {component, remaining}

  defp flood_component([slot | queue], remaining, component) do
    cond do
      not MapSet.member?(remaining, slot) ->
        flood_component(queue, remaining, component)

      true ->
        remaining = MapSet.delete(remaining, slot)
        component = MapSet.put(component, slot)

        neighbors =
          slot
          |> neighboring_slots()
          |> Enum.filter(&MapSet.member?(remaining, &1))

        flood_component(queue ++ neighbors, remaining, component)
    end
  end

  defp neighboring_slots(slot) do
    {x, y, z} = Types.micro_coord!(slot)

    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
    |> Enum.filter(fn {nx, ny, nz} ->
      nx in 0..7 and ny in 0..7 and nz in 0..7
    end)
    |> Enum.map(&Types.micro_index!/1)
  end

  defp electric_component(component, layers) do
    face_contacts =
      Enum.reduce(component, empty_face_contacts(), fn slot, contacts ->
        {x, y, z} = Types.micro_coord!(slot)

        contacts
        |> maybe_put_face_contact(x == 0, :x_neg, {y, z})
        |> maybe_put_face_contact(x == 7, :x_pos, {y, z})
        |> maybe_put_face_contact(y == 0, :y_neg, {x, z})
        |> maybe_put_face_contact(y == 7, :y_pos, {x, z})
        |> maybe_put_face_contact(z == 0, :z_neg, {x, y})
        |> maybe_put_face_contact(z == 7, :z_pos, {x, y})
      end)

    %{
      faces: faces_from_contacts(face_contacts),
      face_contacts: face_contacts,
      roles: component_roles(component, layers),
      # C4b:refined 子分量暂不支持二极管/三极管(走 solid-block 路径),恒双向、无门控。
      conduct_dir: nil,
      gate: nil
    }
  end

  defp maybe_put_face_contact(face_contacts, true, face, contact) do
    Map.update!(face_contacts, face, &MapSet.put(&1, contact))
  end

  defp maybe_put_face_contact(face_contacts, false, _face, _contact), do: face_contacts

  defp faces_from_contacts(face_contacts) do
    Enum.reduce(face_contacts, MapSet.new(), fn {face, contacts}, faces ->
      if MapSet.size(contacts) > 0 do
        MapSet.put(faces, face)
      else
        faces
      end
    end)
  end

  defp union_face_sets(face_sets) do
    Enum.reduce(face_sets, MapSet.new(), &MapSet.union/2)
  end

  defp empty_face_contacts do
    Map.new(@faces, &{&1, MapSet.new()})
  end

  defp all_face_contacts_by_face do
    contacts =
      MapSet.new(
        for first_axis <- 0..7,
            second_axis <- 0..7,
            do: {first_axis, second_axis}
      )

    Map.new(@faces, &{&1, contacts})
  end

  defp merge_component_contacts(components) do
    Enum.reduce(components, empty_face_contacts(), fn component, acc ->
      Enum.reduce(@faces, acc, fn face, inner_acc ->
        Map.update!(
          inner_acc,
          face,
          &MapSet.union(&1, Map.get(component.face_contacts, face, MapSet.new()))
        )
      end)
    end)
  end

  defp union_component_contacts(components, face) do
    Enum.reduce(components, MapSet.new(), fn component, acc ->
      MapSet.union(acc, Map.get(component.face_contacts, face, MapSet.new()))
    end)
  end

  defp ensure_contact_set(%MapSet{} = contacts), do: contacts
  defp ensure_contact_set(contacts) when is_list(contacts), do: MapSet.new(contacts)
  defp ensure_contact_set(_contacts), do: MapSet.new()

  defp contact_sets_overlap?(contacts_a, contacts_b) do
    contacts_a
    |> MapSet.intersection(contacts_b)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp add_face_connections(faces, acc) do
    face_list = MapSet.to_list(faces)

    Enum.reduce(face_list, acc, fn face_a, outer_acc ->
      Enum.reduce(face_list, outer_acc, fn face_b, inner_acc ->
        if face_a == face_b do
          inner_acc
        else
          MapSet.put(inner_acc, connection_key(face_a, face_b))
        end
      end)
    end)
  end

  defp all_face_connections do
    add_face_connections(MapSet.new(@faces), MapSet.new())
  end

  defp connection_key(face_a, face_b) do
    [face_a, face_b]
    |> Enum.sort_by(&face_rank/1)
    |> List.to_tuple()
  end

  defp face_rank(:x_neg), do: 0
  defp face_rank(:x_pos), do: 1
  defp face_rank(:y_neg), do: 2
  defp face_rank(:y_pos), do: 3
  defp face_rank(:z_neg), do: 4
  defp face_rank(:z_pos), do: 5

  defp refined_conductivity(layers) do
    layers
    |> Enum.map(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "electric_conductivity", 0.0)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp refined_dielectric_strength(layers) do
    layers
    |> Enum.map(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "dielectric_strength", 3.0)
    end)
    |> Enum.min(fn -> 3.0 end)
  end

  defp refined_object_refs(layers) do
    layers
    |> Enum.reject(&(&1.owner_object_id == 0))
    |> Enum.map(&{&1.owner_object_id, &1.owner_part_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp component_roles(component, layers) do
    layers
    |> Enum.filter(&layer_intersects_component?(&1, component))
    |> Enum.map(fn %MicroLayer{material_id: material_id} ->
      electric_roles_for_material(material_id)
    end)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp layer_intersects_component?(%MicroLayer{} = layer, component) do
    layer
    |> layer_slots()
    |> MapSet.new()
    |> MapSet.intersection(component)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp electric_roles_for_material(material_id) do
    conductivity = material_float(material_id, "electric_conductivity", 0.0)

    []
    |> maybe_add_role(conductivity >= @min_channel_conductivity, :conductor)
    |> maybe_add_role(MaterialCatalog.power_source_material?(material_id), :source)
    |> maybe_add_role(MaterialCatalog.electric_load_material?(material_id), :load)
    |> MapSet.new()
  end

  defp maybe_add_role(roles, true, role), do: [role | roles]
  defp maybe_add_role(roles, false, _role), do: roles

  defp material_float(material_id, attr_name, fallback) do
    material_id
    |> MaterialCatalog.default_attribute_value(attr_name, round(fallback * @fixed32_scale))
    |> Kernel./(@fixed32_scale)
  end
end

alias MmoContracts.Voxel.Payload
output = List.first(System.argv()) || "../Voxim/Docs/R7/fixtures"
File.mkdir_p!(output)
root = %{definition_id: :binary.copy(<<42>>,32),anchor: {-1,8,129},orientation: 1,parent_id: {0,0},component_slot: 0}
child = %{root | parent_id: {9,0},component_slot: 17}
p = %Payload{cells: :binary.copy(<<0,0>>,66*66*66),refined: %{4430 => %{7 => {11,{10,0}}}},instances: %{{9,0} => root,{10,0} => child}}
File.write!(Path.join(output,"server-a4-vxr7-fixture.vxr"),Payload.encode(p,%{},10,123))
File.write!(Path.join(output,"server-a4-replace-intent.bin"),<<0x7C,1::64,2::32,3::64,10::64,0::32,root.definition_id::binary>>)

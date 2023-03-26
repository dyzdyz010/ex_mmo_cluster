pub mod octree_node;
pub mod types;
pub mod octree_item;
pub mod bounding_box;

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

rustler::init!("Elixir.SceneServer.Native.Octree", [add]);

//! Scene 独占在线 world 的 BEAM 边界；完整批次先解码，DirtyCpu 内一次安装/刷新。
use std::sync::Mutex;
use rustler::{Atom, Binary, Encoder, Env, Error, NifResult, ResourceArc, Term};
use voxim_movement::{movement::{Input, Profile, State}, online::{self, ChunkCoord, Vec3, World}};

mod atoms { rustler::atoms! { ok, not_found, set, remove } }
struct WorldResource(Mutex<World>);
#[rustler::resource_impl]
impl rustler::Resource for WorldResource {}
type Triple = (f64,f64,f64);
type StateTuple = (Triple,Triple,u32);

fn finite(x:f64)->NifResult<f64> { if x.is_finite() {Ok(x)} else {Err(Error::BadArg)} }
fn vector(t:Triple)->NifResult<Vec3> { Ok(Vec3{x:finite(t.0)?,y:finite(t.1)?,z:finite(t.2)?}) }
fn bit(x:u32)->NifResult<u32> { if x<=1 {Ok(x)} else {Err(Error::BadArg)} }
fn state(t:StateTuple)->NifResult<State> {
    let p=vector(t.0)?; let v=vector(t.1)?;
    Ok(State{position:[p.x,p.y,p.z],velocity:[v.x,v.y,v.z],grounded:bit(t.2)?})
}
fn tuple(s:State)->StateTuple { ((s.position[0],s.position[1],s.position[2]),(s.velocity[0],s.velocity[1],s.velocity[2]),s.grounded) }
fn profile(term:Term)->NifResult<Profile> {
    let fields=rustler::types::tuple::get_tuple(term)?;
    if fields.len()!=15 {return Err(Error::BadArg);}
    let values=fields.into_iter().map(|t|finite(t.decode()?)).collect::<NifResult<Vec<f64>>>()?;
    Ok(Profile{radius:values[0],half_height:values[1],speed:values[2],acceleration:values[3],braking:values[4],
        air_braking:values[5],friction:values[6],braking_friction_factor:values[7],air_control:values[8],
        gravity:values[9],jump_speed:values[10],step_height:values[11],snap_distance:values[12],skin:values[13],slope_radians:values[14]})
}
fn coord(term:Term)->NifResult<ChunkCoord> { let (x,y,z)=term.decode::<(i32,i32,i32)>()?; Ok(ChunkCoord{x,y,z}) }
enum Operation<'a> {
    Set(ChunkCoord,usize,f64,Vec3,Binary<'a>),
    Remove(ChunkCoord),
}
fn operation(term:Term<'_>)->NifResult<Operation<'_>> {
    let fields=rustler::types::tuple::get_tuple(term)?;
    match fields.as_slice() {
        [tag,c] if tag.decode::<Atom>()?==atoms::remove() => Ok(Operation::Remove(coord(*c)?)),
        [tag,c,n,scale,origin,cells] if tag.decode::<Atom>()?==atoms::set() => {
            let n=n.decode::<u32>()? as usize;
            let cells=cells.decode::<Binary>()?;
            if n.checked_pow(3)!=Some(cells.len()) {return Err(Error::BadArg);}
            Ok(Operation::Set(coord(*c)?,n,finite(scale.decode()?)?,vector(origin.decode()?)?,cells))
        },
        _=>Err(Error::BadArg),
    }
}

#[rustler::nif]
fn new_world()->ResourceArc<WorldResource> { ResourceArc::new(WorldResource(Mutex::new(World::new()))) }

#[rustler::nif(schedule = "DirtyCpu")]
fn set_chunks(resource:ResourceArc<WorldResource>, operations:Vec<Term>)->NifResult<Atom> {
    let operations=operations.into_iter().map(operation).collect::<NifResult<Vec<_>>>()?;
    let mut previous=None;
    for operation in &operations {
        let c=match operation { Operation::Set(c,..)|Operation::Remove(c)=>*c };
        if previous.is_some_and(|p|p>=c) {return Err(Error::BadArg);}
        previous=Some(c);
    }
    let mut world=resource.0.lock().unwrap();
    for operation in operations {
        match operation {
            Operation::Set(c,n,scale,origin,cells)=>world.set_chunk(c,cells.as_slice(),n,scale,origin),
            Operation::Remove(c)=>world.remove_chunk(c),
        }
    }
    world.refresh();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn step_characters(resource:ResourceArc<WorldResource>, p:Term, characters:Vec<(u64,StateTuple,(f64,f64,u32))>)->NifResult<Vec<(u64,StateTuple)>> {
    let p=profile(p)?;
    let mut previous=None;
    let characters=characters.into_iter().map(|(id,s,(x,z,jump))| {
        if previous.is_some_and(|p|p>=id) {return Err(Error::BadArg);}
        previous=Some(id);
        Ok((id,state(s)?,Input{x:finite(x)?,z:finite(z)?,jump:bit(jump)?}))
    }).collect::<NifResult<Vec<_>>>()?;
    let world=resource.0.lock().unwrap();
    Ok(characters.into_iter().map(|(id,s,i)|(id,tuple(world.step(&p,s,i)))).collect())
}

#[rustler::nif]
fn query_bounds(p:Term,s:StateTuple)->NifResult<(Triple,Triple)> {
    let b=online::query_bounds(&profile(p)?,state(s)?);
    Ok(((b.min.x,b.min.y,b.min.z),(b.max.x,b.max.y,b.max.z)))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn find_spawn<'a>(env:Env<'a>,resource:ResourceArc<WorldResource>,p:Term,probe:Triple,min_center_y:f64)->NifResult<Term<'a>> {
    let p=profile(p)?; let probe=vector(probe)?; let min_center_y=finite(min_center_y)?;
    let found=resource.0.lock().unwrap().find_spawn(&p,probe,min_center_y);
    Ok(if found.found==1 {(atoms::ok(),tuple(found.state)).encode(env)} else {atoms::not_found().encode(env)})
}

rustler::init!("Elixir.SceneServer.Native.VoximMovement");

use rustler::NifStruct;


#[derive(NifStruct, Clone)]
#[module = "DevAttrs"]
pub struct DevAttrs {
    // Memory - 记忆力
    pub mmr: i32,

    // Comprehension - 理解力
    pub cph: i32,
    
    // Concentration - 专注力
    pub cct: i32,
    
    // Perception - 感知力
    pub pct: i32,
    
    // Resilience - 恢复力
    pub rsl: i32,
}

impl DevAttrs {
    pub fn new(mmr: i32, cph: i32, cct: i32, pct: i32, rsl: i32) -> DevAttrs {
        DevAttrs { mmr, cph, cct, pct, rsl }
    }
}
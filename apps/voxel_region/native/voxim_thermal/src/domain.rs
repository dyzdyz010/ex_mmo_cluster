//! 全局系统功能：常驻的热域拓扑——按槽位保存节点接触与辐射视线，按 World 给出的节点次序生成内核边与辐射项。
//!
//! 只是派生缓存：World 用整数槽位标识节点键，推送变化的节点与视线，每轮给出节点次序；
//! 生成的边与辐射项与 World 端 `ThermalGeometry.contacts/1`、`ThermalRadiation.terms/4` 同序同值。

/// 一条接触：伙伴槽位、导热系数、是否由本端发出（本节点键 < 伙伴键，每对只发一次）。
pub type Contact = (u32, f64, bool);

/// 一条视线：`None` 为对天空，`Some(伙伴槽位)` 为互见面半对；面积在后。已按 World 的视线次序排好。
pub type Sight = (Option<u32>, f64);

#[derive(Default)]
pub struct Domain {
    contacts: Vec<Option<Vec<Contact>>>,
    sights: Vec<Vec<Sight>>,
    // 槽位 => 次序下标 + 1；0 表示不在本轮节点集内。
    position: Vec<usize>,
    /// 本轮节点次序（槽位），内核下标即其序号。
    pub order: Vec<u32>,
    pub edges: Vec<(usize, usize, f64)>,
    pub pairs: Vec<(usize, usize, f64)>,
    pub sky: Vec<(usize, f64)>,
    pub nodes: usize,
}

impl Domain {
    fn grow(&mut self, slot: u32) {
        let need = slot as usize + 1;
        if self.contacts.len() < need {
            self.contacts.resize(need, None);
            self.sights.resize(need, Vec::new());
            self.position.resize(need, 0);
        }
    }

    /// 写入（或替换）节点的接触；移除的槽位不再出现在任何边里。
    pub fn put(&mut self, nodes: Vec<(u32, Vec<Contact>)>, removed: Vec<u32>) {
        for (slot, contacts) in nodes {
            self.grow(slot);
            self.contacts[slot as usize] = Some(contacts);
        }
        for slot in removed {
            if let Some(entry) = self.contacts.get_mut(slot as usize) {
                *entry = None;
            }
        }
    }

    /// 清空全部视线（视线缓存整体失效后重推）。
    pub fn clear_sights(&mut self) {
        self.sights.iter_mut().for_each(Vec::clear);
    }

    /// 替换节点的视线；空列表即无视线。
    pub fn put_sights(&mut self, sights: Vec<(u32, Vec<Sight>)>) {
        for (slot, rows) in sights {
            self.grow(slot);
            self.sights[slot as usize] = rows;
        }
    }

    /// 按节点次序（`order`，决定内核下标）重建内核边与辐射项。边：按 `emission` 的节点次序逐节点、逐接触，
    /// 本端发出且伙伴在节点集内（World 端两种遍历次序可能不同，由 World 分别给出）；
    /// 辐射：按下标逐节点、逐视线，对天空 `ε·A`，伙伴在节点集内的半对 `ε/(2−ε)·A/2`，其余按域边界绝热。
    pub fn index(&mut self, order: &[u32], emission: &[u32], emissivity: f64) {
        self.position.iter_mut().for_each(|p| *p = 0);
        for (i, &slot) in order.iter().enumerate() {
            self.grow(slot);
            self.position[slot as usize] = i + 1;
        }
        let grey = emissivity / (2.0 - emissivity);
        let (mut edges, mut pairs, mut sky) = (Vec::new(), Vec::new(), Vec::new());
        for &slot in emission {
            let Some(i) = self.at(slot) else { continue };
            for &(other, g, emits) in self.contacts[slot as usize].as_deref().unwrap_or(&[]) {
                if emits {
                    if let Some(j) = self.at(other) {
                        edges.push((i, j, g));
                    }
                }
            }
        }
        for (i, &slot) in order.iter().enumerate() {
            for &(hit, area) in &self.sights[slot as usize] {
                match hit {
                    None => sky.push((i, emissivity * area)),
                    Some(other) => {
                        if let Some(j) = self.at(other) {
                            pairs.push((i, j, grey * area / 2.0));
                        }
                    }
                }
            }
        }
        (self.edges, self.pairs, self.sky, self.nodes, self.order) = (edges, pairs, sky, order.len(), order.to_vec());
    }

    /// 槽位在本轮节点次序中的下标。
    pub fn at(&self, slot: u32) -> Option<usize> {
        match self.position.get(slot as usize) {
            Some(&p) if p > 0 => Some(p - 1),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 只测试：期望按 ThermalGeometry.contacts/1 的规则手算——逐节点、逐接触，本端发出且伙伴在集内。
    #[test]
    fn edges_follow_node_order_and_skip_absent_partners() {
        let mut d = Domain::default();
        d.put(vec![(5, vec![(7, 2.0, true), (9, 1.0, true)]), (7, vec![(5, 2.0, false)])], vec![]);
        d.index(&[7, 5], &[7, 5], 0.0);
        assert_eq!(d.edges, vec![(1, 0, 2.0)]);
        d.put(vec![(9, vec![(5, 1.0, false)]), (4, vec![(9, 3.0, true)])], vec![]);
        d.index(&[9, 5, 7, 4], &[9, 5, 7, 4], 0.0);
        assert_eq!(d.edges, vec![(1, 2, 2.0), (1, 0, 1.0), (3, 0, 3.0)]);
        // 发边次序与下标次序不同：边按发边次序排列，下标仍按节点次序。
        d.index(&[9, 5, 7, 4], &[4, 7, 5, 9], 0.0);
        assert_eq!(d.edges, vec![(3, 0, 3.0), (1, 2, 2.0), (1, 0, 1.0)]);
        d.put(vec![], vec![7]);
        d.index(&[9, 5], &[9, 5], 0.0);
        assert_eq!(d.edges, vec![(1, 0, 1.0)]);
    }

    // 只测试：ε=0.9 时 grey = 0.9/1.1；半对 grey·A/2，对天空 ε·A；伙伴不在集内的视线不产生项。
    #[test]
    fn radiation_terms_use_grey_body_factors() {
        let mut d = Domain::default();
        d.put(vec![(1, vec![]), (2, vec![])], vec![]);
        d.put_sights(vec![(1, vec![(None, 0.25), (Some(2), 1.0), (Some(3), 1.0)])]);
        d.index(&[2, 1], &[2, 1], 0.9);
        assert_eq!(d.sky, vec![(1, 0.9 * 0.25)]);
        assert_eq!(d.pairs, vec![(1, 0, 0.9 / (2.0 - 0.9) * 1.0 / 2.0)]);
    }
}

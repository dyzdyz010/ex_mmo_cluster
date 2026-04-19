//! Shared client-side skill targeting preflight helpers.
//!
//! The wire protocol only returns a generic success/error bit for normal result
//! packets, so the client performs a lightweight local preflight for known demo
//! skills. This avoids sending casts that are guaranteed to fail and lets the
//! GUI / stdio / headless surfaces explain *why* a skill was blocked.

/// Normalized skill dispatch payload after client-side preflight.
#[derive(Debug, Clone, PartialEq)]
pub struct SkillDispatchPlan {
    /// Target actor cid when the cast should resolve against a specific actor.
    pub target_cid: Option<i64>,
    /// Target point when the cast is point-directed.
    pub target_position: Option<[f64; 3]>,
}

/// Structured reason for a cast the client can reject locally.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkillDispatchBlock {
    /// Machine-readable reason emitted to logs / stdio.
    pub reason: &'static str,
    /// Operator hint for recovering from the blocked cast.
    pub hint: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SkillTargetMode {
    Actor,
    Point,
    Unknown,
}

/// Prepares one client skill cast and blocks requests that are guaranteed to
/// fail given the currently visible target state.
pub fn prepare_skill_dispatch(
    skill_id: u16,
    selected_target_cid: Option<i64>,
    selected_target_point: Option<[f64; 3]>,
    visible_actor_count: usize,
) -> Result<SkillDispatchPlan, SkillDispatchBlock> {
    match skill_target_mode(skill_id) {
        SkillTargetMode::Actor => {
            if selected_target_cid.is_some() || visible_actor_count > 0 {
                Ok(SkillDispatchPlan {
                    target_cid: selected_target_cid,
                    target_position: None,
                })
            } else {
                Err(SkillDispatchBlock {
                    reason: "no_visible_target",
                    hint: "actor-targeted skills need a nearby target; use Tab in the GUI or `players` + `target <cid>` in stdio before casting",
                })
            }
        }
        SkillTargetMode::Point => {
            if selected_target_point.is_some() || visible_actor_count > 0 {
                Ok(SkillDispatchPlan {
                    target_cid: None,
                    target_position: selected_target_point,
                })
            } else {
                Err(SkillDispatchBlock {
                    reason: "no_target_point_or_visible_target",
                    hint: "point-targeted skills need either `target_point <x> <y> [z]` or a nearby actor for auto-targeting",
                })
            }
        }
        SkillTargetMode::Unknown => Ok(SkillDispatchPlan {
            target_cid: selected_target_cid,
            target_position: None,
        }),
    }
}

fn skill_target_mode(skill_id: u16) -> SkillTargetMode {
    match skill_id {
        1 | 2 | 4 | 101 => SkillTargetMode::Actor,
        3 => SkillTargetMode::Point,
        _ => SkillTargetMode::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::{SkillDispatchBlock, SkillDispatchPlan, prepare_skill_dispatch};

    #[test]
    fn actor_skill_blocks_when_no_target_is_visible() {
        assert_eq!(
            prepare_skill_dispatch(1, None, None, 0),
            Err(SkillDispatchBlock {
                reason: "no_visible_target",
                hint: "actor-targeted skills need a nearby target; use Tab in the GUI or `players` + `target <cid>` in stdio before casting",
            })
        );
    }

    #[test]
    fn actor_skill_allows_auto_cast_when_actor_is_visible() {
        assert_eq!(
            prepare_skill_dispatch(1, None, None, 1),
            Ok(SkillDispatchPlan {
                target_cid: None,
                target_position: None,
            })
        );
    }

    #[test]
    fn point_skill_accepts_selected_target_point() {
        assert_eq!(
            prepare_skill_dispatch(3, None, Some([1.0, 2.0, 3.0]), 0),
            Ok(SkillDispatchPlan {
                target_cid: None,
                target_position: Some([1.0, 2.0, 3.0]),
            })
        );
    }
}

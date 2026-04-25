//! Parsing for the comma-separated `--script` value passed to `--headless`.

use bevy::prelude::Vec2;

/// One unit of work the scripted headless runner can execute.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum HeadlessAction {
    Wait(u64),
    Move {
        direction: Vec2,
        label: String,
        duration_ms: u64,
    },
    Chat(String),
    Skill(u16),
    Jump,
    Snapshot,
}

pub(super) fn parse_script(script: &str) -> Result<Vec<HeadlessAction>, String> {
    script
        .split(',')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(parse_action)
        .collect()
}

fn parse_action(segment: &str) -> Result<HeadlessAction, String> {
    let parts = segment.splitn(3, ':').collect::<Vec<_>>();

    match parts.as_slice() {
        ["wait", duration] => parse_u64(duration).map(HeadlessAction::Wait),
        ["move", direction, duration] => Ok(HeadlessAction::Move {
            direction: parse_direction(direction)?,
            label: (*direction).to_string(),
            duration_ms: parse_u64(duration)?,
        }),
        ["chat", text] => Ok(HeadlessAction::Chat((*text).to_string())),
        ["skill", skill_id] => parse_u16(skill_id).map(HeadlessAction::Skill),
        ["jump"] => Ok(HeadlessAction::Jump),
        ["snapshot"] => Ok(HeadlessAction::Snapshot),
        _ => Err(format!("unsupported headless action segment: {segment}")),
    }
}

fn parse_direction(value: &str) -> Result<Vec2, String> {
    match value.to_ascii_lowercase().as_str() {
        "w" | "up" => Ok(Vec2::new(0.0, 1.0)),
        "s" | "down" => Ok(Vec2::new(0.0, -1.0)),
        "a" | "left" => Ok(Vec2::new(-1.0, 0.0)),
        "d" | "right" => Ok(Vec2::new(1.0, 0.0)),
        other => Err(format!("unsupported move direction: {other}")),
    }
}

fn parse_u64(value: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|error| format!("invalid integer {value:?}: {error}"))
}

fn parse_u16(value: &str) -> Result<u16, String> {
    value
        .parse::<u16>()
        .map_err(|error| format!("invalid skill id {value:?}: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_headless_actions() {
        assert_eq!(
            parse_script("wait:500,move:w:600,chat:hello,skill:1,snapshot").unwrap(),
            vec![
                HeadlessAction::Wait(500),
                HeadlessAction::Move {
                    direction: Vec2::new(0.0, 1.0),
                    label: "w".to_string(),
                    duration_ms: 600,
                },
                HeadlessAction::Chat("hello".to_string()),
                HeadlessAction::Skill(1),
                HeadlessAction::Snapshot,
            ]
        );
    }

    #[test]
    fn rejects_invalid_direction() {
        let error = parse_script("move:q:100").unwrap_err();
        assert!(error.contains("unsupported move direction"));
    }
}

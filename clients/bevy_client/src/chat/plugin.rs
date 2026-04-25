//! `ChatPlugin` — owns chat input mode, the visible draft buffer, and the
//! HUD components that render chat. Toggle is `Enter`; `Esc` cancels.

use bevy::input::keyboard::{Key, KeyboardInput};
use bevy::prelude::*;

use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::observe::ClientObserver;

/// Chat input state — modal flag and the in-progress draft string.
#[derive(Resource, Default)]
pub struct ChatState {
    pub enabled: bool,
    pub draft: String,
}

#[derive(Component)]
pub struct ChatLogText;

#[derive(Component)]
pub struct ChatInputText;

pub struct ChatPlugin;

impl Plugin for ChatPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<ChatState>().add_systems(
            Update,
            (toggle_chat_mode, collect_chat_text).run_if(in_state(AppState::Game)),
        );
    }
}

fn toggle_chat_mode(
    keyboard: Res<ButtonInput<KeyCode>>,
    bridge: Res<NetworkBridge>,
    observer: Res<ClientObserver>,
    mut chat_state: ResMut<ChatState>,
) {
    if !chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        chat_state.enabled = true;
        observer.emit("input", "chat_opened", &[]);
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Escape) {
        chat_state.enabled = false;
        chat_state.draft.clear();
        observer.emit("input", "chat_cancelled", &[]);
        return;
    }

    if chat_state.enabled && keyboard.just_pressed(KeyCode::Enter) {
        let message = chat_state.draft.trim().to_string();
        if !message.is_empty() {
            bridge.send(NetworkCommand::Chat(message));
            observer.emit(
                "input",
                "chat_submitted",
                &[("draft", chat_state.draft.clone())],
            );
        }
        chat_state.draft.clear();
        chat_state.enabled = false;
    }
}

fn collect_chat_text(
    mut keyboard_input_reader: MessageReader<KeyboardInput>,
    mut chat_state: ResMut<ChatState>,
) {
    if !chat_state.enabled {
        return;
    }

    for keyboard_input in keyboard_input_reader.read() {
        if !keyboard_input.state.is_pressed() {
            continue;
        }

        match (&keyboard_input.logical_key, &keyboard_input.text) {
            (Key::Backspace, _) => {
                chat_state.draft.pop();
            }
            (Key::Enter, _) => {}
            (_, Some(inserted_text)) if inserted_text.chars().all(is_printable_char) => {
                chat_state.draft.push_str(inserted_text);
            }
            _ => {}
        }
    }
}

fn is_printable_char(chr: char) -> bool {
    let is_in_private_use_area = ('\u{e000}'..='\u{f8ff}').contains(&chr)
        || ('\u{f0000}'..='\u{ffffd}').contains(&chr)
        || ('\u{100000}'..='\u{10fffd}').contains(&chr);

    !is_in_private_use_area && !chr.is_ascii_control()
}

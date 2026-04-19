//! egui-driven login screen that collects a username and exchanges it for session credentials.

use crate::{
    auth_client,
    config::{ClientConfig, SessionCredentials},
};
use bevy::prelude::*;
use bevy_egui::{EguiContexts, EguiPlugin, egui};
use std::{
    sync::{
        Mutex,
        mpsc::{self, Receiver, TryRecvError},
    },
    thread,
};

/// Top-level app state controlling whether the Login or Game systems are active.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq, States)]
pub enum AppState {
    #[default]
    Login,
    Game,
}

#[derive(Resource, Default)]
struct LoginUi {
    username_draft: String,
    error: Option<String>,
    in_flight: bool,
}

#[derive(Resource)]
struct PendingAuth(Mutex<Receiver<Result<SessionCredentials, String>>>);

/// Installs the Bevy plugin that renders the login panel and handles the HTTP round-trip.
pub struct LoginPlugin;

impl Plugin for LoginPlugin {
    fn build(&self, app: &mut App) {
        if !app.is_plugin_added::<EguiPlugin>() {
            app.add_plugins(EguiPlugin::default());
        }

        app.insert_resource(LoginUi::default()).add_systems(
            Update,
            (login_panel_system, poll_pending_auth_system).run_if(in_state(AppState::Login)),
        );
    }
}

fn login_panel_system(
    mut commands: Commands,
    mut contexts: EguiContexts,
    config: Res<ClientConfig>,
    mut ui_state: ResMut<LoginUi>,
    pending: Option<Res<PendingAuth>>,
) {
    let Ok(ctx) = contexts.ctx_mut() else {
        return;
    };

    let mut submit = false;
    egui::CentralPanel::default().show(ctx, |ui| {
        ui.vertical_centered(|ui| {
            ui.add_space(64.0);
            ui.heading("Hemifuture Login");
            ui.add_space(16.0);
            ui.label(format!("auth: {}", config.auth_addr));
            ui.label(format!("gate: {}", config.gate_addr));
            ui.add_space(16.0);

            ui.label("username:");
            let response = ui.add_enabled(
                !ui_state.in_flight,
                egui::TextEdit::singleline(&mut ui_state.username_draft).desired_width(240.0),
            );
            let submitted_with_enter = response.lost_focus()
                && ui.input(|input| input.key_pressed(egui::Key::Enter));

            ui.add_space(8.0);
            let enter_clicked = ui
                .add_enabled(!ui_state.in_flight, egui::Button::new("Enter"))
                .clicked();

            if (submitted_with_enter || enter_clicked)
                && !ui_state.in_flight
                && !ui_state.username_draft.trim().is_empty()
            {
                submit = true;
            }

            if ui_state.in_flight {
                ui.add_space(8.0);
                ui.label("contacting auth server...");
            }

            if let Some(error) = ui_state.error.as_deref() {
                ui.add_space(8.0);
                ui.colored_label(egui::Color32::LIGHT_RED, error);
            }
        });
    });

    if submit && pending.is_none() {
        let username = ui_state.username_draft.trim().to_string();
        let auth_addr = config.auth_addr.clone();
        ui_state.in_flight = true;
        ui_state.error = None;

        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let result = auth_client::auto_login(&auth_addr, &username);
            let _ = tx.send(result);
        });
        commands.insert_resource(PendingAuth(Mutex::new(rx)));
    }
}

fn poll_pending_auth_system(
    mut commands: Commands,
    mut ui_state: ResMut<LoginUi>,
    pending: Option<Res<PendingAuth>>,
    mut next_state: ResMut<NextState<AppState>>,
) {
    let Some(pending) = pending else {
        return;
    };

    let Ok(receiver) = pending.0.lock() else {
        return;
    };

    match receiver.try_recv() {
        Ok(Ok(creds)) => {
            drop(receiver);
            commands.insert_resource(creds);
            commands.remove_resource::<PendingAuth>();
            ui_state.in_flight = false;
            ui_state.error = None;
            next_state.set(AppState::Game);
        }
        Ok(Err(message)) => {
            drop(receiver);
            commands.remove_resource::<PendingAuth>();
            ui_state.in_flight = false;
            ui_state.error = Some(message);
        }
        Err(TryRecvError::Empty) => {}
        Err(TryRecvError::Disconnected) => {
            drop(receiver);
            commands.remove_resource::<PendingAuth>();
            ui_state.in_flight = false;
            ui_state.error = Some("auth worker thread exited without result".to_string());
        }
    }
}

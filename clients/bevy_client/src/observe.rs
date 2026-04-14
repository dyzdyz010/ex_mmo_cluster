//! Lightweight structured observe sink for the Bevy client.

use bevy::prelude::Resource;
use std::{
    fs::{OpenOptions, create_dir_all},
    io::{BufWriter, Write},
    path::Path,
    sync::mpsc::{self, Sender},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Default, Resource)]
/// File/stdout-backed structured event sink used by local automation and QA.
pub struct ClientObserver {
    sink: Option<Sender<String>>,
    stdout: bool,
}

impl ClientObserver {
    /// Creates a new observer that can write to a file and/or stdout.
    pub fn new(path: Option<String>, stdout: bool) -> Self {
        let sink = path.and_then(|path| {
            let path = Path::new(&path);
            if let Some(parent) = path.parent() {
                let _ = create_dir_all(parent);
            }

            let file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .ok()?;

            let (tx, rx) = mpsc::channel::<String>();
            thread::spawn(move || {
                let mut writer = BufWriter::new(file);
                while let Ok(line) = rx.recv() {
                    let _ = writer.write_all(line.as_bytes());
                    let _ = writer.flush();
                }
            });

            Some(tx)
        });

        Self { sink, stdout }
    }

    /// Returns whether any observe sink is enabled.
    pub fn enabled(&self) -> bool {
        self.stdout || self.sink.is_some()
    }

    /// Emits one structured observe line.
    pub fn emit(&self, source: &str, event: &str, fields: &[(&str, String)]) {
        if !self.enabled() {
            return;
        }

        let mut line = format!("ts={} source={source:?} event={event:?}", unix_millis());

        for (key, value) in fields {
            line.push(' ');
            line.push_str(key);
            line.push('=');
            line.push_str(&format!("{value:?}"));
        }

        line.push('\n');

        if self.stdout {
            print!("{line}");
        }

        if let Some(sink) = &self.sink {
            let _ = sink.send(line);
        }
    }
}

fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

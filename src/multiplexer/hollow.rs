//! Hollow terminal multiplexer backend.
//!
//! Hollow uses a Workspace → Tab → Pane hierarchy.
//! This backend maps workmux concepts as:
//!   - session / window  →  hollow workspace (named, persistent within the GUI process)
//!   - pane              →  hollow pane
//!
//! All communication goes through `hollow cli …`, which talks to the hollow
//! GUI process over the loopback IPC socket advertised in HOLLOW_COMMAND_ADDR.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use serde::Deserialize;

use super::types::*;
use super::util;
use super::Multiplexer;
use crate::cmd::Cmd;
use crate::config::SplitDirection;

// ── Wire types (hollow CLI JSON output) ──────────────────────────────────────

#[derive(Debug, Deserialize)]
struct HollowPane {
    id: u64,
    #[serde(default)]
    pid: u64,
    #[serde(default)]
    cwd: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    foreground_process: String,
    #[serde(default)]
    is_focused: bool,
}

#[derive(Debug, Deserialize)]
struct HollowTab {
    id: u64,
    #[serde(default)]
    panes: Vec<HollowPane>,
}

#[derive(Debug, Deserialize)]
struct HollowWorkspace {
    id: u64,
    index: u64,
    name: String,
    #[serde(default)]
    is_active: bool,
}

// ── Backend ───────────────────────────────────────────────────────────────────

pub struct HollowBackend;

impl HollowBackend {
    pub fn new() -> Self {
        Self
    }

    fn hollow_cmd(&self) -> Cmd<'static> {
        Cmd::new("hollow")
    }

    fn list_panes(&self) -> Result<Vec<HollowPane>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "panes"])
            .run_and_capture_stdout()
            .context("Failed to list hollow panes")?;
        serde_json::from_str(&out).context("Failed to parse hollow pane list")
    }

    fn list_workspaces(&self) -> Result<Vec<HollowWorkspace>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "workspaces"])
            .run_and_capture_stdout()
            .context("Failed to list hollow workspaces")?;
        serde_json::from_str(&out).context("Failed to parse hollow workspace list")
    }

    fn list_tabs(&self) -> Result<Vec<HollowTab>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "tabs"])
            .run_and_capture_stdout()
            .context("Failed to list hollow tabs")?;
        serde_json::from_str(&out).context("Failed to parse hollow tab list")
    }

    fn get_workspace_by_name(&self, name: &str) -> Result<Option<HollowWorkspace>> {
        Ok(self.list_workspaces()?.into_iter().find(|ws| ws.name == name))
    }

    /// Return the ID of the currently active pane by querying the CLI.
    fn query_current_pane_id(&self) -> Result<Option<String>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "current-pane"])
            .run_and_capture_stdout()
            .context("Failed to get hollow current-pane")?;
        if out.is_empty() || out == "null" {
            return Ok(None);
        }
        let pane: HollowPane =
            serde_json::from_str(&out).context("Failed to parse hollow current-pane")?;
        Ok(Some(pane.id.to_string()))
    }

    /// Select a workspace by name: find its index then call `workspace select`.
    fn select_workspace_by_name(&self, full_name: &str) -> Result<()> {
        let ws = self
            .get_workspace_by_name(full_name)?
            .ok_or_else(|| anyhow!("Hollow workspace '{}' not found", full_name))?;
        self.hollow_cmd()
            .args(&["cli", "workspace", "select", &ws.index.to_string()])
            .run()
            .context("Failed to select hollow workspace")?;
        Ok(())
    }

    fn pane_to_snapshot(&self, pane: &HollowPane) -> util::LivePaneSnapshot {
        util::LivePaneSnapshot {
            pane_id: pane.id.to_string(),
            pid: if pane.pid > 0 {
                Some(pane.pid as u32)
            } else {
                None
            },
            current_command: if pane.foreground_process.is_empty() {
                None
            } else {
                Some(pane.foreground_process.clone())
            },
            working_dir: PathBuf::from(&pane.cwd),
            title: pane.title.clone(),
            session: String::new(),
            window: String::new(),
        }
    }
}

// ── Trait implementation ──────────────────────────────────────────────────────

impl Multiplexer for HollowBackend {
    fn name(&self) -> &'static str {
        "hollow"
    }

    // === Server/Session ===

    fn is_running(&self) -> Result<bool> {
        self.hollow_cmd()
            .args(&["cli", "get", "revision"])
            .run_as_check()
    }

    fn current_pane_id(&self) -> Option<String> {
        std::env::var("HOLLOW_PANE_ID").ok()
    }

    fn active_pane_id(&self) -> Option<String> {
        self.list_panes()
            .ok()
            .and_then(|panes| panes.into_iter().find(|p| p.is_focused).map(|p| p.id.to_string()))
    }

    fn get_client_active_pane_path(&self) -> Result<PathBuf> {
        let pane_id = std::env::var("HOLLOW_PANE_ID")
            .ok()
            .ok_or_else(|| anyhow!("HOLLOW_PANE_ID is not set"))?;

        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "pane", "--id", &pane_id])
            .run_and_capture_stdout()
            .context("Failed to get hollow pane")?;

        if out.is_empty() || out == "null" {
            return Err(anyhow!("Hollow pane {} not found", pane_id));
        }
        let pane: HollowPane =
            serde_json::from_str(&out).context("Failed to parse hollow pane")?;

        let path = PathBuf::from(&pane.cwd);
        if path.as_os_str().is_empty() {
            return Err(anyhow!("Hollow returned an empty path for pane {}", pane_id));
        }
        Ok(path)
    }

    // === Window / Tab management  (window = workspace in hollow) ===

    fn create_window(&self, params: CreateWindowParams) -> Result<String> {
        let full_name = util::prefixed(params.prefix, params.name);
        let cwd_str = params.cwd.to_string_lossy();

        self.hollow_cmd()
            .args(&[
                "cli", "workspace", "new",
                "--name", &full_name,
                "--cwd", &cwd_str,
            ])
            .run()
            .context("Failed to create hollow workspace")?;

        // Explicitly select the new workspace so current-pane is reliable.
        self.select_workspace_by_name(&full_name)?;

        let pane_id = self
            .query_current_pane_id()?
            .ok_or_else(|| anyhow!("No active pane after creating workspace '{}'", full_name))?;

        Ok(pane_id)
    }

    fn create_session(&self, params: CreateSessionParams) -> Result<String> {
        // Hollow sessions and windows both map to hollow workspaces.
        let full_name = util::prefixed(params.prefix, params.name);
        let cwd_str = params.cwd.to_string_lossy();

        self.hollow_cmd()
            .args(&[
                "cli", "workspace", "new",
                "--name", &full_name,
                "--cwd", &cwd_str,
            ])
            .run()
            .context("Failed to create hollow workspace (session)")?;

        self.select_workspace_by_name(&full_name)?;

        let pane_id = self
            .query_current_pane_id()?
            .ok_or_else(|| anyhow!("No active pane after creating workspace '{}'", full_name))?;

        Ok(pane_id)
    }

    fn switch_to_session(&self, prefix: &str, name: &str) -> Result<()> {
        let full_name = util::prefixed(prefix, name);
        self.select_workspace_by_name(&full_name)
    }

    fn session_exists(&self, full_name: &str) -> Result<bool> {
        Ok(self.get_workspace_by_name(full_name)?.is_some())
    }

    fn kill_session(&self, full_name: &str) -> Result<()> {
        if let Some(ws) = self.get_workspace_by_name(full_name)? {
            self.hollow_cmd()
                .args(&["cli", "workspace", "close", "--id", &ws.id.to_string()])
                .run()
                .context("Failed to close hollow workspace")?;
        }
        Ok(())
    }

    fn kill_window(&self, full_name: &str) -> Result<()> {
        self.kill_session(full_name)
    }

    fn schedule_window_close(&self, full_name: &str, delay: Duration) -> Result<()> {
        let Some(ws) = self.get_workspace_by_name(full_name)? else {
            return Ok(());
        };
        let secs = delay.as_secs_f64();
        let script = format!(
            "sleep {secs:.3}; hollow cli workspace close --id {}",
            ws.id
        );
        util::run_detached_sh_c(&script)
    }

    fn schedule_session_close(&self, full_name: &str, delay: Duration) -> Result<()> {
        self.schedule_window_close(full_name, delay)
    }

    fn run_deferred_script(&self, script: &str) -> Result<()> {
        util::run_detached_sh_c(script)
    }

    fn shell_select_window_cmd(&self, full_name: &str) -> Result<String> {
        let ws = self
            .get_workspace_by_name(full_name)?
            .ok_or_else(|| anyhow!("Workspace '{}' not found", full_name))?;
        Ok(format!(
            "hollow cli workspace select {} >/dev/null 2>&1",
            ws.index
        ))
    }

    fn shell_kill_window_cmd(&self, full_name: &str) -> Result<String> {
        let ws = self
            .get_workspace_by_name(full_name)?
            .ok_or_else(|| anyhow!("Workspace '{}' not found", full_name))?;
        Ok(format!(
            "hollow cli workspace close --id {} >/dev/null 2>&1",
            ws.id
        ))
    }

    fn shell_switch_session_cmd(&self, full_name: &str) -> Result<String> {
        self.shell_select_window_cmd(full_name)
    }

    fn shell_kill_session_cmd(&self, full_name: &str) -> Result<String> {
        self.shell_kill_window_cmd(full_name)
    }

    fn select_window(&self, prefix: &str, name: &str) -> Result<()> {
        let full_name = util::prefixed(prefix, name);
        self.select_workspace_by_name(&full_name)
    }

    fn current_window_name(&self) -> Result<Option<String>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "current-workspace"])
            .run_and_capture_stdout()
            .ok();
        let Some(out) = out else {
            return Ok(None);
        };
        if out.is_empty() || out == "null" {
            return Ok(None);
        }
        let ws: HollowWorkspace =
            serde_json::from_str(&out).context("Failed to parse hollow current-workspace")?;
        Ok(Some(ws.name))
    }

    fn get_all_window_names(&self) -> Result<HashSet<String>> {
        let workspaces = self.list_workspaces()?;
        Ok(workspaces.into_iter().map(|ws| ws.name).collect())
    }

    fn get_all_session_names(&self) -> Result<HashSet<String>> {
        self.get_all_window_names()
    }

    fn wait_until_session_closed(&self, full_session_name: &str) -> Result<()> {
        loop {
            if !self.is_running()? {
                return Ok(());
            }
            if !self.session_exists(full_session_name)? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }

    // === Pane Management ===

    fn select_pane(&self, pane_id: &str) -> Result<()> {
        // Hollow has no direct "focus pane by ID" CLI verb. Zoom is the closest
        // approximation (it brings the pane into view and gives it focus).
        self.hollow_cmd()
            .args(&["cli", "pane", "zoom", "--id", pane_id])
            .run()
            .context("Failed to zoom/select hollow pane")?;
        Ok(())
    }

    fn switch_to_pane(&self, pane_id: &str, _window_hint: Option<&str>) -> Result<()> {
        self.select_pane(pane_id)
    }

    fn kill_pane(&self, pane_id: &str) -> Result<()> {
        self.hollow_cmd()
            .args(&["cli", "pane", "close", "--id", pane_id])
            .run()
            .context("Failed to close hollow pane")?;
        Ok(())
    }

    fn respawn_pane(&self, pane_id: &str, cwd: &Path, cmd: Option<&str>) -> Result<String> {
        // Hollow has no native respawn. Strategy:
        //   1. Find the tab that contains this pane.
        //   2. If the pane has siblings → close it, split from a sibling.
        //   3. If the pane is alone in its tab → create a new tab, close the old pane.
        let tabs = self.list_tabs()?;
        let pane_id_num: u64 = pane_id.parse().unwrap_or(0);
        let cwd_str = cwd.to_string_lossy();

        let containing_tab = tabs
            .iter()
            .find(|tab| tab.panes.iter().any(|p| p.id == pane_id_num));

        if let Some(tab) = containing_tab {
            let has_siblings = tab.panes.iter().any(|p| p.id != pane_id_num);

            if has_siblings {
                // Close target pane; a sibling becomes active.
                self.hollow_cmd()
                    .args(&["cli", "pane", "close", "--id", pane_id])
                    .run()
                    .context("Failed to close hollow pane for respawn")?;

                // Split the now-active sibling pane horizontally.
                let mut args: Vec<&str> = vec!["cli", "pane", "split", "horizontal", "--cwd", &cwd_str];
                let cmd_owned;
                if let Some(c) = cmd {
                    cmd_owned = c.to_string();
                    args.push("--cmd");
                    args.push(&cmd_owned);
                }
                self.hollow_cmd()
                    .args(&args)
                    .run()
                    .context("Failed to split hollow pane for respawn")?;

                return self
                    .query_current_pane_id()?
                    .ok_or_else(|| anyhow!("No active pane after respawn split"));
            }

            // Pane is alone in its tab: create a new tab, close the old one.
            let tab_id = tab.id.to_string();
            let mut args: Vec<&str> = vec!["cli", "tab", "new", "--cwd", &cwd_str];
            let cmd_owned;
            if let Some(c) = cmd {
                cmd_owned = c.to_string();
                args.push("--cmd");
                args.push(&cmd_owned);
            }
            self.hollow_cmd()
                .args(&args)
                .run()
                .context("Failed to create hollow tab for respawn")?;

            let new_pane_id = self
                .query_current_pane_id()?
                .ok_or_else(|| anyhow!("No active pane after creating tab for respawn"))?;

            // Close the old (now-empty-pane) tab.
            let _ = self
                .hollow_cmd()
                .args(&["cli", "tab", "close", "--id", &tab_id])
                .run();

            return Ok(new_pane_id);
        }

        // No matching tab found; fall back to creating a new tab.
        let mut args: Vec<&str> = vec!["cli", "tab", "new", "--cwd", &cwd_str];
        let cmd_owned;
        if let Some(c) = cmd {
            cmd_owned = c.to_string();
            args.push("--cmd");
            args.push(&cmd_owned);
        }
        self.hollow_cmd()
            .args(&args)
            .run()
            .context("Failed to create hollow tab for respawn (fallback)")?;

        self.query_current_pane_id()?
            .ok_or_else(|| anyhow!("No active pane after respawn fallback"))
    }

    fn capture_pane(&self, pane_id: &str, lines: u16) -> Option<String> {
        let raw = self
            .hollow_cmd()
            .args(&["cli", "get", "pane-text", "--id", pane_id])
            .run_and_capture_stdout()
            .ok()?;

        // The CLI returns a JSON-encoded string (with surrounding quotes).
        let text: String = serde_json::from_str(&raw).unwrap_or(raw);
        Some(util::tail_lines(&text, lines))
    }

    // === Text I/O ===

    fn send_text_fragment(&self, pane_id: &str, text: &str) -> Result<()> {
        self.hollow_cmd()
            .args(&["cli", "pane", "send-text", text, "--id", pane_id])
            .run()
            .context("Failed to send text to hollow pane")?;
        Ok(())
    }

    fn send_enter(&self, pane_id: &str) -> Result<()> {
        // send-keys decodes {Enter} to the Enter key sequence.
        self.hollow_cmd()
            .args(&["cli", "send-keys", "{Enter}", "--id", pane_id])
            .run()
            .context("Failed to send Enter to hollow pane")?;
        Ok(())
    }

    fn send_key(&self, pane_id: &str, key: &str) -> Result<()> {
        // send-text sends raw bytes; this matches WezTerm's --no-paste behavior.
        self.hollow_cmd()
            .args(&["cli", "pane", "send-text", key, "--id", pane_id])
            .run()
            .context("Failed to send key to hollow pane")?;
        Ok(())
    }

    fn paste_text(&self, pane_id: &str, content: &str) -> Result<()> {
        // Hollow has no separate bracketed-paste mode; raw send-text works fine.
        self.send_text_fragment(pane_id, content)
    }

    // === Status ===
    // Hollow doesn't expose a tab/pane status-icon API via the CLI.

    fn set_status(&self, _pane_id: &str, _icon: &str, _auto_clear_on_focus: bool) -> Result<()> {
        Ok(())
    }

    fn clear_status(&self, _pane_id: &str) -> Result<()> {
        Ok(())
    }

    fn ensure_status_format(&self, _pane_id: &str) -> Result<()> {
        Ok(())
    }

    // === Pane Setup ===

    fn split_pane(
        &self,
        _target_pane_id: &str,
        direction: &SplitDirection,
        cwd: &Path,
        _size: Option<u16>,
        percentage: Option<u8>,
        command: Option<&str>,
    ) -> Result<String> {
        let dir = match direction {
            SplitDirection::Horizontal => "horizontal",
            SplitDirection::Vertical => "vertical",
            SplitDirection::Stacked => {
                return Err(anyhow!(
                    "Stacked splits are not supported by the hollow backend"
                ));
            }
        };

        let cwd_str = cwd.to_string_lossy();
        let mut args: Vec<&str> = vec!["cli", "pane", "split", dir, "--cwd", &cwd_str];

        // hollow pane split operates on the ACTIVE pane (no --id support).
        // This works for sequential setup_panes calls where the most-recently
        // created pane is always active.

        let ratio_str;
        if let Some(pct) = percentage {
            ratio_str = format!("{:.2}", pct as f64 / 100.0);
            args.push("--ratio");
            args.push(&ratio_str);
        }

        let cmd_owned;
        if let Some(c) = command {
            cmd_owned = c.to_string();
            args.push("--cmd");
            args.push(&cmd_owned);
        }

        self.hollow_cmd()
            .args(&args)
            .run()
            .context("Failed to split hollow pane")?;

        self.query_current_pane_id()?
            .ok_or_else(|| anyhow!("No active pane after split"))
    }

    // === Multi-Session / Workspace ===

    fn current_session(&self) -> Option<String> {
        self.current_window_name().ok().flatten()
    }

    // === State Reconciliation ===

    fn instance_id(&self) -> String {
        std::env::var("HOLLOW_COMMAND_ADDR").unwrap_or_else(|_| "default".to_string())
    }

    fn resolve_instance_id(&self) -> Result<String> {
        if let Ok(addr) = std::env::var("HOLLOW_COMMAND_ADDR") {
            if !addr.trim().is_empty() {
                return Ok(addr);
            }
        }

        // Fall back to the IPC address file written by hollow on startup.
        #[cfg(target_os = "windows")]
        if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
            let addr_file = Path::new(&local_app_data)
                .join("hollow")
                .join("command-ipc-address");
            if let Ok(addr) = std::fs::read_to_string(&addr_file) {
                let addr = addr.trim().to_string();
                if !addr.is_empty() {
                    return Ok(addr);
                }
            }
        }

        Err(anyhow!(
            "HOLLOW_COMMAND_ADDR is not set. \
             Run workmux from within a hollow pane, or set HOLLOW_COMMAND_ADDR."
        ))
    }

    fn get_live_pane_info(&self, pane_id: &str) -> Result<Option<LivePaneInfo>> {
        let out = self
            .hollow_cmd()
            .args(&["cli", "get", "pane", "--id", pane_id])
            .run_and_capture_stdout();

        let out = match out {
            Err(_) => return Ok(None),
            Ok(s) => s,
        };

        if out.is_empty() || out == "null" {
            return Ok(None);
        }

        let pane: HollowPane =
            serde_json::from_str(&out).context("Failed to parse hollow pane")?;

        Ok(Some(self.pane_to_snapshot(&pane).into_pair().1))
    }

    fn get_all_live_pane_info(&self) -> Result<HashMap<String, LivePaneInfo>> {
        Ok(util::live_pane_map(
            self.list_panes()?.iter().map(|p| self.pane_to_snapshot(p)),
        ))
    }
}

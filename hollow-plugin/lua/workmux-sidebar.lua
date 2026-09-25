-- workmux-sidebar.lua
-- Hollow sidebar plugin showing workmux agent statuses, modelled on the tmux
-- sidebar (`workmux sidebar`).
--
-- Hollow itself is a native Windows app, but workmux only runs inside WSL, so
-- every bit of data this widget needs (agent state files, git diff stats)
-- lives on the Linux side. Rather than crossing the WSL/Windows boundary once
-- per file, each refresh shells out ONCE per concern through
-- `hollow.term.run_domain_process`, using `jq` to read and flatten
-- everything in that one call.
--
-- Each agent renders as a 2-3 line tile:
--
--   ⠹⠸ feature-auth                      12m
--      workmux            +412 -87 ±+12 -3
--      fix sidebar socket paths on macOS
--
--   line 1: spinner (working) or status icon, worktree name, time in state
--   line 2: project name, committed diff stats (dim) + uncommitted (bright)
--   line 3: pane title, when the agent has set one
--
-- Install: add this plugin's parent directory to your hollow init.lua:
--   hollow.plugins.setup({ plugins = { "/path/to/workmux/hollow-plugin" } })
--
-- Optional config (pass as opts to setup):
--   require("workmux-sidebar").setup({
--     width = 34, side = "left",
--     domain = "UbuntuWSL",               -- WSL domain to run in;
--                                          -- nil uses hollow's default domain
--     spinner = true, spinner_ms = 120,   -- animate working agents
--     git = true, git_refresh_secs = 10,  -- diff stats, per-worktree poll
--     untracked = true,                   -- count untracked lines as adds
--     show_title = true,                  -- third line with the pane title
--     stale_after = 3600,                 -- seconds before an agent dims out
--   })
--
-- Default keybindings (override with hollow.keymap.set):
--   <C-A-j>  jump to next agent
--   <C-A-k>  jump to previous agent
--   <C-A-w>  toggle sidebar
--   <C-A-r>  reload agents and force a git refresh
--
-- HTP channels (usable from shell via `hollow cli emit <channel> <json>`):
--   workmux:status   {"pane_id":"<id>","icon":"<icon>"}        -- set live icon
--                    {"pane_id":"<id>","clear":true}           -- clear live icon
--   workmux:sidebar  {"action":"toggle"|"show"|"hide"|"refresh"}

local hollow = _G.hollow
local ui     = hollow.ui

-- ── Config ────────────────────────────────────────────────────────────────────

local cfg = {
  width                  = 34,
  side                   = "left",
  domain                 = nil,  -- nil = hollow's configured default domain
  stale_after            = 3600, -- matches the tmux sidebar's stale threshold
  spinner                = true,
  spinner_ms             = 120,
  reload_secs            = 2,    -- re-list+parse agent state files
  git                    = true,
  git_refresh_secs       = 10,
  git_worktrees_per_tick = 1,    -- bound the git work done in one tick
  untracked              = true,
  untracked_byte_limit   = 1024 * 1024,
  show_title             = true,
}

-- ── Palette ───────────────────────────────────────────────────────────────────

local C = {
  header      = "#7a7a7a",
  dim         = "#4a4a4a",
  text        = "#aaaaaa",
  text_hi     = "#e8e8e8",
  working     = "#6cb6ff",
  waiting     = "#e07b54",
  done        = "#5fba7d",
  stale       = "#4a4a4a",
  added       = "#5fba7d",
  removed     = "#e06c75",
  added_dim   = "#41724f",
  removed_dim = "#7a4046",
  accent      = "#f5c842",
  project     = "#6f7a8c",
  title       = "#5a6472",
  cursor_bg   = "#1e2430",
}

-- Two-cell braille frames, the same animation the tmux sidebar uses for `working`.
local SPINNER_FRAMES = {
  "⠋⠙", "⠙⠹", "⠹⠸", "⠸⠼", "⠼⠴", "⠴⠦", "⠦⠧", "⠧⠇", "⠇⠏", "⠏⠋",
}

local STATUS_ICONS = { waiting = "◆ ", done = "✔ " }
local IDLE_ICON     = "· "
local STALE_ICON    = "◦ "
local DIFF_ICON      = "±"
local REBASE_ICON    = "⟲ "

-- ── Module state ──────────────────────────────────────────────────────────────

-- pane_id (string) → { icon, ts } from live HTP emits (supersedes disk data)
local live_cache     = {}
-- sorted list of agent tables
local agents         = {}
-- 1-based index of the "selected" agent (follows current workspace)
local cursor         = 1
-- sidebar widget handle
local sidebar_widget = nil
-- workdir → { stats = {...}, fetched_at }
local git_cache      = {}
local spinner_frame  = 1
local last_load      = 0
local ticking        = false

-- ── Small utilities ───────────────────────────────────────────────────────────

-- Display width in code points; wide glyphs count as one, which is close
-- enough for the short labels and counters rendered here.
local function dwidth(s)
  local n = 0
  for _ in tostring(s or ""):gmatch("[^\128-\191]") do n = n + 1 end
  return n
end

local function trunc(s, max)
  s = tostring(s or "")
  if max <= 0 then return "" end
  if dwidth(s) <= max then return s end
  local out, n = {}, 0
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    if n >= max - 1 then break end
    out[#out + 1] = ch
    n = n + 1
  end
  return table.concat(out) .. "…"
end

local function format_elapsed(ts)
  if not ts or ts == 0 then return "" end
  local diff = math.max(0, os.time() - math.floor(ts))
  if diff < 60 then
    return diff .. "s"
  elseif diff < 3600 then
    local m = math.floor(diff / 60)
    local s = diff % 60
    return s > 0 and (m .. "m" .. s .. "s") or (m .. "m")
  elseif diff < 86400 then
    local h = math.floor(diff / 3600)
    local m = math.floor((diff % 3600) / 60)
    return m > 0 and (h .. "h" .. m .. "m") or (h .. "h")
  else
    return math.floor(diff / 86400) .. "d"
  end
end

-- POSIX single-quote for interpolating a path into the bash script we hand
-- to run_domain_process (the script's other values all come from inside the
-- WSL shell itself, so this is the only place we need to escape anything).
local function quote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- ── Path derivation (pure string/path work, no I/O) ──────────────────────────

local function path_parts(p)
  local parts = {}
  for part in tostring(p or ""):gmatch("[^/]+") do parts[#parts + 1] = part end
  return parts
end

-- Mirrors workmux's own derivation (src/agent_display.rs):
--   <project>__worktrees/<name>  or  <project>/.worktrees/<name>
-- Returns the worktree name and whether this is the project's main checkout.
local function derive_worktree(path)
  local parts = path_parts(path)
  for i = #parts, 1, -1 do
    local comp = parts[i]
    if comp:sub(-11) == "__worktrees" and parts[i + 1] then return parts[i + 1], false end
    if comp == ".worktrees" and parts[i + 1] then return parts[i + 1], false end
  end
  return "main", true
end

local function derive_project(path)
  local parts = path_parts(path)
  for i = #parts, 1, -1 do
    local comp = parts[i]
    if comp:sub(-11) == "__worktrees" then return comp:sub(1, #comp - 11) end
    if comp == ".worktrees" and parts[i - 1] then return parts[i - 1] end
  end
  return parts[#parts] or ""
end

local function strip_wm(name)
  if not name or name == "" then return nil end
  return (name:gsub("^wm%-", ""))
end

-- primary = worktree (or project, on the main checkout), secondary = project
-- (or branch, on the main checkout) — the same pairing as the tmux sidebar.
local function resolve_labels(agent, stats)
  local worktree, is_main = derive_worktree(agent.workdir)
  local project = derive_project(agent.workdir)
  if is_main then
    local primary = (project ~= "" and project) or strip_wm(agent.window_name) or "?"
    return primary, (stats and stats.branch) or "main"
  end
  return worktree, project
end

-- ── WSL process runner ────────────────────────────────────────────────────────

-- Run a bash script inside the configured WSL domain in one shot. Returns
-- (true, stdout) unless the call itself failed to run at all (missing
-- domain, wsl.exe not found, etc). A script line that errors on one input
-- (e.g. jq hitting one corrupt agent file among many) still exits non-zero
-- overall, so the process "ok" flag is deliberately ignored here — callers
-- work off the shape of stdout, not the exit code.
local function run_bash(script)
  local ok, _ran, stdout = pcall(hollow.term.run_domain_process, { "bash", "-lc", script }, cfg.domain)
  if not ok then return false, "" end
  return true, tostring(stdout or "")
end

-- The last line looking like a JSON object, ignoring any shell/profile noise
-- a login shell might print ahead of it.
local function last_json_object(text)
  local found
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line:match("^%s*{") then found = line end
  end
  return found
end

-- ── Agent loading ─────────────────────────────────────────────────────────────

-- One jq call reads every agent state file and projects just the fields this
-- sidebar needs, printing one compact JSON object per file — so a single
-- corrupt/half-written file can't break the rest of the batch.
local AGENTS_SCRIPT = [[
dir="${XDG_STATE_HOME:-$HOME/.local/state}/workmux/agents"
jq -c '{
  pane_id: ((.pane_key.pane_id // .pane_id) | tostring),
  workdir: .workdir,
  status: .status,
  status_ts: .status_ts,
  activity_ts: .activity_ts,
  updated_ts: .updated_ts,
  pane_title: .pane_title,
  window_name: .window_name,
  session: (.session_name // .session),
  agent_kind: .agent_kind
}' -- "$dir"/hollow__*.json 2>/dev/null
]]

local function activity_ts(agent)
  return agent.live_ts or agent.activity_ts or agent.status_ts or agent.updated_ts or 0
end

local function is_stale(agent, now)
  local ts = activity_ts(agent)
  return ts > 0 and (now - ts) > cfg.stale_after
end

-- A successful listing is authoritative: an agent whose state file is gone
-- (pane closed, agent exited) must drop out here, not linger. A failed WSL
-- call never reaches this function at all (see load_agents), so there is no
-- need to merge with the previous list "just in case".
local function apply_agents(result)
  local result_list = {}

  for line in result:gmatch("[^\r\n]+") do
    if line:match("^%s*{") then
      local ok, data = pcall(hollow.json.decode, line)
      if ok and type(data) == "table" and data.pane_id and data.pane_id ~= "" then
        local live = live_cache[data.pane_id]
        data.live_icon = live and live.icon or nil
        data.live_ts   = live and live.ts or nil
        result_list[#result_list + 1] = data
      end
    end
  end

  -- most recently active first; pane_id breaks ties so the order stays stable
  table.sort(result_list, function(a, b)
    local ta, tb = activity_ts(a), activity_ts(b)
    if ta ~= tb then return ta > tb end
    return a.pane_id < b.pane_id
  end)

  agents = result_list
  cursor = math.max(1, math.min(cursor, math.max(1, #agents)))
end

local function load_agents()
  last_load = os.time()
  local ok, stdout = run_bash(AGENTS_SCRIPT)
  if not ok then return end
  apply_agents(stdout)
end

-- Sync cursor to the agent matching the given workspace name.
local function sync_cursor_to_workspace(ws_name)
  if not ws_name or ws_name == "" then return end
  for i, agent in ipairs(agents) do
    if agent.window_name == ws_name or agent.session == ws_name then
      cursor = i
      return
    end
  end
end

-- ── Navigation ────────────────────────────────────────────────────────────────

local function jump_to_agent(agent)
  if not agent then return end
  local target_name = agent.window_name or agent.session
  if not target_name then return end

  -- find the matching hollow workspace and switch to it
  local ok_ws, ws_list = pcall(hollow.term.workspaces)
  if ok_ws and type(ws_list) == "table" then
    for _, ws in ipairs(ws_list) do
      if ws.name == target_name then
        pcall(hollow.term.switch_workspace, ws.index)
        break
      end
    end
  end

  -- also attempt to focus the specific pane by numeric ID
  local pane_id_num = tonumber(agent.pane_id)
  if pane_id_num then
    pcall(hollow.term.focus_pane_by_id, pane_id_num)
  end
end

local function select_next()
  if #agents == 0 then return end
  cursor = cursor % #agents + 1
  jump_to_agent(agents[cursor])
end

local function select_prev()
  if #agents == 0 then return end
  cursor = ((cursor - 2) % #agents) + 1
  jump_to_agent(agents[cursor])
end

-- ── Git stats ─────────────────────────────────────────────────────────────────

-- Everything for one worktree in a single call: branch/ahead/behind/dirty,
-- rebase-in-progress, base-branch resolution (same precedence as workmux:
-- branch.<name>.workmux-base, then origin/HEAD, then main/master), committed
-- diff vs base, uncommitted diff vs HEAD, and untracked lines (counted as
-- added, capped at untracked_byte_limit bytes of file content).
local GIT_SCRIPT_BODY = [[
cd %s 2>/dev/null || { echo '{}'; exit 0; }
status_out=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
if [ -z "$status_out" ]; then echo '{}'; exit 0; fi

branch=$(printf '%%s\n' "$status_out" | sed -n 's/^# branch\.head //p')
[ "$branch" = "(detached)" ] && branch=""
ab_line=$(printf '%%s\n' "$status_out" | sed -n 's/^# branch\.ab //p')
ahead=$(printf '%%s\n' "$ab_line" | sed -n 's/^+\([0-9]*\).*/\1/p'); ahead=${ahead:-0}
behind=$(printf '%%s\n' "$ab_line" | sed -n 's/.*-\([0-9]*\)$/\1/p'); behind=${behind:-0}
dirty=false
printf '%%s\n' "$status_out" | grep -qv '^#' && dirty=true

rebasing=false
rb=$(git rev-parse --git-path rebase-merge 2>/dev/null)
[ -n "$rb" ] && [ -d "$rb" ] && rebasing=true
if ! $rebasing; then
  rb=$(git rev-parse --git-path rebase-apply 2>/dev/null)
  [ -n "$rb" ] && [ -d "$rb" ] && rebasing=true
fi

added=0; removed=0
if [ -n "$branch" ]; then
  base=$(git config --local --get "branch.$branch.workmux-base" 2>/dev/null)
  if [ -z "$base" ]; then
    head_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
    base=${head_ref#refs/remotes/origin/}
    [ "$base" = "$head_ref" ] && base=""
  fi
  if [ -z "$base" ]; then
    for candidate in main master; do
      if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then base="$candidate"; break; fi
    done
  fi
  [ -z "$base" ] && base="main"
  if [ "$branch" != "$base" ]; then
    read -r added removed <<<"$(git diff --no-ext-diff --no-textconv --numstat "$base...HEAD" 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')"
  fi
fi

read -r unc_added unc_removed <<<"$(git diff --no-ext-diff --no-textconv --numstat HEAD 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')"
untracked=$(git ls-files -z --others --exclude-standard 2>/dev/null | xargs -0 -r cat 2>/dev/null | head -c %d | wc -l)
unc_added=$((unc_added + untracked))

jq -n --arg branch "$branch" --argjson ahead "$ahead" --argjson behind "$behind" \
  --argjson dirty "$dirty" --argjson rebasing "$rebasing" \
  --argjson added "$added" --argjson removed "$removed" \
  --argjson uadded "$unc_added" --argjson uremoved "$unc_removed" \
  '{branch: (if $branch == "" then null else $branch end), ahead:$ahead, behind:$behind,
    dirty:$dirty, rebasing:$rebasing, added:$added, removed:$removed,
    uncommitted_added:$uadded, uncommitted_removed:$uremoved}'
]]

local function git_script_for(dir)
  local untracked_limit = cfg.untracked and cfg.untracked_byte_limit or 0
  return GIT_SCRIPT_BODY:format(quote(dir), untracked_limit)
end

local function refresh_git(dir)
  local entry = git_cache[dir] or {}
  entry.fetched_at = os.time()
  git_cache[dir] = entry

  local ok, stdout = run_bash(git_script_for(dir))
  if not ok then return end

  local line = last_json_object(stdout)
  if not line then
    entry.stats = nil
    return
  end
  local decode_ok, data = pcall(hollow.json.decode, line)
  if not decode_ok or type(data) ~= "table" or data.branch == nil and not next(data) then
    entry.stats = nil
    return
  end
  entry.stats = {
    branch               = data.branch,
    ahead                = data.ahead or 0,
    behind               = data.behind or 0,
    dirty                = data.dirty or false,
    rebasing             = data.rebasing or false,
    added                = data.added or 0,
    removed              = data.removed or 0,
    uncommitted_added    = data.uncommitted_added or 0,
    uncommitted_removed  = data.uncommitted_removed or 0,
  }
end

local function stats_for(agent)
  if not cfg.git then return nil end
  local entry = agent.workdir and git_cache[agent.workdir]
  return entry and entry.stats or nil
end

-- Refresh worktrees whose stats have aged out; true if anything changed.
local function refresh_due_git(now)
  if not cfg.git then return false end
  local refreshed, seen = 0, {}
  for _, agent in ipairs(agents) do
    if refreshed >= cfg.git_worktrees_per_tick then break end
    local dir = agent.workdir
    if dir and dir ~= "" and not seen[dir] then
      seen[dir] = true
      local entry = git_cache[dir]
      if not entry or (now - (entry.fetched_at or 0)) >= cfg.git_refresh_secs then
        refresh_git(dir)
        refreshed = refreshed + 1
      end
    end
  end
  return refreshed > 0
end

-- ── Row pieces ────────────────────────────────────────────────────────────────

local function status_icon(agent, stale)
  if stale then return STALE_ICON, C.stale end
  if agent.status == "working" then
    if cfg.spinner then
      return SPINNER_FRAMES[spinner_frame], C.working
    end
    return agent.live_icon and (agent.live_icon .. " ") or "⠿ ", C.working
  end
  if agent.live_icon then return agent.live_icon .. " ", C.accent end
  local icon = STATUS_ICONS[agent.status or ""]
  if icon then return icon, C[agent.status] or C.dim end
  return IDLE_ICON, C.dim
end

-- Diff-stat fragments ({text, color} pairs) that fit `avail` columns, dropping
-- the lower-priority half first — the same ladder as the tmux sidebar, where
-- bright uncommitted stats outrank dim committed ones.
local function git_fragments(stats, avail, stale)
  if not stats then return {} end

  local committed, uncommitted = {}, {}
  local has_committed = stats.added > 0 or stats.removed > 0
  local has_uncommitted =
    stats.uncommitted_added > 0 or stats.uncommitted_removed > 0 or stats.dirty
  -- when every change is still uncommitted, the dim committed half is noise
  local all_uncommitted = has_uncommitted
    and stats.uncommitted_added == stats.added
    and stats.uncommitted_removed == stats.removed

  if stats.rebasing then
    committed[#committed + 1] = { REBASE_ICON, C.waiting }
  end
  if has_committed and not all_uncommitted then
    if stats.added > 0 then
      committed[#committed + 1] = { "+" .. stats.added, C.added_dim }
    end
    if stats.removed > 0 then
      committed[#committed + 1] = { "-" .. stats.removed, C.removed_dim }
    end
  end
  if has_uncommitted then
    uncommitted[#uncommitted + 1] = { DIFF_ICON, C.accent }
    if stats.uncommitted_added > 0 then
      uncommitted[#uncommitted + 1] = { "+" .. stats.uncommitted_added, C.added }
    end
    if stats.uncommitted_removed > 0 then
      uncommitted[#uncommitted + 1] = { "-" .. stats.uncommitted_removed, C.removed }
    end
  end

  local function join(...)
    local out = {}
    for _, group in ipairs({ ... }) do
      for _, frag in ipairs(group) do
        if #out > 0 then out[#out + 1] = { " ", C.dim } end
        out[#out + 1] = { frag[1], stale and C.stale or frag[2] }
      end
    end
    return out
  end

  local ladder = { join(committed, uncommitted), join(uncommitted), join(committed) }
  for _, variant in ipairs(ladder) do
    local width = 0
    for _, frag in ipairs(variant) do width = width + dwidth(frag[1]) end
    if width > 0 and width <= avail then return variant end
  end
  return {}
end

-- ── Sidebar render ────────────────────────────────────────────────────────────

local function render(ctx)
  local rows  = {}
  local width = cfg.width
  if type(ctx) == "table" and type(ctx.size) == "table" and type(ctx.size.cols) == "number"
      and ctx.size.cols > 4 then
    width = ctx.size.cols
  end
  local now = os.time()

  -- header: name on the left, working/waiting/done counts on the right
  local counts = { working = 0, waiting = 0, done = 0 }
  for _, agent in ipairs(agents) do
    if counts[agent.status or ""] then counts[agent.status] = counts[agent.status] + 1 end
  end
  rows[#rows + 1] = ui.row({
    ui.span("  workmux", { fg = C.header, bold = true }),
    ui.spacer(),
    ui.span(tostring(counts.working), { fg = C.working }),
    ui.span("/", { fg = C.dim }),
    ui.span(tostring(counts.waiting), { fg = C.waiting }),
    ui.span("/", { fg = C.dim }),
    ui.span(counts.done .. "  ", { fg = C.done }),
  })
  rows[#rows + 1] = ui.divider()

  if #agents == 0 then
    rows[#rows + 1] = ui.row({
      ui.span("  no agents", { fg = C.dim, italic = true }),
    })
  else
    local current_ws = ctx and ctx.term and ctx.term.workspace and ctx.term.workspace.name or ""

    for i, agent in ipairs(agents) do
      local is_current = (agent.window_name == current_ws or agent.session == current_ws)
      local bg         = (i == cursor) and C.cursor_bg or nil
      local stale      = is_stale(agent, now)
      local stats      = stats_for(agent)

      local icon, icon_color   = status_icon(agent, stale)
      local primary, secondary = resolve_labels(agent, stats)
      local elapsed            = format_elapsed(activity_ts(agent))
      local name_color         = stale and C.stale or (is_current and C.text_hi or C.text)

      -- line 1: status icon · worktree · time in state
      rows[#rows + 1] = ui.row({
        ui.span(" " .. icon, { fg = icon_color, bg = bg }),
        ui.span(trunc(primary, width - dwidth(icon) - dwidth(elapsed) - 4),
          { fg = name_color, bold = is_current, bg = bg }),
        ui.spacer(),
        ui.span(elapsed ~= "" and (elapsed .. " ") or " ", { fg = C.dim, bg = bg }),
      }, { fill_bg = bg })

      -- line 2: project · diff stats
      local frags      = git_fragments(stats, math.floor(width / 2), stale)
      local frag_width = 0
      for _, frag in ipairs(frags) do frag_width = frag_width + dwidth(frag[1]) end

      local line2 = {
        ui.span("    ", { bg = bg }),
        ui.span(trunc(secondary, width - frag_width - 6),
          { fg = stale and C.stale or C.project, bg = bg }),
        ui.spacer(),
      }
      for _, frag in ipairs(frags) do
        line2[#line2 + 1] = ui.span(frag[1], { fg = frag[2], bg = bg })
      end
      line2[#line2 + 1] = ui.span(" ", { bg = bg })
      rows[#rows + 1] = ui.row(line2, { fill_bg = bg })

      -- line 3: the agent's own summary, when it set one
      if cfg.show_title and agent.pane_title and agent.pane_title ~= "" then
        rows[#rows + 1] = ui.row({
          ui.span("    ", { bg = bg }),
          ui.span(trunc(agent.pane_title, width - 6),
            { fg = stale and C.stale or C.title, italic = true, bg = bg }),
          ui.spacer(),
        }, { fill_bg = bg })
      end
    end
  end

  -- footer: hint line
  rows[#rows + 1] = ui.divider()
  rows[#rows + 1] = ui.row({
    ui.span("  ⌃⌥j/k  ⌃⌥w  ⌃⌥r ", { fg = "#2a2a2a" }),
  })

  return ui.column(rows)
end

-- ── Scheduling ────────────────────────────────────────────────────────────────

local function redraw()
  pcall(ui.sidebar.invalidate)
end

local function any_working()
  for _, agent in ipairs(agents) do
    if agent.status == "working" then return true end
  end
  return false
end

local tick -- forward declaration; tick reschedules itself via hollow.defer

-- One animation frame: advance the spinner, and at the slower cadences reload
-- agent state and refresh one worktree's git stats.
tick = function()
  local dirty = false
  local now   = os.time()

  if cfg.spinner and any_working() then
    spinner_frame = spinner_frame % #SPINNER_FRAMES + 1
    dirty = true
  end

  if now - last_load >= cfg.reload_secs then
    load_agents()
    dirty = true
  end

  if refresh_due_git(now) then dirty = true end

  if dirty then redraw() end

  -- hollow has no repeating-interval API; `defer` is one-shot, so keep the
  -- animation going by rescheduling ourselves at the end of every frame.
  if ticking then
    pcall(hollow.defer, tick, cfg.spinner_ms)
  end
end

-- ── HTP handlers ─────────────────────────────────────────────────────────────

local function on_htp_status(ctx)
  local p = ctx.payload
  if type(p) ~= "table" then return end
  local pid = tostring(p.pane_id or "")
  if pid == "" then return end

  if p.clear then
    live_cache[pid] = nil
  else
    live_cache[pid] = { icon = p.icon, ts = os.time() }
  end

  -- patch matching agent in-place so the next render picks it up immediately
  for _, agent in ipairs(agents) do
    if agent.pane_id == pid then
      agent.live_icon = not p.clear and p.icon or nil
      agent.live_ts   = not p.clear and os.time() or nil
      break
    end
  end
  redraw()
end

local function on_htp_sidebar(ctx)
  local p      = ctx.payload
  local action = type(p) == "table" and p.action or nil
  if action == "toggle" then
    ui.sidebar.toggle()
  elseif action == "show" then
    if sidebar_widget then ui.sidebar.mount(sidebar_widget) end
  elseif action == "hide" then
    ui.sidebar.unmount()
  elseif action == "refresh" then
    load_agents()
    redraw()
  end
end

-- ── Widget event handler ──────────────────────────────────────────────────────

local REFRESH_EVENTS = {
  ["workspace:changed"]              = true,
  ["workspace:new"]                  = true,
  ["workspace:closed"]               = true,
  ["term:pane_focused"]              = true,
  ["term:cwd_changed"]               = true,
  ["term:foreground_process_changed"] = true,
}

local function on_widget_event(name, payload)
  if not REFRESH_EVENTS[name] then return end

  load_agents()

  -- track cursor to follow the user's current workspace
  local ws_name
  if (name == "workspace:changed" or name == "workspace:new")
      and type(payload) == "table"
      and type(payload.workspace) == "table" then
    ws_name = payload.workspace.name
  else
    local ok, ws = pcall(hollow.term.current_workspace)
    ws_name = ok and type(ws) == "table" and ws.name or nil
  end
  sync_cursor_to_workspace(ws_name)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local M = {}

--- Reload agent state and force a git refresh on the next tick.
function M.refresh()
  load_agents()
  for _, entry in pairs(git_cache) do entry.fetched_at = 0 end
  redraw()
end

---@param opts? table see the header comment for the recognised keys
function M.setup(opts)
  if type(opts) == "table" then
    for key, value in pairs(opts) do cfg[key] = value end
  end

  load_agents()

  sidebar_widget = ui.sidebar.new({
    side     = cfg.side,
    width    = cfg.width,
    render   = render,
    on_event = on_widget_event,
  })
  ui.sidebar.mount(sidebar_widget)

  -- real-time status pushes from workmux via `hollow cli emit`
  hollow.htp.on_emit("workmux:status",  on_htp_status)
  hollow.htp.on_emit("workmux:sidebar", on_htp_sidebar)

  -- global keybindings (registered as defaults — users can override)
  hollow.keymap.default("<C-A-j>", select_next)
  hollow.keymap.default("<C-A-k>", select_prev)
  hollow.keymap.default("<C-A-w>", function() ui.sidebar.toggle() end)
  hollow.keymap.default("<C-A-r>", M.refresh)

  -- kick off the self-rescheduling animation/refresh loop
  ticking = true
  pcall(hollow.defer, tick, cfg.spinner_ms)
end

return M

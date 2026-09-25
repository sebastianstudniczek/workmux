-- workmux-sidebar.lua
-- Hollow sidebar plugin showing workmux agent statuses, modelled on the tmux
-- sidebar (`workmux sidebar`).
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
--     spinner = true, spinner_ms = 120,   -- animate working agents
--     git = true, git_refresh_secs = 10,  -- diff stats, per-worktree poll
--     untracked = true,                   -- count untracked lines as adds
--     show_title = true,                  -- third line with the pane title
--     stale_after = 3600,                 -- seconds before an agent dims out
--     timer = function(ms, fn) ... end,   -- scheduler, if autodetect fails
--     redraw = function() ... end,        -- repaint hook, ditto
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
  stale_after            = 3600, -- matches the tmux sidebar's stale threshold
  spinner                = true,
  spinner_ms             = 120,
  reload_secs            = 2,    -- re-read agent state files from disk
  git                    = true,
  git_refresh_secs       = 10,
  git_worktrees_per_tick = 1,    -- bound the git work done in one tick
  untracked              = true,
  untracked_file_limit   = 200,
  untracked_byte_limit   = 1024 * 1024,
  show_title             = true,
  timer                  = nil,
  redraw                 = nil,
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
local IDLE_ICON    = "· "
local STALE_ICON   = "◦ "
local DIFF_ICON    = "±"

-- ── Module state ──────────────────────────────────────────────────────────────

-- pane_id (string) → { icon, ts } from live HTP emits (supersedes disk data)
local live_cache     = {}
-- sorted list of agent tables (from disk + live overlay)
local agents         = {}
-- 1-based index of the "selected" agent (follows current workspace)
local cursor         = 1
-- sidebar widget handle
local sidebar_widget = nil
-- workdir → { stats = {...}, base, base_for, fetched_at }
local git_cache      = {}
local spinner_frame  = 1
local last_load      = 0
local timer_handle   = nil

-- ── Small utilities ───────────────────────────────────────────────────────────

local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

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
  -- one UTF-8 sequence at a time (no %z: it is gone in Lua 5.2+)
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

-- Call each candidate until one doesn't raise; used to probe optional hollow APIs.
local function first_ok(candidates)
  for _, fn in ipairs(candidates) do
    local ok, res = pcall(fn)
    if ok then return res == nil and true or res end
  end
  return nil
end

-- ── Paths ─────────────────────────────────────────────────────────────────────

local function agents_dir()
  local xdg = os.getenv("XDG_STATE_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/workmux/agents"
  end
  local home = os.getenv("HOME")
  if not home then return nil end
  return home .. "/.local/state/workmux/agents"
end

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

-- ── File helpers ──────────────────────────────────────────────────────────────

local function list_hollow_agent_files(dir)
  if not dir then return {} end
  local files = {}
  local f = io.popen('ls -1 "' .. dir .. '"/hollow__*.json 2>/dev/null', "r")
  if not f then return files end
  for line in f:lines() do
    local name = line:match("^%s*(.-)%s*$")
    if name and name ~= "" then
      files[#files + 1] = name
    end
  end
  pcall(function() f:close() end)
  return files
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- ── Git stats ─────────────────────────────────────────────────────────────────

local function quote(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function capture(cmd)
  local f = io.popen(cmd, "r")
  if not f then return nil end
  local ok, out = pcall(function() return f:read("*a") end)
  pcall(function() f:close() end)
  return ok and out or nil
end

local function git_cmd(dir, ...)
  local parts = { "git", "--no-optional-locks", "-C", quote(dir) }
  for _, arg in ipairs({ ... }) do parts[#parts + 1] = arg end
  parts[#parts + 1] = "2>/dev/null"
  return table.concat(parts, " ")
end

local function parse_numstat(text)
  local added, removed = 0, 0
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    -- <added>\t<removed>\t<path>; binary files use "-" and parse as 0
    local a, r = line:match("^(%S+)%s+(%S+)%s")
    added   = added + (tonumber(a) or 0)
    removed = removed + (tonumber(r) or 0)
  end
  return added, removed
end

local function parse_porcelain(text)
  local branch, ahead, behind, dirty = nil, 0, 0, false
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local head = line:match("^# branch%.head (.+)$")
    if head then branch = trim(head) end
    local ab = line:match("^# branch%.ab (.+)$")
    if ab then
      local a, b = ab:match("^%+(%d+)%s+%-(%d+)")
      ahead, behind = tonumber(a) or 0, tonumber(b) or 0
    end
    if line:sub(1, 1) ~= "#" and trim(line) ~= "" then dirty = true end
  end
  if branch == "(detached)" then branch = nil end
  return branch, ahead, behind, dirty
end

-- Same precedence as workmux: branch.<name>.workmux-base, then origin/HEAD,
-- then main/master.
local function resolve_base(dir, branch)
  local configured = trim(capture(git_cmd(
    dir, "config", "--local", "--get", quote("branch." .. branch .. ".workmux-base"))))
  if configured ~= "" then return configured end

  local head = trim(capture(git_cmd(dir, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")))
  local default_branch = head:match("^refs/remotes/origin/(.+)$")
  if default_branch then return trim(default_branch) end

  for _, candidate in ipairs({ "main", "master" }) do
    if trim(capture(git_cmd(dir, "rev-parse", "--verify", "--quiet", candidate))) ~= "" then
      return candidate
    end
  end
  return "main"
end

local function count_lines(path, byte_limit)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local lines, read = 0, 0
  while read < byte_limit do
    local chunk = f:read(64 * 1024)
    if not chunk then break end
    read = read + #chunk
    local _, n = chunk:gsub("\n", "")
    lines = lines + n
  end
  f:close()
  return lines
end

-- Untracked files count as added lines, the way `workmux sidebar` counts them.
local function count_untracked_lines(dir)
  local listing = capture(git_cmd(
    dir, "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard")) or ""
  local total, seen = 0, 0
  for rel in listing:gmatch("[^\r\n]+") do
    seen = seen + 1
    if seen > cfg.untracked_file_limit then break end
    -- git quotes paths containing newlines; skip those rather than mis-join them
    if rel:sub(1, 1) ~= '"' then
      total = total + count_lines(dir .. "/" .. rel, cfg.untracked_byte_limit)
    end
  end
  return total
end

-- Refresh one worktree's diff stats. This blocks, so callers keep it off the
-- render path and bound it to a couple of worktrees per tick.
local function refresh_git(dir)
  local entry = git_cache[dir] or {}
  entry.fetched_at = os.time()
  git_cache[dir] = entry

  local status_out = capture(git_cmd(dir, "status", "--porcelain=v2", "--branch"))
  if not status_out or trim(status_out) == "" then
    entry.stats = nil
    return
  end

  local branch, ahead, behind, dirty = parse_porcelain(status_out)
  if entry.base_for ~= branch then
    entry.base     = branch and resolve_base(dir, branch) or nil
    entry.base_for = branch
  end

  local added, removed = 0, 0
  if branch and entry.base and branch ~= entry.base then
    added, removed = parse_numstat(capture(git_cmd(
      dir, "diff", "--no-ext-diff", "--no-textconv", "--numstat",
      quote(entry.base .. "...HEAD"))))
  end

  local unc_added, unc_removed = parse_numstat(capture(git_cmd(
    dir, "diff", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD")))
  if cfg.untracked then
    unc_added = unc_added + count_untracked_lines(dir)
  end

  entry.stats = {
    branch              = branch,
    ahead               = ahead,
    behind              = behind,
    dirty               = dirty,
    added               = added,
    removed             = removed,
    uncommitted_added   = unc_added,
    uncommitted_removed = unc_removed,
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

-- ── Agent loading ─────────────────────────────────────────────────────────────

local function activity_ts(agent)
  return agent.live_ts or agent.activity_ts or agent.status_ts or agent.updated_ts or 0
end

local function is_stale(agent, now)
  local ts = activity_ts(agent)
  return ts > 0 and (now - ts) > cfg.stale_after
end

local function load_agents()
  local files  = list_hollow_agent_files(agents_dir())
  local result = {}

  for _, path in ipairs(files) do
    local content = read_file(path)
    -- a half-written state file is normal: skip it and pick it up next tick
    local ok, data = pcall(hollow.json.decode, content or "")
    if ok and type(data) == "table" then
      -- workmux writes AgentState, where the pane id lives under pane_key
      local pane_key = type(data.pane_key) == "table" and data.pane_key or {}
      local pane_id  = pane_key.pane_id or data.pane_id
      if pane_id ~= nil then
        pane_id = tostring(pane_id)
        local live = live_cache[pane_id]
        result[#result + 1] = {
          pane_id     = pane_id,
          workdir     = data.workdir,
          status      = data.status,
          status_ts   = data.status_ts,
          activity_ts = data.activity_ts,
          updated_ts  = data.updated_ts,
          pane_title  = data.pane_title,
          window_name = data.window_name,
          session     = data.session_name or data.session,
          agent_kind  = data.agent_kind,
          live_icon   = live and live.icon or nil,
          live_ts     = live and live.ts or nil,
        }
      end
    end
  end

  -- most recently active first; pane_id breaks ties so the order stays stable
  table.sort(result, function(a, b)
    local ta, tb = activity_ts(a), activity_ts(b)
    if ta ~= tb then return ta > tb end
    return a.pane_id < b.pane_id
  end)

  agents    = result
  last_load = os.time()
  cursor    = math.max(1, math.min(cursor, math.max(1, #agents)))
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
  if type(ctx) == "table" and type(ctx.width) == "number" and ctx.width > 4 then
    width = ctx.width
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

-- hollow's timer and repaint entry points differ between versions, so probe a
-- few and let the caller inject its own through opts.timer / opts.redraw.
local function schedule(interval_ms, fn)
  if type(cfg.timer) == "function" then
    local ok, handle = pcall(cfg.timer, interval_ms, fn)
    if ok then return handle or true end
  end
  return first_ok({
    function() return hollow.timer.interval(interval_ms, fn) end,
    function() return hollow.timer.every(interval_ms, fn) end,
    function() return hollow.timer.start(interval_ms, fn) end,
    function() return hollow.loop.every(interval_ms, fn) end,
    function() return ui.timer.interval(interval_ms, fn) end,
  })
end

local function redraw()
  if type(cfg.redraw) == "function" then
    pcall(cfg.redraw)
    return
  end
  first_ok({
    function() return ui.sidebar.redraw(sidebar_widget) end,
    function() return sidebar_widget:redraw() end,
    function() return ui.sidebar.refresh(sidebar_widget) end,
    function() return ui.redraw() end,
  })
end

local function any_working()
  for _, agent in ipairs(agents) do
    if agent.status == "working" then return true end
  end
  return false
end

-- One animation frame: advance the spinner, and at the slower cadences reload
-- agent state from disk and refresh one worktree's git stats.
local function tick()
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

--- One animation/refresh step. Exposed so a host with its own scheduler can
--- drive the sidebar when `schedule()` finds no hollow timer API.
function M.tick()
  tick()
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

  -- without a timer the sidebar still works: it refreshes on events and shows
  -- a static icon instead of the spinner
  timer_handle = schedule(cfg.spinner_ms, tick)
  M.has_timer  = timer_handle ~= nil
end

return M

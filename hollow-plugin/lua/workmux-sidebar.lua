-- workmux-sidebar.lua
-- Hollow sidebar plugin showing workmux agent statuses.
--
-- Install: add this plugin's parent directory to your hollow init.lua:
--   hollow.plugins.setup({ plugins = { "/path/to/workmux/hollow-plugin" } })
--
-- Optional config (call before setup, or pass as opts to setup):
--   require("workmux-sidebar").setup({ width = 30, side = "left" })
--
-- Default keybindings (override with hollow.keymap.set):
--   <C-A-j>  jump to next agent
--   <C-A-k>  jump to previous agent
--   <C-A-w>  toggle sidebar
--   <C-A-r>  refresh agent list from disk
--
-- HTP channels (usable from shell via `hollow cli emit <channel> <json>`):
--   workmux:status   {"pane_id":"<id>","icon":"<icon>"}        -- set live icon
--                    {"pane_id":"<id>","clear":true}           -- clear live icon
--   workmux:sidebar  {"action":"toggle"|"show"|"hide"|"refresh"}

local hollow = _G.hollow
local ui     = hollow.ui

-- ── Platform detection ────────────────────────────────────────────────────────

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local SEP        = IS_WINDOWS and "\\" or "/"

-- ── Minimal JSON decoder ──────────────────────────────────────────────────────

local function json_decode(str)
  local pos = 1

  local function skip()
    while pos <= #str and str:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local parse  -- forward declaration

  local function parse_string()
    pos = pos + 1 -- consume opening quote
    local buf = {}
    while pos <= #str do
      local ch = str:sub(pos, pos)
      if ch == '"' then
        pos = pos + 1
        return table.concat(buf)
      end
      if ch == "\\" then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if     esc == "n" then buf[#buf + 1] = "\n"
        elseif esc == "t" then buf[#buf + 1] = "\t"
        elseif esc == "r" then buf[#buf + 1] = "\r"
        else                   buf[#buf + 1] = esc
        end
      else
        buf[#buf + 1] = ch
      end
      pos = pos + 1
    end
    error("unterminated string")
  end

  local function parse_object()
    pos = pos + 1 -- consume '{'
    local t = {}
    skip()
    if str:sub(pos, pos) == "}" then pos = pos + 1; return t end
    while true do
      skip()
      local key = parse()
      skip()
      if str:sub(pos, pos) == ":" then pos = pos + 1 end
      local val = parse()
      t[key] = val
      skip()
      local sep = str:sub(pos, pos)
      if sep == "}" then pos = pos + 1; return t end
      if sep == "," then pos = pos + 1 end
    end
  end

  local function parse_array()
    pos = pos + 1 -- consume '['
    local t = {}
    skip()
    if str:sub(pos, pos) == "]" then pos = pos + 1; return t end
    while true do
      t[#t + 1] = parse()
      skip()
      local sep = str:sub(pos, pos)
      if sep == "]" then pos = pos + 1; return t end
      if sep == "," then pos = pos + 1 end
    end
  end

  parse = function()
    skip()
    local c = str:sub(pos, pos)
    if c == '"'  then return parse_string() end
    if c == "{"  then return parse_object() end
    if c == "["  then return parse_array() end
    if str:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true  end
    if str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
    if str:sub(pos, pos + 3) == "null"  then pos = pos + 4; return nil   end
    -- number
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if s then
      local n = tonumber(str:sub(s, e))
      pos = e + 1
      return n
    end
    error("unexpected character '" .. c .. "' at pos " .. pos)
  end

  local ok, result = pcall(parse)
  return ok and result or nil
end

-- ── XDG state path ────────────────────────────────────────────────────────────

local function agents_dir()
  local xdg = os.getenv("XDG_STATE_HOME")
  if xdg and xdg ~= "" then
    return xdg .. SEP .. "workmux" .. SEP .. "agents"
  end
  local home = os.getenv(IS_WINDOWS and "USERPROFILE" or "HOME")
  if not home then return nil end
  if IS_WINDOWS then
    return home .. "\\.local\\state\\workmux\\agents"
  else
    return home .. "/.local/state/workmux/agents"
  end
end

-- ── File helpers ──────────────────────────────────────────────────────────────

local function list_hollow_agent_files(dir)
  if not dir then return {} end
  local files = {}
  local cmd
  if IS_WINDOWS then
    -- dir /b lists filenames only; redirect errors to NUL
    cmd = 'dir /b /a:-d "' .. dir .. '\\hollow__*.json" 2>NUL'
  else
    cmd = 'ls -1 "' .. dir .. '"/hollow__*.json 2>/dev/null'
  end
  local f = io.popen(cmd, "r")
  if not f then return files end
  for line in f:lines() do
    local name = line:match("^%s*(.-)%s*$")
    if name and name ~= "" then
      -- dir /b on Windows yields filename only; ls on Unix yields the full path
      if IS_WINDOWS and not name:find("[/\\]", 1, true) then
        name = dir .. SEP .. name
      end
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

-- ── Module state ──────────────────────────────────────────────────────────────

-- pane_id (string) → { icon, ts } from live HTP emits (supersedes disk data)
local live_cache = {}
-- sorted list of decoded agent tables (from disk + live overlay)
local agents     = {}
-- 1-based index of the "selected" agent (follows current workspace)
local cursor     = 1
-- sidebar widget handle
local sidebar_widget = nil

-- ── Formatting ────────────────────────────────────────────────────────────────

local STATUS_COLORS = {
  working = "#f5c842",  -- yellow
  waiting = "#e07b54",  -- orange
  done    = "#5fba7d",  -- green
}

local STATUS_FALLBACK_ICONS = {
  working = "⠸",
  waiting = "◆",
  done    = "✔",
}

local function format_elapsed(ts)
  if not ts then return "" end
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

local function trim_name(name, max_len)
  if not name or name == "" then return "?" end
  -- strip common workmux prefix so names fit in a narrow sidebar
  name = name:gsub("^wm%-", "")
  if #name > max_len then
    name = name:sub(1, max_len - 1) .. "…"
  end
  return name
end

-- ── Agent loading ─────────────────────────────────────────────────────────────

local function load_agents()
  local dir   = agents_dir()
  local files = list_hollow_agent_files(dir)
  local result = {}

  for _, path in ipairs(files) do
    local content = read_file(path)
    if content then
      local data = json_decode(content)
      if type(data) == "table" and data.pane_id ~= nil then
        local pid  = tostring(data.pane_id)
        local live = live_cache[pid]
        data._live_icon = live and live.icon or nil
        data._live_ts   = live and live.ts   or nil
        result[#result + 1] = data
      end
    end
  end

  -- most recently active first
  table.sort(result, function(a, b)
    local ta = a._live_ts or a.activity_ts or a.status_ts or a.updated_ts or 0
    local tb = b._live_ts or b.activity_ts or b.status_ts or b.updated_ts or 0
    return ta > tb
  end)

  agents = result
  cursor = math.max(1, math.min(cursor, math.max(1, #agents)))
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

-- ── Sidebar render ────────────────────────────────────────────────────────────

local function render(ctx)
  local rows = {}

  -- header
  rows[#rows + 1] = ui.row({
    ui.span("  workmux", { fg = "#777777", bold = true }),
    ui.spacer(),
    ui.span(#agents .. "  ", { fg = "#444444" }),
  })
  rows[#rows + 1] = ui.divider()

  if #agents == 0 then
    rows[#rows + 1] = ui.row({
      ui.span("  no agents", { fg = "#444444", italic = true }),
    })
  else
    local current_ws = ctx.term.workspace and ctx.term.workspace.name or ""

    for i, agent in ipairs(agents) do
      local is_current = (agent.window_name == current_ws or agent.session == current_ws)
      local is_cursor  = (i == cursor)
      local bg         = is_cursor and "#1e2430" or nil

      -- resolve display icon and its timestamp
      local icon, icon_ts, icon_color
      if agent._live_icon then
        icon       = agent._live_icon
        icon_ts    = agent._live_ts
        icon_color = "#f5c842"  -- accent for live (HTP-pushed) status
      else
        local status = agent.status
        icon         = STATUS_FALLBACK_ICONS[status] or "·"
        icon_ts      = agent.status_ts or agent.activity_ts
        icon_color   = STATUS_COLORS[status] or "#444444"
      end

      local name       = trim_name(agent.window_name or agent.session, 18)
      local elapsed    = format_elapsed(icon_ts)
      local name_color = is_current and "#e8e8e8" or "#aaaaaa"

      rows[#rows + 1] = ui.row({
        ui.span(" " .. icon .. " ", { fg = icon_color, bg = bg }),
        ui.span(name, { fg = name_color, bold = is_current, bg = bg }),
        ui.spacer(),
        ui.span(elapsed .. " ", { fg = "#444444", bg = bg }),
      }, { fill_bg = bg })
    end
  end

  -- footer: hint line
  rows[#rows + 1] = ui.divider()
  rows[#rows + 1] = ui.row({
    ui.span("  ⌃⌥j/k  ⌃⌥w ", { fg = "#2a2a2a" }),
  })

  return ui.column(rows)
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
    if tostring(agent.pane_id) == pid then
      agent._live_icon = not p.clear and p.icon or nil
      agent._live_ts   = not p.clear and os.time() or nil
      break
    end
  end
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

---@param opts? { width?: number, side?: "left"|"right" }
function M.setup(opts)
  opts = type(opts) == "table" and opts or {}
  local width = opts.width or 28
  local side  = opts.side  or "left"

  load_agents()

  sidebar_widget = ui.sidebar.new({
    side     = side,
    width    = width,
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
  hollow.keymap.default("<C-A-r>", function() load_agents() end)
end

return M

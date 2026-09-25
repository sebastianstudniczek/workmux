-- Auto-loaded by hollow on startup when this plugin is enabled.
-- Installs the workmux sidebar widget.
--
-- Options come from `_G.workmux_sidebar_opts` when set (put it in your hollow
-- init.lua before the plugin loads), so the sidebar can be configured without
-- editing this file:
--
--   _G.workmux_sidebar_opts = { width = 40, git = false }
--
-- A few knobs also read environment variables, for per-launch overrides:
--   WORKMUX_SIDEBAR_WIDTH   sidebar columns
--   WORKMUX_SIDEBAR_SIDE    "left" | "right"
--   WORKMUX_SIDEBAR_GIT     "0" disables git diff stats
--   WORKMUX_SIDEBAR_SPINNER "0" disables the working-agent spinner
local function env_opts()
  local opts = {}

  local width = tonumber(os.getenv("WORKMUX_SIDEBAR_WIDTH") or "")
  if width and width > 0 then opts.width = math.floor(width) end

  local side = os.getenv("WORKMUX_SIDEBAR_SIDE")
  if side == "left" or side == "right" then opts.side = side end

  if os.getenv("WORKMUX_SIDEBAR_GIT") == "0" then opts.git = false end
  if os.getenv("WORKMUX_SIDEBAR_SPINNER") == "0" then opts.spinner = false end

  return opts
end

local ok, sidebar = pcall(require, "workmux-sidebar")
if ok and type(sidebar) == "table" and type(sidebar.setup) == "function" then
  local opts = env_opts()
  local user = _G.workmux_sidebar_opts
  if type(user) == "table" then
    for key, value in pairs(user) do opts[key] = value end
  end

  local setup_ok, err = pcall(sidebar.setup, opts)
  if not setup_ok then
    -- a broken sidebar must not take the rest of hollow's startup down with it
    local notify = _G.hollow and _G.hollow.notify
    if type(notify) == "function" then
      pcall(notify, "workmux sidebar failed to start: " .. tostring(err))
    else
      io.stderr:write("workmux sidebar failed to start: " .. tostring(err) .. "\n")
    end
  end
end

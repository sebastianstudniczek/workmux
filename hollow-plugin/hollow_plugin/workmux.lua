-- Auto-loaded by hollow on startup when this plugin is enabled.
-- Installs the workmux sidebar widget.
local ok, sidebar = pcall(require, "workmux-sidebar")
if ok and type(sidebar) == "table" and type(sidebar.setup) == "function" then
  sidebar.setup()
end

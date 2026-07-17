local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local tmux_command = [[
if ! tmux has-session -t main 2>/dev/null ||
   [ "$(tmux display-message -p -t main '#{session_attached}')" -eq 0 ]; then
  exec tmux new-session -A -s main
fi

secondary="$(
  tmux list-sessions -F '#{?session_last_attached,#{session_last_attached},#{session_activity}} #{session_attached} #{session_name}' |
    awk '$2 == 0 && $3 ~ /^wezterm-/ { print $1, $3 }' |
    sort -nr |
    awk 'NR == 1 { print $2 }'
)"
if [ -n "$secondary" ]; then
  exec tmux attach-session -t "$secondary"
fi

exec tmux new-session -s "wezterm-$(date +%s)-$$"
]]

config.wsl_domains = {
  {
    name = 'WSL:Ubuntu',
    distribution = 'Ubuntu',
    default_cwd = '~',
    default_prog = { 'sh', '-c', tmux_command },
  },
}
config.default_domain = 'WSL:Ubuntu'
config.front_end = "OpenGL"

-- Since I am only using this for WSL, the default of CRLF on Windows is somewhat annoying since it leads to double-newline. Changing it to just CR does the right thing.
config.canonicalize_pasted_newlines = "CarriageReturn"

config.window_decorations = "RESIZE"
config.enable_scroll_bar = false

config.initial_cols = 120
config.initial_rows = 28

config.font_size = 12
config.font = wezterm.font('Berkeley Mono', {})

config.color_scheme = 'DoomOne'
config.color_scheme = 'Dracula'
config.color_scheme = 'Nord (Gogh)'

config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true

config.audible_bell = "Disabled"
config.visual_bell = {
  fade_out_duration_ms = 75,
}
config.colors = {
  visual_bell = '#202020',
}

config.scrollback_lines = 10000000

-- Add split-pane and navigation keybindings
-- local directions = {
--   Up = 'UpArrow',
--   Down = 'DownArrow',
--   Left = 'LeftArrow',
--   Right = 'RightArrow',
-- }
config.keys = {}

table.insert(config.keys, {
  key = 'Enter',
  mods = 'ALT',
  action = wezterm.action.DisableDefaultAssignment,
})

table.insert(config.keys, {
  key = 'F11',
  mods = 'NONE',
  action = wezterm.action.ToggleFullScreen,
})

-- for dir, key in pairs(directions) do
--   table.insert(config.keys, {
--     key = key,
--     mods = 'ALT|SHIFT',
--     action = wezterm.action.SplitPane {
--       direction = dir,
--       size = { Percent = 50 },
--     },
--   })
--   table.insert(config.keys, {
--     key = key,
--     mods = 'ALT',
--     action = wezterm.action.ActivatePaneDirection(dir),
--   })
-- end
-- Translate shortcuts into tmux commands
for _, key_binding in ipairs {
  { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action.SendString '\x1ay' },
  { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action.SendString '\x1at' },
  { key = 'Tab', mods = 'CTRL', action = wezterm.action.SendString '\x1a]' },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = wezterm.action.SendString '\x1a[' },
  { key = 'PageUp', mods = 'CTRL', action = wezterm.action.SendString '\x1a[' },
  { key = 'PageDown', mods = 'CTRL', action = wezterm.action.SendString '\x1a]' },
  { key = 'PageUp', mods = 'CTRL|SHIFT', action = wezterm.action.SendString '\x1a{' },
  { key = 'PageDown', mods = 'CTRL|SHIFT', action = wezterm.action.SendString '\x1a}' },
} do
  table.insert(config.keys, key_binding)
end

-- Add mouse bindings to disable plain-click link opening and enable Ctrl-click
-- instead
config.mouse_bindings = {
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'NONE',
    action = wezterm.action.Nop,
  },
  {
    event = { Down = { streak = 1, button = 'Left' } },
    mods = 'CTRL',
    action = wezterm.action.Nop,
  },
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'CTRL',
    action = wezterm.action.OpenLinkAtMouseCursor,
  },
  {
    event = { Down = { streak = 1, button = 'Left' } },
    mods = 'CTRL',
    mouse_reporting = true,
    action = wezterm.action.Nop,
  },
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'CTRL',
    mouse_reporting = true,
    action = wezterm.action.OpenLinkAtMouseCursor,
  },
}

return config

-- Keep candidate paging ahead of scheme-specific punctuation processors.
local M = {}
function M.func(key, env)
  if key.modifier ~= 0 or (key.keycode ~= 0x2c and key.keycode ~= 0x2e) then return 2 end
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or not ctx:has_menu() then return 2 end
  env.engine:process_key(KeyEvent(key.keycode == 0x2c and 'Page_Up' or 'Page_Down'))
  -- Consume boundary presses too, so punctuation cannot commit a candidate.
  return 1
end
return M

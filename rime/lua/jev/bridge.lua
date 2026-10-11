-- Snapshot and reorder genuine Rime candidates; no network or process I/O.
local M = {}
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)) end
local function quote(s)
  return '"' .. (tostring(s):gsub('[%z\1-\31\\"]', function(c)
    if c == '\\' then return '\\\\' elseif c == '"' then return '\\"' end
    return string.format('\\u%04x', string.byte(c))
  end)) .. '"'
end
local function chinese(s)
  if s == '' then return false end
  for _, n in utf8.codes(s) do
    if not ((n >= 0x3400 and n <= 0x9fff) or (n >= 0x20000 and n <= 0x3134f)) then return false end
  end
  return true
end
local function key(c)
  local g = c:get_genuine()
  return hex(table.concat({c.start,c._end,c.type or '',c.text or '',g.type or '',g.text or ''}, '\31'))
end
local function snapshot(ctx, raw, rows, protected)
  local encoded = {}
  for i,r in ipairs(rows) do
    encoded[i] = '{"id":'..quote('c'..(i-1))..',"key":'..quote(r.key)..',"text":'..quote(r.text)..'}'
  end
  local code = rows[1] and raw:sub(rows[1].start+1, rows[1].finish) or raw
  local value = '{"input":'..quote(raw)..',"pinyin":'..quote(code)..',"epoch":'..quote(ctx:get_property('_jev_epoch') or '')..
    ',"protected":'..tostring(protected)..',"candidates":['..table.concat(encoded, ',')..']}'
  ctx:set_property('_jev_snapshot', value)
end
function M.init(env)
  env.refreshing = false
  env.connection = env.engine.context.property_update_notifier:connect(function(ctx, name)
    if name ~= '_jev_result' or env.refreshing then return end
    env.refreshing = true
    ctx:refresh_non_confirmed_composition()
    env.refreshing = false
  end)
end
function M.fini(env)
  if env.connection then env.connection:disconnect() end
end
function M.func(input, env)
  local ctx, raw = env.engine.context, env.engine.context.input
  if raw == '' or ctx:get_option('ascii_mode') then
    ctx:set_property('_jev_snapshot', '')
    for c in input:iter() do yield(c) end
    return
  end
  local rows, seen, protected, first_start, first_end = {}, {}, false, nil, nil
  local function collect(c)
    if #rows >= 24 or not chinese(c.text) then return end
    if not first_start then first_start, first_end = c.start, c._end end
    if c.start ~= first_start or c._end ~= first_end or seen[c.text] then return end
    seen[c.text] = true
    local typ = c:get_genuine().type or ''
    if typ == 'custom' or typ == 'table' or (c.comment or ''):find('置顶', 1, true) then protected = true end
    rows[#rows+1] = {key=key(c), text=c.text, start=c.start, finish=c._end}
    return true
  end
  local result = ctx:get_property('_jev_result') or ''
  local epoch, code, target, count, signature, source = result:match('^([^|]*)|([^|]*)|([^|]*)|(%d+)|([^|]*)|([^|]*)$')
  local active = epoch and epoch == ctx:get_property('_jev_epoch') and code == hex(raw) and
    (source == 'jev' or source == 'local')
  if not active then
    ctx:set_property('_jev_applied', '')
    snapshot(ctx, raw, rows, false)
    for c in input:iter() do
      if collect(c) then snapshot(ctx, raw, rows, protected) end
      yield(c)
    end
    return
  end
  local buffered, found, flushed = {}, nil, false
  local expected = tonumber(count)
  if expected < 1 or expected > 24 then active = false end
  local function flush()
    local keys = {}
    for i=1,math.min(expected,#rows) do keys[#keys+1] = rows[i].key end
    local valid = active and not protected and found and #rows >= expected and hex(table.concat(keys, '\n')) == signature
    snapshot(ctx, raw, rows, protected)
    ctx:set_property('_jev_applied', valid and target or '')
    flushed = true
    if valid and found ~= 1 then
      yield(buffered[1])
      yield(buffered[found])
      for i=2,#buffered do if i ~= found then yield(buffered[i]) end end
    else
      for _,c in ipairs(buffered) do yield(c) end
    end
  end
  for c in input:iter() do
    if flushed then
      yield(c)
    else
      buffered[#buffered+1] = c
      collect(c)
      if key(c) == target and not found then found = #buffered end
      if (found and #rows >= expected) or #buffered >= 64 then flush() end
    end
  end
  if not flushed then flush() end
end
return M

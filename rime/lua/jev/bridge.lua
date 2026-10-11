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
local function split(s, separator)
  local parts, start = {}, 1
  while true do
    local at = s:find(separator, start, true)
    parts[#parts+1] = s:sub(start, at and at-1 or #s)
    if not at then return parts end
    start = at + #separator
  end
end
local function provider_family(source)
  if source == 'jev' then return 'jev' end
  if source == 'local' or source == 'tev-0.8b' or source == 'tev-4b' then return 'local' end
end
local function plan(result, ctx, raw)
  local v2 = result:sub(1,3) == 'v2|'
  local payload = v2 and result:sub(4) or result
  local epoch, code, target, count, signature, source = payload:match('^([^|]*)|([^|]*)|([^|]*)|(%d+)|([^|]*)|([^|]*)$')
  if not epoch or epoch == '' or epoch ~= ctx:get_property('_jev_epoch') or code ~= hex(raw) then return end
  local expected = tonumber(count)
  if expected < 1 or expected > 24 then return end
  local targets = v2 and split(target, ',') or {target}
  local groups = v2 and split(source, ',') or {source}
  if #targets > 2 or #targets ~= #groups then return end
  local seen_targets, families = {}, {}
  for i, value in ipairs(targets) do
    if value == '' or seen_targets[value] then return end
    seen_targets[value] = true
    local sources = v2 and split(groups[i], '+') or {groups[i]}
    for _, label in ipairs(sources) do
      local family = provider_family(label)
      if not family or families[family] then return end
      families[family] = true
    end
  end
  return {targets=targets, expected=expected, signature=signature, marker=v2 and result or target}
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
    ctx:set_property('_jev_applied', '')
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
  local requested = plan(ctx:get_property('_jev_result') or '', ctx, raw)
  if not requested then
    ctx:set_property('_jev_applied', '')
    snapshot(ctx, raw, rows, false)
    local scanned = 0
    for c in input:iter() do
      scanned = scanned + 1
      if scanned <= 64 and collect(c) then snapshot(ctx, raw, rows, protected) end
      yield(c)
    end
    return
  end
  local buffered, found, flushed, scanned = {}, {}, false, 0
  local function all_found()
    for _, target in ipairs(requested.targets) do if not found[target] then return false end end
    return true
  end
  local function flush()
    local keys, signed = {}, {}
    for i=1,math.min(requested.expected,#rows) do
      keys[#keys+1] = rows[i].key
      signed[rows[i].key] = true
    end
    local valid = not protected and all_found() and #rows >= requested.expected and
      hex(table.concat(keys, '\n')) == requested.signature
    for _, target in ipairs(requested.targets) do if not signed[target] then valid = false end end
    snapshot(ctx, raw, rows, protected)
    ctx:set_property('_jev_applied', valid and requested.marker or '')
    flushed = true
    if valid then
      yield(buffered[1])
      local placed = {[1]=true}
      for _, target in ipairs(requested.targets) do
        local index = found[target]
        if not placed[index] then yield(buffered[index]); placed[index] = true end
      end
      for i=2,#buffered do if not placed[i] then yield(buffered[i]) end end
    else
      for _,c in ipairs(buffered) do yield(c) end
    end
  end
  for c in input:iter() do
    scanned = scanned + 1
    if flushed then
      -- Keep subsequent callbacks bound to the original translation order.
      if scanned <= 64 and collect(c) then snapshot(ctx, raw, rows, protected) end
      yield(c)
    else
      buffered[#buffered+1] = c
      collect(c)
      local candidate_key = key(c)
      for _, target in ipairs(requested.targets) do
        if candidate_key == target and not found[target] then found[target] = #buffered end
      end
      if (all_found() and #rows >= requested.expected) or #buffered >= 64 then flush() end
    end
  end
  if not flushed then flush() end
end
return M

-- noema_learned.lua: Noema's learned-phrase translator (pure Lua 5.4; no sqlite3, no C modules).
--
-- Loaded as `lua_translator@*noema_learned` from `<user_data_dir>/lua/noema_learned.lua`;
-- noema-rime-deployer appends it to `engine/translators` through `<schema>.custom.yaml`
-- and never touches `rime.lua`. It reads `<user_data_dir>/noema_learned.tsv`, which
-- `LearnedSnapshotExporter` writes atomically from `learning.sqlite`:
--
--   <compact pinyin>\t<text>\t<frequency>\n     (most frequent first)
--
-- `init` loads the file into a map keyed by compact pinyin, so each lookup is one table
-- index. Typed input is looked up with the schema's `speller/delimiter` bytes removed and
-- ASCII lowercased, so `ni'hao` finds `nihao`. The file is re-read only when its size changes (checked at most every few
-- seconds); a rename(2) replacing it with equal size is picked up on the next `init`
-- (each schema switch or session start). Malformed lines are skipped; caps bound memory.

local MAX_FILE_BYTES = 32 * 1024 * 1024
local MAX_PER_KEY = 8
local MAX_TEXT_BYTES = 256
local RECHECK_SECONDS = 5

local function tsv_path()
  local dir = rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir() or nil
  if not dir or dir == "" then return nil end
  return dir .. "/noema_learned.tsv"
end

-- Size of the file at `path`, or nil when it cannot be opened.
local function file_size(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local size = file:seek("end")
  file:close()
  return size
end

local function load(path)
  local map = {}
  local file = io.open(path, "rb")
  if not file then return map, nil end
  local size = file:seek("end")
  if not size or size > MAX_FILE_BYTES then
    file:close()
    return map, size
  end
  file:seek("set", 0)
  for line in file:lines() do
    local key, text, frequency = line:match("^([a-z]+)\t([^\t]+)\t(%d+)$")
    if key and #text <= MAX_TEXT_BYTES then
      local list = map[key]
      if not list then
        list = {}
        map[key] = list
      end
      if #list < MAX_PER_KEY then list[#list + 1] = text end
    end
  end
  file:close()
  return map, size
end

local function refresh(env, force)
  local now = os.time()
  if not force and env.checked_at and now - env.checked_at < RECHECK_SECONDS then return end
  env.checked_at = now
  local path = env.path
  if not path then return end
  local size = file_size(path)
  if force or size ~= env.size then
    env.map, env.size = load(path)
  end
end

-- The set of bytes of `speller/delimiter` (default " '"), as table keys: matched byte by
-- byte, so no delimiter is ever read as a Lua pattern.
local function delimiter_set(env)
  local config = env.engine and env.engine.schema and env.engine.schema.config
  local delimiter = config and config:get_string("speller/delimiter") or nil
  if not delimiter or delimiter == "" then delimiter = " '" end
  local set = {}
  for index = 1, #delimiter do set[delimiter:sub(index, index)] = true end
  return set
end

-- `input` without delimiter bytes, ASCII letters lowercased.
local function lookup_key(input, delimiters)
  local key = input:gsub(".", function(byte)
    if delimiters[byte] then return "" end
  end)
  return (key:gsub("%u", string.lower))
end

local translator = {}

function translator.init(env)
  env.delimiters = delimiter_set(env)
  env.path = tsv_path()
  env.map = {}
  env.size = nil
  env.checked_at = nil
  refresh(env, true)
end

function translator.func(input, seg, env)
  refresh(env, false)
  local key = lookup_key(input, env.delimiters)
  if key == "" then return end
  local list = env.map[key]
  if not list then return end
  for _, text in ipairs(list) do
    yield(Candidate("noema_learned", seg.start, seg._end, text, ""))
  end
end

function translator.fini(env)
  env.map = nil
end

return translator

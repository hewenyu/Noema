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
--
-- The keys are full pinyin, so typed input is only a valid key on a full-pinyin schema.
-- `init` enables the translator only when the schema demonstrably is one (fail-closed,
-- see `is_full_pinyin_schema`); elsewhere (double pinyin: Xiaohe `shui` is `sang shi`;
-- Wubi, Cangjie, Zhuyin, Jyutping) it loads nothing and yields nothing, and the schema's
-- own userdb, which the guardian fills under full pinyin and the speller projects onto
-- the schema's keys, still serves the learned phrases.

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

-- Lowercase substrings of a schema ID or `translator/prism` that mark a schema whose keys
-- are not full pinyin, even one whose speller keeps the full spellings (a mixed schema
-- that only `derive`s double-pinyin codes would read `shui` both ways). `terra_pinyin`
-- is full pinyin (tone digits are optional), so it is not listed.
local NON_FULL_PINYIN_NAMES = {
  "double_pinyin", "shuangpin", "flypy", "xiaohe", "zrm", "ziranma", "mspy", "pyjj",
  "ziguang", "sogou", "wubi", "cangjie", "bopomofo", "zhuyin", "stroke", "erbi",
  "zhengma", "jyutping", "cantonese",
}

-- Standard Mandarin syllables whose initials and finals every double-pinyin layout (and
-- every Zhuyin or other key remapping) rewrites.
local PROBE_SYLLABLES = {
  "ni", "hao", "shui", "zhong", "sang", "shi", "jian", "chuan", "guang", "zhuang",
  "chang", "sheng", "qiong", "huang", "ang", "er", "ai", "ou",
}

local function has_script_translator(config)
  local list = config:get_list("engine/translators")
  if not list then return false end
  for index = 0, list.size - 1 do
    local item = list:get_value_at(index)
    local name = item and item.value or ""
    if name == "script_translator" or name:sub(1, #"script_translator@") == "script_translator@" then
      return true
    end
  end
  return false
end

local function has_non_full_pinyin_name(env, config)
  local names = { env.engine.schema.schema_id or "", config:get_string("translator/prism") or "" }
  for _, name in ipairs(names) do
    local lowered = name:lower()
    for _, marker in ipairs(NON_FULL_PINYIN_NAMES) do
      if lowered:find(marker, 1, true) then return true end
    end
  end
  return false
end

-- Whether every probe syllable, typed as is, is still a spelling after `speller/algebra`.
-- `derive`, `fuzz`, and `abbrev` keep the original spelling, so only the rules that
-- replace or drop it (`xform`, `xlit`, `erase`) are replayed, in order, through
-- librime's own `Projection` (Xiaohe: `shui` becomes `uv`, `sang` becomes `sh`). Without
-- `Projection` any such rule disables the translator.
local function speller_keeps_full_pinyin(config)
  local algebra = config:get_list("speller/algebra")
  if not algebra or algebra.size == 0 then return true end
  local replacing = {}
  for index = 0, algebra.size - 1 do
    local item = algebra:get_value_at(index)
    local rule = item and item.value
    if not rule then return false end
    local operator = rule:match("^(%a+)[^%w%s]")
    if operator == "xform" or operator == "xlit" or operator == "erase" then
      replacing[#replacing + 1] = rule
    elseif operator ~= "derive" and operator ~= "fuzz" and operator ~= "abbrev" then
      return false
    end
  end
  if #replacing == 0 then return true end
  if not (Projection and ConfigList and ConfigValue) then return false end
  local ok, keeps = pcall(function()
    local list = ConfigList()
    for _, rule in ipairs(replacing) do list:append(ConfigValue(rule).element) end
    local projection = Projection()
    if not projection:load(list) then return false end
    for _, syllable in ipairs(PROBE_SYLLABLES) do
      if projection:apply(syllable, true) ~= syllable then return false end
    end
    return true
  end)
  return ok and keeps == true
end

-- True only for a schema whose raw input spells full pinyin: a `script_translator`, no
-- non-full-pinyin name, and a speller that leaves full-pinyin syllables as they are.
local function is_full_pinyin_schema(env)
  local config = env.engine and env.engine.schema and env.engine.schema.config
  if not config then return false end
  local ok, result = pcall(function()
    return has_script_translator(config)
      and not has_non_full_pinyin_name(env, config)
      and speller_keeps_full_pinyin(config)
  end)
  return ok and result == true
end

local translator = {}

function translator.init(env)
  env.map = {}
  env.enabled = is_full_pinyin_schema(env)
  if not env.enabled then return end
  env.delimiters = delimiter_set(env)
  env.path = tsv_path()
  env.size = nil
  env.checked_at = nil
  refresh(env, true)
end

function translator.func(input, seg, env)
  if not env.enabled then return end
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

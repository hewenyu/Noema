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
-- own userdb, which the guardian fills in the dictionary's spelling (`ni hao`, or 万象's
-- toned `ní hào`) and the speller projects onto the schema's keys, still serves them.

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

-- Lowercase substrings of a schema ID, `translator/dictionary`, or `translator/prism` that mark a schema whose keys
-- are not full pinyin, even one whose speller keeps the full spellings (a mixed schema
-- that only `derive`s double-pinyin codes would read `shui` both ways). `terra_pinyin`
-- is full pinyin (tone digits are optional), so it is not listed.
local NON_FULL_PINYIN_NAMES = {
  "double_pinyin", "shuangpin", "flypy", "xiaohe", "zrm", "ziranma", "mspy", "pyjj",
  "ziguang", "sogou", "wubi", "cangjie", "bopomofo", "zhuyin", "stroke", "erbi",
  "zhengma", "jyutping", "jyut6ping3", "cantonese", "hakka", "array", "quick", "dayi",
  "kana", "hangul", "easy_en", "melt_eng", "english", "tiger", "wugniu", "soutzoe", "xingma",
}

-- Standard Mandarin syllables whose initials and finals every double-pinyin layout (and
-- every Zhuyin or other key remapping) rewrites, each with a Unicode-toned reading: a toned
-- dictionary (万象, 薄荷: `ní hào`) feeds the speller toned syllables, a toneless one plain.
local PROBE_SYLLABLES = {
  { "ni", "ní" }, { "hao", "hǎo" }, { "shui", "shuǐ" }, { "zhong", "zhōng" }, { "sang", "sāng" },
  { "shi", "shì" }, { "jian", "jiàn" }, { "chuan", "chuān" }, { "guang", "guāng" },
  { "zhuang", "zhuàng" }, { "chang", "cháng" }, { "sheng", "shēng" }, { "qiong", "qióng" },
  { "huang", "huáng" }, { "ang", "áng" }, { "er", "ér" }, { "ai", "ài" }, { "ou", "ōu" },
}

-- Spellings kept per probe syllable while replaying `speller/algebra`: bounds a pathological
-- algebra; 万象's full-pinyin algebra keeps well under it.
local MAX_FORMS = 64

-- `speller_keeps_full_pinyin` results by algebra text: the replay (a few ms on 万象's ~95
-- rules) runs once per algebra, not on every session `init`. Bounded; cleared when full.
local MAX_CACHED_ALGEBRAS = 16
local algebra_cache, cached_algebras = {}, 0

-- Whether the primary translator is an untagged `script_translator`: one is listed and no
-- untagged `table_translator` is (the primary translator of Wubi, Cangjie, Stroke, and
-- Zhengma). A tagged one (`script_translator@reverse_lookup` beside Wubi's table, or full
-- pinyin's `table_translator@custom_phrase`) never decides it.
local function has_script_translator(config)
  local list = config:get_list("engine/translators")
  if not list then return false end
  local script = false
  for index = 0, list.size - 1 do
    local item = list:get_value_at(index)
    local name = item and item.value or ""
    if name == "table_translator" then return false end
    if name == "script_translator" then script = true end
  end
  return script
end

local function has_non_full_pinyin_name(env, config)
  local names = {
    env.engine.schema.schema_id or "",
    config:get_string("translator/dictionary") or "",
    config:get_string("translator/prism") or "",
  }
  for _, name in ipairs(names) do
    local lowered = name:lower()
    for _, marker in ipairs(NON_FULL_PINYIN_NAMES) do
      if lowered:find(marker, 1, true) then return true end
    end
  end
  return false
end

-- Whether every probe syllable, typed as is, is still a spelling after `speller/algebra`.
-- Replays the algebra as librime builds a syllabary's spellings: rule by rule, in order, over
-- the set of spellings of each probe (its toneless and toned forms), each rule through its own
-- librime `Projection`. `xform` and `xlit` replace a spelling, `erase` drops the ones it
-- matches, and `derive`, `fuzz`, and `abbrev` add their result beside the original. So 万象's
-- `xform/^([a-z]+)$/$1④/` + `xlit/①②③④/7890` (`ni` becomes `ni0`) and its later
-- `derive/(.+)(\d)/$1/` (`ni` again) keep full pinyin, while Xiaohe's `xform/^sh/…/` (`shui`
-- becomes `uv`) does not. An unknown operator, or no `Projection`, disables the translator.
local function speller_keeps_full_pinyin(config)
  local algebra = config:get_list("speller/algebra")
  if not algebra or algebra.size == 0 then return true end
  local rules = {}
  for index = 0, algebra.size - 1 do
    local item = algebra:get_value_at(index)
    local rule = item and item.value
    if not rule then return false end
    local operator = rule:match("^(%a+)[^%w%s]")
    if operator ~= "xform" and operator ~= "xlit" and operator ~= "erase"
      and operator ~= "derive" and operator ~= "fuzz" and operator ~= "abbrev" then
      return false
    end
    rules[#rules + 1] = { operator = operator, rule = rule }
  end
  if not (Projection and ConfigList and ConfigValue) then return false end
  local texts = {}
  for index, entry in ipairs(rules) do texts[index] = entry.rule end
  local key = table.concat(texts, "\n")
  if algebra_cache[key] ~= nil then return algebra_cache[key] end
  local ok, keeps = pcall(function()
    for _, entry in ipairs(rules) do
      local list = ConfigList()
      list:append(ConfigValue(entry.rule).element)
      local projection = Projection()
      if not projection:load(list) then return false end
      entry.projection = projection
    end
    for _, probe in ipairs(PROBE_SYLLABLES) do
      local forms, seen = {}, {}
      for _, form in ipairs(probe) do
        if not seen[form] then
          seen[form] = true
          forms[#forms + 1] = form
        end
      end
      for _, entry in ipairs(rules) do
        local operator, projection = entry.operator, entry.projection
        local next_forms, next_seen = {}, {}
        local function keep(form)
          if form ~= "" and not next_seen[form] and #next_forms < MAX_FORMS then
            next_seen[form] = true
            next_forms[#next_forms + 1] = form
          end
        end
        for _, form in ipairs(forms) do
          local result = projection:apply(form, true)
          if operator == "xform" or operator == "xlit" then
            keep(result)
          elseif operator == "erase" then
            if result ~= "" then keep(form) end
          else
            keep(form)
            keep(result)
          end
        end
        forms = next_forms
      end
      local found = false
      for _, form in ipairs(forms) do
        if form == probe[1] then found = true end
      end
      if not found then return false end
    end
    return true
  end)
  local result = ok and keeps == true
  if cached_algebras >= MAX_CACHED_ALGEBRAS then algebra_cache, cached_algebras = {}, 0 end
  algebra_cache[key] = result
  cached_algebras = cached_algebras + 1
  return result
end

-- True only for a schema whose raw input spells full pinyin: an untagged `script_translator`
-- and no untagged `table_translator`, no
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

-- Primary tag of the main `script_translator` (default `"abc"`). Only segments carrying
-- this tag and none of the schema's secondary tags (reverse lookup, recognizer, punct)
-- receive learned full-pinyin candidates.
local function primary_tag(env)
  local config = env.engine and env.engine.schema and env.engine.schema.config
  local tag = config and config:get_string("translator/tag") or nil
  if not tag or tag == "" then return "abc" end
  return tag
end

local function secondary_tags(env, primary)
  local tags = {}
  local seen = { [primary] = true, paging = true }
  local function add(tag)
    if tag and tag ~= "" and not seen[tag] then
      seen[tag] = true
      tags[#tags + 1] = tag
    end
  end
  local config = env.engine and env.engine.schema and env.engine.schema.config
  if config then
    -- Tags attached to primary `abc` segments via `abc_segmentor/extra_tags` (such as
    -- `melt_eng` or `custom_phrase` in rime-ice/mint) legitimately coexist with `abc`.
    pcall(function()
      local extra = config:get_list("abc_segmentor/extra_tags")
      if extra then
        for index = 0, extra.size - 1 do
          local item = extra:get_value_at(index)
          local tag = item and item.value or ""
          if tag ~= "" then seen[tag] = true end
        end
      end
    end)
  end
  add("punct")
  add("reverse_lookup")
  if not config then return tags end
  pcall(function()
    add(config:get_string("reverse_lookup/tag"))
    for _, list_key in ipairs({ "engine/translators", "engine/segmentors" }) do
      local list = config:get_list(list_key)
      if list then
        for index = 0, list.size - 1 do
          local item = list:get_value_at(index)
          local name = item and item.value or ""
          local ns = name:match("@([^@]+)$")
          if ns then ns = ns:gsub("^%*", "") end
          if ns and ns ~= "" and ns ~= "noema_learned" then
            add(ns)
            add(config:get_string(ns .. "/tag"))
          end
        end
      end
    end
    local patterns = config:get_map("recognizer/patterns")
    if patterns and patterns.keys then
      for _, key in ipairs(patterns:keys()) do add(key) end
    end
  end)
  return tags
end

local translator = {}

function translator.init(env)
  env.map = {}
  env.enabled = is_full_pinyin_schema(env)
  if not env.enabled then return end
  env.primary_tag = primary_tag(env)
  env.secondary_tags = secondary_tags(env, env.primary_tag)
  env.delimiters = delimiter_set(env)
  env.path = tsv_path()
  env.size = nil
  env.checked_at = nil
  refresh(env, true)
end

function translator.func(input, seg, env)
  if not env.enabled then return end
  if not seg or not seg.has_tag or not seg:has_tag(env.primary_tag) then return end
  for _, tag in ipairs(env.secondary_tags) do
    if seg:has_tag(tag) then return end
  end
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

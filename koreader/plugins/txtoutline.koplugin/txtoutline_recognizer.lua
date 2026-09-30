--[[--
txtoutline.koplugin / recognizer.lua

Pure-Lua heading recognizer for plain-text books.

Design constraints (see README.md for the full compatibility matrix):

  * This module has **no KOReader dependency at all**. It turns an already
    decoded, LF-normalised UTF-8 string into heading candidates in document
    order. That keeps the risky part (encoding detection, crengine APIs)
    confined to adapter.lua and makes this module unit-testable with a stock
    Lua interpreter (tests/run.lua needs neither KOReader nor busted).
  * Lua 5.1 / LuaJIT compatible (KOReader runs LuaJIT): no `goto`, no integer
    division, no 5.3-only syntax.
  * Lua patterns are **byte** oriented. Multi-byte character classes such as
    `[一二三]` are therefore never used: such a class matches individual
    *bytes* of the UTF-8 sequences and produces garbage matches. The scanner
    decodes lines into an array of characters and works on that array.
  * Recognition is deliberately "balanced": a heading candidate must be a
    short, standalone line that starts with a recognised marker. We prefer
    false negatives (missed headings) over false positives (body lines
    promoted to chapters), because a wrong TOC is worse than a short one.

Recognised forms (documented extensions are marked with `+`):

  structural (semantic level 1/2/3):
    第<n>卷 / 第<n>部 / 第<n>篇 / 第<n>集 / +第<n>册   -> volume  (level 1)
    第<n>章 / +第<n>回 / +第<n>话 / +第<n>話          -> chapter (level 2)
    第<n>节 / +第<n>節                                -> section (level 3)
    <marker><n>            e.g. 卷五, 章三            (same levels as above)
  matter (front/back matter, always top level):
    序 / 序章 / 序言 / 自序 / 代序 / 译序 / 前言 / 楔子 / 引子 / 尾声 /
    终章 / 终篇 / 后记 / 番外 / 番外篇 / 附录 (+ traditional variants)
    Prologue / Epilogue / Preface / Foreword / Introduction / Afterword /
    Appendix / Interlude
  numbered English:
    Chapter|Part|Book|Volume|Section + arabic numeral or roman numeral

  Numbers: arabic, full-width arabic, Chinese numerals (incl. 零/两/兩 and the
  formal 壹贰叁… forms) and Roman numerals.
  A heading may carry a short subtitle, but it has to be separated from the
  marker by whitespace or one of `: ： . 、 - — – ·` (`allow_glued_subtitle`
  relaxes that; off by default because 第一章说到了… style run-ons are a very
  common source of false positives in Chinese TXT files).
--]]--

local Recognizer = {}

--- Bumped whenever the recognition rules or the produced item shape change.
--- cache.lua uses it to invalidate a previously stored outline.
Recognizer.VERSION = 1
Recognizer.MODE = "balanced"

-- ---------------------------------------------------------------------------
-- Tunable defaults (all overridable through the `opts` argument)
-- ---------------------------------------------------------------------------

Recognizer.DEFAULT_OPTIONS = {
    -- Maximum length (in characters, not bytes) of a line we are willing to
    -- treat as a heading. Body paragraphs in Chinese TXT files are frequently
    -- one single line, so this is the main guard against promoting prose.
    max_line_chars = 40,
    -- Maximum length of the subtitle that may follow the marker.
    max_subtitle_chars = 30,
    -- Hard cap on the number of headings produced by one scan. Beyond that the
    -- scan stops so that no pathologically formatted file (or a false
    -- positive storm) can blow up the reader.
    max_headings = 1500,
    -- Chinese novel headings often omit a separator ("第一章初入江湖").
    -- This remains limited by the standalone-line and length checks.
    allow_cjk_glued_subtitle = true,
    -- Keep English and matter headings conservative ("前言不搭后语" and
    -- "Chapter 1 was..." are prose, not headings).
    allow_glued_subtitle = false,
    -- Paragraph indentation is decided once per book. Sampling keeps cache
    -- opens cheap while still ignoring a short, unindented title/front-matter
    -- preamble before the body starts.
    indent_sample_lines = 1000,
    indent_min_lines = 20,
    indent_threshold = 0.5,
}

-- ---------------------------------------------------------------------------
-- Character constants
--
-- Explicit byte sequences (`"\239\187\191"` etc.) rather than `\u{...}`
-- escapes: some of the constants below are compared against Lua patterns, and
-- keeping them as plain literals makes it obvious that nothing in them can be
-- interpreted as a pattern class.
-- ---------------------------------------------------------------------------

local BYTE_BOM_UTF8     = "\239\187\191" -- U+FEFF
local BYTE_BOM_UTF16BE  = "\254\255"     -- U+FEFF, big endian
local BYTE_BOM_UTF16LE  = "\255\254"     -- U+FEFF, little endian
local BYTE_SOFT_HYPHEN  = "\194\173"     -- U+00AD
local BYTE_NBSP         = "\194\160"     -- U+00A0
local BYTE_IDEO_SPACE   = "\227\128\128" -- U+3000
local BYTE_FW_FULLSTOP  = "\239\188\142" -- U+FF0E
local BYTE_CJK_FULLSTOP = "\227\128\130" -- U+3002
local BYTE_FW_SEMICOLON = "\239\188\155" -- U+FF1B

Recognizer.BOM_UTF8 = BYTE_BOM_UTF8
Recognizer.BOM_UTF16BE = BYTE_BOM_UTF16BE
Recognizer.BOM_UTF16LE = BYTE_BOM_UTF16LE

-- ---------------------------------------------------------------------------
-- UTF-8 helpers
-- ---------------------------------------------------------------------------

--- Decode the character starting at byte index `i`.
--- Invalid lead bytes are treated as one-byte characters; this function is
--- only reached after Recognizer.isValidUtf8() has accepted the text.
--- @return character string|nil, next byte index
local function char_at(s, i)
    local b = s:byte(i)
    if not b then return nil, i end
    local clen
    if b < 0x80 then
        clen = 1
    elseif b < 0xC0 then
        clen = 1
    elseif b < 0xE0 then
        clen = 2
    elseif b < 0xF0 then
        clen = 3
    else
        clen = 4
    end
    if i + clen - 1 > #s then
        clen = #s - i + 1
    end
    return s:sub(i, i + clen - 1), i + clen
end

--- Split a string into an array of characters (UTF-8 aware, byte-safe).
local function utf8_split(s)
    local out, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local ch, next_i = char_at(s, i)
        n = n + 1
        out[n] = ch
        i = next_i
    end
    return out
end

--- Number of characters (Unicode code points) in a UTF-8 string.
function Recognizer.codepointCount(s)
    local n, i = 0, 1
    while i <= #s do
        local _, next_i = char_at(s, i)
        n = n + 1
        i = next_i
    end
    return n
end

--- Strict UTF-8 validator (rejects overlong forms, lone continuation bytes,
--- UTF-16 surrogate code points and out-of-range code points).
--- Used to decide whether a raw .txt file may be treated as UTF-8 at all.
function Recognizer.isValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b1 = s:byte(i + 1)
            if not b1 or b1 < 0x80 or b1 > 0xBF then return false end
            i = i + 2
        elseif b >= 0xE0 and b <= 0xEF then
            local b1, b2 = s:byte(i + 1), s:byte(i + 2)
            if not b1 or not b2 or b1 < 0x80 or b1 > 0xBF or b2 < 0x80 or b2 > 0xBF then
                return false
            end
            if b == 0xE0 and b1 < 0xA0 then return false end -- overlong
            if b == 0xED and b1 > 0x9F then return false end -- surrogates
            i = i + 3
        elseif b >= 0xF0 and b <= 0xF4 then
            local b1, b2, b3 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if not b1 or not b2 or not b3 then return false end
            if b1 < 0x80 or b1 > 0xBF or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then
                return false
            end
            if b == 0xF0 and b1 < 0x90 then return false end -- overlong
            if b == 0xF4 and b1 > 0x8F then return false end -- > U+10FFFF
            i = i + 4
        else
            return false
        end
    end
    return true
end

--- True when the string contains a NUL. For a .txt file that means "binary or
--- UTF-16", i.e. something we must not treat as UTF-8 (see adapter.lua).
function Recognizer.hasNulByte(s)
    return s:find("\0", 1, true) ~= nil
end

--- Remove a leading UTF-8 BOM (U+FEFF), if any.
function Recognizer.stripBom(s)
    if s:sub(1, 3) == BYTE_BOM_UTF8 then
        return s:sub(4)
    end
    return s
end

--- True when the string starts with a UTF-16 byte order mark.
function Recognizer.hasUtf16Bom(s)
    local head = s:sub(1, 2)
    return head == BYTE_BOM_UTF16BE or head == BYTE_BOM_UTF16LE
end

--- Normalise CRLF / CR line endings to LF.
function Recognizer.normalizeNewlines(s)
    s = s:gsub("\r\n", "\n")
    s = s:gsub("\r", "\n")
    return s
end

--- Canonical form used for TOC titles, for comparing a recognised heading with
--- the text crengine actually rendered, and as the cache key of a title.
--- Collapses whitespace runs, drops soft hyphens (crengine inserts those when
--- hyphenation is enabled) and trims.
function Recognizer.normalizeText(s)
    if not s then return "" end
    s = s:gsub(BYTE_SOFT_HYPHEN, "")
    s = s:gsub(BYTE_NBSP, " ")
    s = s:gsub(BYTE_IDEO_SPACE, " ")
    s = s:gsub("[ \t\r\n\v\f]+", " ")
    s = s:gsub("^ +", "")
    s = s:gsub(" +$", "")
    return s
end

-- ---------------------------------------------------------------------------
-- Recognised markers
-- ---------------------------------------------------------------------------

-- Structural markers: character -> { kind, level }
local STRUCT_MARKERS = {}
local function add_marker(dst, chars, kind, level)
    for _, ch in ipairs(utf8_split(chars)) do
        dst[ch] = { kind = kind, level = level }
    end
end
add_marker(STRUCT_MARKERS, "卷部篇集册", "volume", 1)
add_marker(STRUCT_MARKERS, "章回话話", "chapter", 2)
add_marker(STRUCT_MARKERS, "节節", "section", 3)

-- Front/back matter: plain words, matched longest-first. Lengths are
-- precomputed because this list is probed once per candidate line.
local MATTER_WORDS = {
    "序章", "序言", "自序", "代序", "译序", "譯序", "序",
    "前言", "楔子", "引子",
    "尾声", "尾聲", "终章", "終章", "终篇", "終篇",
    "后记", "後記", "番外篇", "番外", "附录", "附錄",
}
do
    local entries = {}
    for _, w in ipairs(MATTER_WORDS) do
        entries[#entries + 1] = { word = w, len = Recognizer.codepointCount(w) }
    end
    table.sort(entries, function(a, b)
        if a.len == b.len then return a.word < b.word end
        return a.len > b.len
    end)
    MATTER_WORDS = entries
end

-- English keywords. `standalone` means the keyword alone on a line is a valid
-- heading (that is how "Prologue" / "Introduction" normally appear); for
-- Chapter/Part/... we require a number or a subtitle.
local EN_KEYWORDS = {}
local function add_en(word, kind, level, standalone)
    EN_KEYWORDS[word] = { kind = kind, level = level, standalone = standalone and true or false }
end
add_en("chapter", "chapter", 2, false)
add_en("section", "section", 3, false)
add_en("part", "volume", 1, false)
add_en("book", "volume", 1, false)
add_en("volume", "volume", 1, false)
add_en("prologue", "matter", nil, true)
add_en("epilogue", "matter", nil, true)
add_en("preface", "matter", nil, true)
add_en("foreword", "matter", nil, true)
add_en("introduction", "matter", nil, true)
add_en("afterword", "matter", nil, true)
add_en("appendix", "matter", nil, true)
add_en("interlude", "matter", nil, true)

-- Whitespace characters, as a set of single characters.
local WS = {}
local function add_chars(dst, s)
    for _, ch in ipairs(utf8_split(s)) do dst[ch] = true end
end
add_chars(WS, " \t\n\r\v\f")
WS[BYTE_NBSP] = true
WS[BYTE_IDEO_SPACE] = true

-- Characters that may separate a marker from its subtitle.
local SEPARATOR_CHARS = {}
add_chars(SEPARATOR_CHARS, ":：.、-—–·|")

-- Characters that must not end a heading line: they signal a running sentence
-- or an empty subtitle such as "第一章：".
local TRAILING_REJECT = {}
add_chars(TRAILING_REJECT, ",，、;；:：")

-- Digits / numerals.
local DIGIT_CHARS = {}
add_chars(DIGIT_CHARS, "0123456789")
add_chars(DIGIT_CHARS, "０１２３４５６７８９")
add_chars(DIGIT_CHARS, "零〇一二三四五六七八九十百千万亿兩两")
add_chars(DIGIT_CHARS, "壹贰叁肆伍陆柒捌玖拾佰仟")

local ROMAN_CHARS = {}
add_chars(ROMAN_CHARS, "IVXLCDMivxlcdm")

-- Cheap first-character filter.
--
-- Body lines in a Chinese TXT file start with an arbitrary Chinese character,
-- so before doing any allocation we check whether the first non-whitespace
-- character can possibly begin a heading. This is what keeps a linear scan of
-- a 16 MB book cheap.
local PLAUSIBLE_FIRST = {
    ["第"] = true,
}
for ch in pairs(STRUCT_MARKERS) do PLAUSIBLE_FIRST[ch] = true end
for _, entry in ipairs(MATTER_WORDS) do
    local first = char_at(entry.word, 1)
    PLAUSIBLE_FIRST[first] = true
end
add_chars(PLAUSIBLE_FIRST, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

-- ---------------------------------------------------------------------------
-- Scanner primitives
-- ---------------------------------------------------------------------------

local function skip_ws(chars, i, last)
    while i <= last and WS[chars[i]] do
        i = i + 1
    end
    return i
end

--- Consume a run of numeral characters starting at `i`.
--- @return numeral string|nil, next index
local function consume_number(chars, i, last)
    local start = i
    while i <= last and (DIGIT_CHARS[chars[i]] or ROMAN_CHARS[chars[i]]) do
        i = i + 1
    end
    if i == start then
        return nil, start
    end
    return table.concat(chars, "", start, i - 1), i
end

--- Like consume_number(), but also accepts a single Latin letter, so that
--- "附录A" / "Appendix A" style markers work.
local function consume_number_or_letter(chars, i, last)
    local num, next_i = consume_number(chars, i, last)
    if num then
        return num, next_i
    end
    local ch = chars[i]
    if ch and #ch == 1 and ch:match("^%a$") then
        return ch, i + 1
    end
    return nil, i
end

--- Longest matter word starting at `i`.
--- @return matched word|nil, next index
local function match_matter_word(chars, i, last)
    -- MATTER_WORDS is sorted longest first, so the first hit is the longest one.
    for _, entry in ipairs(MATTER_WORDS) do
        if i + entry.len - 1 <= last then
            local candidate = table.concat(chars, "", i, i + entry.len - 1)
            if candidate == entry.word then
                return entry.word, i + entry.len
            end
        end
    end
    return nil, i
end

--- Shared "what follows the marker" handling.
--- @return subtitle string ("" when none) or nil, reason
local function consume_subtitle(chars, i, last, opts)
    local had_space = false
    while i <= last and WS[chars[i]] do
        i = i + 1
        had_space = true
    end
    local had_separator = false
    if i <= last and SEPARATOR_CHARS[chars[i]] then
        had_separator = true
        i = i + 1
        while i <= last and WS[chars[i]] do
            i = i + 1
        end
    end
    if i > last then
        return ""
    end
    if last - i + 1 > opts.max_subtitle_chars then
        return nil, "subtitle-too-long"
    end
    if not (had_space or had_separator or opts.allow_glued_subtitle) then
        return nil, "glued-subtitle"
    end
    return table.concat(chars, "", i, last)
end

-- ---------------------------------------------------------------------------
-- Matchers
-- ---------------------------------------------------------------------------

--- "第<n><marker>" (marker after the number) and "<marker><n>".
local function match_cjk_structural(chars, i, last, opts)
    local result = { kind = nil, level = nil, number = nil }

    if chars[i] == "第" then
        local j = skip_ws(chars, i + 1, last)
        local num, next_j = consume_number(chars, j, last)
        if not num then return nil end
        j = skip_ws(chars, next_j, last)
        local marker = STRUCT_MARKERS[chars[j]]
        if not marker then return nil end
        result.kind = marker.kind
        result.level = marker.level
        result.number = num
        i = j + 1
    else
        local marker = STRUCT_MARKERS[chars[i]]
        if not marker then return nil end
        local j = skip_ws(chars, i + 1, last)
        local num, next_j = consume_number(chars, j, last)
        if not num then return nil end
        result.kind = marker.kind
        result.level = marker.level
        result.number = num
        i = next_j
    end

    local subtitle_opts = opts
    if opts.allow_cjk_glued_subtitle then
        subtitle_opts = {}
        for k, v in pairs(opts) do subtitle_opts[k] = v end
        subtitle_opts.allow_glued_subtitle = true
    end
    local subtitle, reason = consume_subtitle(chars, i, last, subtitle_opts)
    if subtitle == nil then return nil, reason end
    result.subtitle = subtitle
    return result
end

--- Front/back matter words, Chinese only (English lives in match_english).
local function match_matter(chars, i, last, opts)
    local word, next_i = match_matter_word(chars, i, last)
    if not word then return nil end
    local result = { kind = "matter", level = nil, word = word }
    local num, next_i2 = consume_number_or_letter(chars, next_i, last)
    if num then
        result.number = num
        next_i = next_i2
    end
    local subtitle, reason = consume_subtitle(chars, next_i, last, opts)
    if subtitle == nil then return nil, reason end
    result.subtitle = subtitle
    return result
end

--- "Chapter 12: ...", "Part I", "Prologue", "Appendix A", ...
local function match_english(chars, i, last, opts)
    local j = i
    while j <= last and chars[j]:match("^%a$") do
        j = j + 1
    end
    if j == i then return nil end
    local word = table.concat(chars, "", i, j - 1):lower()
    local keyword = EN_KEYWORDS[word]
    if not keyword then return nil end
    -- An optional '.' right after the keyword ("Part. I") is tolerated.
    if j <= last and chars[j] == "." then
        j = j + 1
    end
    -- The keyword must be a whole word: the next character has to be
    -- whitespace, a separator or end of line. This rejects "Chapters are ...".
    if j <= last and not WS[chars[j]] and not SEPARATOR_CHARS[chars[j]] then
        return nil
    end

    local saw_separator = false
    while j <= last and WS[chars[j]] do
        j = j + 1
    end
    if j <= last and SEPARATOR_CHARS[chars[j]] then
        saw_separator = true
        j = j + 1
        while j <= last and WS[chars[j]] do
            j = j + 1
        end
    end

    local number
    -- consume_number_or_letter() so that "Appendix B" reports B as the
    -- number; the boundary guard below rejects a letter that is really the
    -- first letter of a subtitle word.
    local num, next_j = consume_number_or_letter(chars, j, last)
    if num and (next_j > last or WS[chars[next_j]] or SEPARATOR_CHARS[chars[next_j]]) then
        number = num
        j = next_j
        while j <= last and WS[chars[j]] do
            j = j + 1
        end
        if j <= last and SEPARATOR_CHARS[chars[j]] then
            saw_separator = true
            j = j + 1
            while j <= last and WS[chars[j]] do
                j = j + 1
            end
        end
    end

    local subtitle = ""
    if j <= last then
        if last - j + 1 > opts.max_subtitle_chars then
            return nil, "subtitle-too-long"
        end
        -- Without a separator, an English tail is overwhelmingly likely to be
        -- a sentence continuation ("Chapter 1 was the first ..."). Requiring a
        -- separator or a capitalised start keeps those out.
        if not saw_separator and not opts.allow_glued_subtitle then
            local first = chars[j]
            local capitalised = first:match("^[A-Z]$") or first:match("^[0-9]$")
                or first == "\"" or first == "'" or first == "("
                or first:byte(1) >= 0x80 -- CJK / other non-ASCII
            if not capitalised then
                return nil, "english-subtitle"
            end
        end
        subtitle = table.concat(chars, "", j, last)
    end

    if not number and subtitle == "" and not keyword.standalone then
        return nil, "english-incomplete"
    end

    return {
        kind = keyword.kind,
        level = keyword.level,
        number = number,
        word = word,
        subtitle = subtitle,
    }
end

-- Try each matcher in turn, keeping the most specific rejection reason
-- (the first non-nil one) for the diagnostic counters.
local MATCHERS = { match_cjk_structural, match_matter, match_english }

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Merge caller options over DEFAULT_OPTIONS.
function Recognizer.withDefaults(opts)
    local o = {}
    for k, v in pairs(Recognizer.DEFAULT_OPTIONS) do o[k] = v end
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end
    return o
end

--- Try to recognise one raw text line as a heading.
--- @param line string a single line, without its newline
--- @param opts table|nil a table produced by Recognizer.withDefaults()
--- @return heading table|nil, reason string
---         The heading table contains: kind, level, number, subtitle, title,
---         normalized_title, raw, char_count.
function Recognizer.matchLine(line, opts)
    opts = opts or Recognizer.DEFAULT_OPTIONS

    -- Cheap byte-level trim first (ASCII whitespace only) so that obviously
    -- long prose lines are rejected without any allocation.
    local s = line:gsub("^[ \t\r\n\v\f]+", ""):gsub("[ \t\r\n\v\f]+$", "")
    if s == "" then return nil, "empty" end
    if #s > opts.max_line_chars * 4 then return nil, "too-long" end

    -- Skip leading whitespace character-aware (ideographic / NBSP spaces) and
    -- apply the plausible-first-character filter.
    local i = 1
    local first_ch, next_i = char_at(s, i)
    while first_ch and WS[first_ch] do
        i = next_i
        first_ch, next_i = char_at(s, i)
    end
    if not first_ch then return nil, "empty" end
    if not PLAUSIBLE_FIRST[first_ch] then return nil, "implausible" end

    local chars = utf8_split(s:sub(i))
    local first, last = 1, #chars
    while last >= first and WS[chars[last]] do last = last - 1 end
    if first > last then return nil, "empty" end

    local char_count = last - first + 1
    if char_count > opts.max_line_chars then
        return nil, "too-long"
    end

    local raw = table.concat(chars, "", first, last)
    -- A full stop or a semicolon anywhere means we are looking at prose, not at
    -- a heading ("第一章说到了。"). Cheap and very effective.
    if raw:find(BYTE_CJK_FULLSTOP, 1, true) or raw:find(BYTE_FW_FULLSTOP, 1, true)
        or raw:find(";", 1, true) or raw:find(BYTE_FW_SEMICOLON, 1, true) then
        return nil, "sentence"
    end
    if TRAILING_REJECT[chars[last]] then
        return nil, "trailing-punctuation"
    end

    -- Try each matcher in turn, keeping the most specific rejection reason
    -- (the first non-nil one) for the diagnostic counters.
    local matched, reason
    for _, matcher in ipairs(MATCHERS) do
        local m, r = matcher(chars, first, last, opts)
        if m then
            matched = m
            break
        end
        reason = reason or r
    end
    if not matched then
        return nil, reason or "no-match"
    end

    matched.raw = raw
    matched.char_count = char_count
    matched.title = Recognizer.normalizeText(raw)
    matched.normalized_title = matched.title
    return matched
end

--- Decide whether CSS should add a first-line indent for this book.
--- Samples non-empty, non-heading lines and treats ASCII, tab, NBSP and
--- ideographic space as source indentation.
--- @return add_indent boolean, stats table
function Recognizer.analyzeIndentation(text, opts)
    opts = Recognizer.withDefaults(opts)
    local stats = { sampled = 0, indented = 0, ratio = 0 }
    if type(text) ~= "string" or text == "" then
        return true, stats
    end

    local pos, len = 1, #text
    while pos <= len and stats.sampled < opts.indent_sample_lines do
        local nl = text:find("\n", pos, true)
        local line
        if nl then
            line = text:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = text:sub(pos)
            pos = len + 1
        end

        local normalized = Recognizer.normalizeText(line)
        if normalized ~= "" and not Recognizer.matchLine(line, opts) then
            stats.sampled = stats.sampled + 1
            local first = char_at(line, 1)
            if first == " " or first == "\t" or first == BYTE_NBSP
                or first == BYTE_IDEO_SPACE then
                stats.indented = stats.indented + 1
            end
        end
    end

    if stats.sampled > 0 then
        stats.ratio = stats.indented / stats.sampled
    end
    if stats.sampled < opts.indent_min_lines then
        return true, stats
    end
    return stats.ratio < opts.indent_threshold, stats
end

--- Scan a whole document body.
--- @param text string decoded, LF-normalised UTF-8 text
--- @param opts table|nil
--- @return items array of heading items in document order,
---         stats table with diagnostic counters
function Recognizer.scan(text, opts)
    opts = Recognizer.withDefaults(opts)
    local items = {}
    local stats = {
        lines = 0,
        candidates = 0,
        truncated = false,
        rejected = {
            ["too-long"] = 0,
            ["sentence"] = 0,
            ["trailing-punctuation"] = 0,
            ["subtitle-too-long"] = 0,
            ["glued-subtitle"] = 0,
            ["english-subtitle"] = 0,
            ["english-incomplete"] = 0,
        },
    }
    if type(text) ~= "string" or text == "" then
        Recognizer.assignDepths(items)
        return items, stats
    end

    local pos = 1
    local len = #text
    while pos <= len do
        local nl = text:find("\n", pos, true)
        local line
        if nl then
            line = text:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = text:sub(pos)
            pos = len + 1
        end
        stats.lines = stats.lines + 1

        local item, reason = Recognizer.matchLine(line, opts)
        if item then
            if stats.candidates >= opts.max_headings then
                stats.truncated = true
                break
            end
            stats.candidates = stats.candidates + 1
            item.line_no = stats.lines -- diagnostics only, never used as xpointer
            items[#items + 1] = item
        elseif reason and stats.rejected[reason] then
            stats.rejected[reason] = stats.rejected[reason] + 1
        end
    end

    Recognizer.assignDepths(items)
    return items, stats
end

--- Map the semantic levels produced by the matchers onto contiguous depths
--- 1..k (k <= 3).
---
--- "Missing levels are compressed, no virtual nodes are invented": a book that
--- only has 章/节 must not end up with a level-2 root above an empty level 1,
--- so the used levels {2,3} become {1,2}. Front/back matter items are always
--- depth 1, which also means that in a chapters-only book 序章/尾声 end up
--- flat next to the chapters instead of becoming their parent.
function Recognizer.assignDepths(items)
    local present = {}
    local max_level = 0
    for _, item in ipairs(items) do
        local lvl = item.level
        if lvl then
            present[lvl] = true
            if lvl > max_level then max_level = lvl end
        end
    end
    local map = {}
    local k = 0
    for lvl = 1, max_level do
        if present[lvl] then
            k = k + 1
            map[lvl] = k
        end
    end
    for _, item in ipairs(items) do
        if item.level then
            item.depth = map[item.level] or 1
        else
            item.depth = 1
        end
        -- Depth is what KOReader consumes; level/kind stay around for
        -- diagnostics and for the cache signature.
        if item.depth > 3 then item.depth = 3 end
    end
    return map
end

--- Summary used by the plugin's status dialog and by the log line.
function Recognizer.summarizeKinds(items)
    local counts = {}
    for _, item in ipairs(items) do
        local key = item.kind or "unknown"
        counts[key] = (counts[key] or 0) + 1
    end
    return counts
end

return Recognizer

--[[--
txtoutline.koplugin / adapter.lua

The *only* module of this plugin that talks to KOReader. Everything risky
(encoding detection, crengine text search, DOM probing) lives here so that the
compatibility surface is small and reviewable.

API basis (audited against the KOReader source tree; see README.md for the
exact files/lines):

  document.file                                   -- path of the opened document
  document.is_txt                                 -- set in ReaderUI:extendProvider()
  document:getDocumentFileContent(path)           -- crengine file reader (optional)
  document:findAllText(pattern, case_insensitive, nb_context_words, max_hits,
                       regex, search_flags)
                                                  -- CreDocument:findAllText()
                                                     returns { idx, start, ["end"],
                                                               matched_text, ... }
  document:getAndClearRegexSearchError()          -- 0 == ok
  document:getPageFromXPointer(xp)                -- xpointer -> page number
  document:getNormalizedXPointer(xp)              -- false when xp is stale/unknown
  document:getHTMLFromXPointer(xp, flags, from_final_parent)
                                                  -- read-only DOM access; used to
                                                     verify what the heading line
                                                     actually is, and to check that
                                                     a search hit is the heading and
                                                     not a prose mention
  document:setStyleSheet(css_file, appended_css)  -- document-wide only

Compatibility boundaries (deliberate, see README.md for the rationale):

  * There is **no** KOReader/crengine Lua API to re-tag a node or assign it a
    class. getHTMLFromXPointer() is read-only and setStyleSheet() is document-wide.
    For presentation only, the plugin converts normalized XPointers into exact
    structural selectors (`:nth-of-type`) and appends those rules to the active
    stylesheet. If an XPointer cannot be converted safely, that node is not
    styled; it never falls back to a broad `p` or `pre` selector.
  * Encoding: crengine is asked to read the file first. If the raw bytes have to
    be read by us they are accepted as UTF-8 (with or without BOM), or handed to
    the system ICU as GB2312/GBK/GB18030 when they are not valid UTF-8 (see
    charset.lua); UTF-16 is still detected and skipped, with a log line. A wrong
    guess cannot produce a silently wrong TOC: the recognised titles are matched
    against crengine's own decoded DOM text further down, so a mis-decoded
    heading simply fails to map instead of pointing somewhere wrong.
  * Every search/probe call is pcall'ed: a KOReader build without the API makes
    the plugin skip that step instead of breaking the reader.
--]]--

local logger = require("logger")

local Recognizer = require("txtoutline_recognizer")
local Charset = require("txtoutline_charset")

local Adapter = {}

-- ---------------------------------------------------------------------------
-- Bounds
-- ---------------------------------------------------------------------------

Adapter.DEFAULT_READ_LIMITS = {
    -- Largest .txt file we are willing to pull into memory. 16 MB of UTF-8 is
    -- roughly 5 million CJK characters; the scan itself is linear (measured at
    -- well under a second for 47 MB / 400k lines), so this bound exists to cap
    -- peak memory rather than CPU.
    max_bytes = 16 * 1024 * 1024,
    -- Non-UTF-8 bytes are decoded by the system ICU (charset.lua). A file whose
    -- decode needs more replacement characters than this fraction of its size is
    -- not treated as that code page at all (wrong guessing, binary data) and is
    -- skipped like before.
    max_replacement_ratio = 0.02,
    -- Converter name for those files. "gb18030" is a superset of GBK and GB2312,
    -- so one name covers every Chinese TXT seen so far.
    legacy_cjk_encoding = "gb18030",
}

Adapter.DEFAULT_SEARCH_OPTIONS = {
    -- Number of title alternatives packed into one regex. Bigger batches mean
    -- fewer full-document scans; the value is halved automatically whenever
    -- crengine reports "regex too complex".
    batch_size = 200,
    -- Upper bound on full-document searches. Large batches dramatically reduce
    -- repeated full-book scans on e-ink hardware; regex failures automatically
    -- halve the batch until the engine accepts it.
    max_batches = 60,
    max_hits = 5000,
    case_insensitive = true,
    -- See the search flag list in readerfrontend
    -- apps/reader/modules/readersearch.lua:
    --   MATCH_ACROSS_TEXT_NODES     = 0x0001 (deliberately disabled below)
    --   COLLAPSE_CONSECUTIVE_SPACES = 0x0002
    --   IGNORE_FORMAT_CONTROL_CHARS = 0x0010
    --   FOLD_SPACES                 = 0x0020
    -- (NORMALIZE_* are deliberately not used: they would rewrite the matched
    -- text and make the hit -> title correlation guesswork.)
    -- Keep regex matching inside one text node. A title is required to be a
    -- standalone source line, so matching across nodes only creates ambiguous
    -- ranges and can turn nearby prose into a false hit.
    search_flags = 0x0002 + 0x0010 + 0x0020,
    nb_context_words = 0,
}

Adapter.DEFAULT_BLOCK_OPTIONS = {
    -- 0x1001 == "purest HTML, no CSS, soft hyphens added, dir/lang from
    -- parents" (see frontend/apps/reader/modules/readerlink.lua, which uses the
    -- same flag set for footnote rendering).
    html_flags = 0x1001,
    -- A block bigger than this means the DOM has no per-paragraph structure we
    -- can use (a preformatted TXT file is one huge <pre> node), so we stop
    -- probing instead of pulling the whole book into a Lua string.
    max_html_chars = 1024,
    -- Hard cap on DOM probes per analysis run.
    max_checks = 2000,
}

local function merge(defaults, opts)
    local o = {}
    for k, v in pairs(defaults) do o[k] = v end
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end
    return o
end

-- ---------------------------------------------------------------------------
-- Document selection
-- ---------------------------------------------------------------------------

--- True when this document is a plain .txt book handled by crengine.
--- `document.is_txt` is set by ReaderUI:extendProvider() from the file
--- extension; we additionally accept the case where only the path is useful, so
--- that the plugin still works if a KOReader build stops setting the flag.
function Adapter.isPlainTxt(document)
    if not document then return false end
    if document.is_txt then return true end
    local path = document.file
    if type(path) == "string" then
        return path:lower():match("%.txt$") ~= nil
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Reading the source text
-- ---------------------------------------------------------------------------

--- Decode raw file bytes. Only UTF-8 is accepted.
--- @return text|nil, reason|nil
function Adapter.decodeBytes(bytes, limits)
    limits = merge(Adapter.DEFAULT_READ_LIMITS, limits)
    if type(bytes) ~= "string" or #bytes == 0 then
        return nil, "empty"
    end
    if Recognizer.hasUtf16Bom(bytes) then
        return nil, "utf16-bom"
    end
    local body = Recognizer.stripBom(bytes)
    if Recognizer.hasNulByte(body) then
        -- Either UTF-16 without a BOM or a binary file. Either way we cannot
        -- reliably decode it here, and guessing would corrupt the search
        -- strings, so skip.
        return nil, "nul-byte"
    end
    if not Recognizer.isValidUtf8(body) then
        -- Typical for GB2312/GBK/GB18030 TXT files: hand the bytes to the
        -- system ICU. A mis-decode is safe by construction -- searchTitles()
        -- only keeps titles that crengine's decoded DOM really contains, so a
        -- wrong guess drops headings instead of misplacing them.
        local text, reason, stats = Charset.decode(body, limits.legacy_cjk_encoding)
        if not text then
            logger.dbg("txtoutline: legacy CJK decode unavailable:", reason)
            return nil, "not-utf8"
        end
        local replacements = Charset.countReplacements(text)
        if replacements > #body * limits.max_replacement_ratio then
            logger.warn("txtoutline: " .. replacements .. " replacement characters in "
                .. #body .. " bytes, not treating the file as " .. limits.legacy_cjk_encoding)
            return nil, "not-utf8"
        end
        logger.info("txtoutline: decoded " .. #body .. " bytes as " .. limits.legacy_cjk_encoding
            .. " (" .. (stats and stats.symbol or "?") .. ", " .. replacements
            .. " replacement characters)")
        return Recognizer.normalizeNewlines(text), nil
    end
    return Recognizer.normalizeNewlines(body), nil
end

--- Obtain the book text as decoded UTF-8 with LF line endings.
---
--- Order of preference:
---   1. document:getDocumentFileContent(path) -- crengine's own reader. It uses
---      the exact same decoding pipeline that produced the rendered text, so
---      its output is guaranteed to be searchable.
---   2. Raw byte read + strict UTF-8 validation (BOM and CRLF handled here).
---
--- @return text|nil, source|nil, reason|nil
function Adapter.readSourceText(document, limits)
    limits = merge(Adapter.DEFAULT_READ_LIMITS, limits)
    local path = document and document.file
    if type(path) ~= "string" or path == "" then
        return nil, nil, "no-file-path"
    end

    -- Check size before either read path so getDocumentFileContent() cannot
    -- accidentally copy an unbounded book into Lua memory.
    local f = io.open(path, "rb")
    if not f then
        return nil, nil, "open-failed"
    end
    local size = f:seek("end")
    f:seek("set", 0)
    if not size or size <= 0 then
        f:close()
        return nil, nil, "empty"
    end
    if size > limits.max_bytes then
        f:close()
        return nil, nil, "too-large"
    end

    if type(document.getDocumentFileContent) == "function" then
        local ok, content = pcall(document.getDocumentFileContent, document, path)
        if ok and type(content) == "string" and #content > 0
            and not Recognizer.hasUtf16Bom(content)
            and not Recognizer.hasNulByte(content)
            and Recognizer.isValidUtf8(content) then
            f:close()
            return Recognizer.normalizeNewlines(Recognizer.stripBom(content)), "crengine"
        end
        logger.dbg("txtoutline: crengine file reader unusable, falling back to raw read",
            ok and "inconclusive-content" or tostring(content))
    end
    local bytes = f:read(size)
    f:close()
    if type(bytes) ~= "string" then
        return nil, nil, "read-failed"
    end
    local text, reason = Adapter.decodeBytes(bytes, limits)
    if not text then
        return nil, nil, reason
    end
    return text, "raw", nil
end

-- ---------------------------------------------------------------------------
-- Title -> xpointer mapping
-- ---------------------------------------------------------------------------

-- Characters that must be escaped to make a title a literal regex.
-- `-` and `/` are intentionally left alone: they are literal in both Lua
-- patterns and crengine's SRELL patterns, while an unnecessary `\/` is a
-- needless risk of a "bad escape" error on an older engine.
local PATTERN_SPECIALS = {
    ["\\"] = true, ["^"] = true, ["$"] = true, ["."] = true,
    ["*"] = true, ["+"] = true, ["?"] = true, ["("] = true,
    [")"] = true, ["["] = true, ["]"] = true, ["{"] = true,
    ["}"] = true, ["|"] = true,
}

-- findAllText(..., regex=true) uses SRELL/ECMAScript syntax, not Lua patterns.
local function escape_pattern(s)
    local out = {}
    local i = 1
    while i <= #s do
        local byte = s:byte(i)
        local length = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
        local ch = s:sub(i, i + length - 1)
        out[#out + 1] = PATTERN_SPECIALS[ch] and ("\\" .. ch) or ch
        i = i + length
    end
    return table.concat(out)
end
Adapter.escapePattern = escape_pattern

--- Run one findAllText() and return its hits, or nil + reason.
local function find_all_text(document, pattern, opts)
    local ok, result = pcall(document.findAllText, document,
        pattern, opts.case_insensitive, opts.nb_context_words,
        opts.max_hits, true, opts.search_flags)
    if not ok then
        return nil, "call-failed"
    end
    if type(document.getAndClearRegexSearchError) == "function" then
        local ok_err, err_code = pcall(document.getAndClearRegexSearchError, document)
        if ok_err and err_code and err_code ~= 0 then
            return nil, "regex-error-" .. tostring(err_code)
        end
    end
    if type(result) ~= "table" then
        return {}, nil
    end
    return result, nil
end

--- Map a list of titles to xpointers through the document search API.
---
--- Titles are searched in batches: one regex `(title1|title2|...)` per batch,
--- so a 500 chapter book costs ~13 full-document scans instead of 500. Hits are
--- grouped by their matched text, which lets repeated titles be disambiguated
--- by occurrence order (requirement: duplicate headings must not collapse).
---
--- @param titles array of { title = <display/normalized title>, key = <normalized title> }
--- @return hits_by_key table key -> ordered array of
---         { xpointer, end_xpointer, page, ordinal }, stats table
function Adapter.searchTitles(document, titles, opts)
    opts = merge(Adapter.DEFAULT_SEARCH_OPTIONS, opts)
    local hits_by_key = {}
    local stats = {
        batches = 0,
        searches_failed = 0,
        titles_searched = 0,
        hits = 0,
        duplicates_dropped = 0,
        unavailable = false,
    }

    if type(document.findAllText) ~= "function" then
        stats.unavailable = true
        return hits_by_key, stats
    end
    if type(titles) ~= "table" or #titles == 0 then
        return hits_by_key, stats
    end

    -- Deduplicate: one alternative per distinct normalized title.
    local keys = {}
    local batch_size = opts.batch_size
    local i = 1
    local batches = 0
    while i <= #titles do
        if batches >= opts.max_batches then
            logger.warn("txtoutline: search batch limit reached, ignoring remaining titles")
            break
        end
        local chunk = {}
        local j = i
        while j <= #titles and #chunk < batch_size do
            local key = titles[j].key
            if not keys[key] then
                keys[key] = true
                chunk[#chunk + 1] = key
            end
            j = j + 1
        end
        if #chunk == 0 then
            -- Every title in this window was already searched; advance.
            i = j > i and j or (i + 1)
        else
            -- Longest alternative first: SRELL alternation is leftmost-first, so
            -- "第一章 归来" has to be tried before "第一章" or the shorter
            -- alternative would swallow the longer match.
            table.sort(chunk, function(a, b)
                if #a == #b then return a < b end
                return #a > #b
            end)
            local escaped = {}
            for n = 1, #chunk do
                escaped[n] = escape_pattern(chunk[n])
            end
            local pattern = "(" .. table.concat(escaped, "|") .. ")"

            local result, reason = find_all_text(document, pattern, opts)
            batches = batches + 1
            stats.batches = batches
            if not result then
                stats.searches_failed = stats.searches_failed + 1
                logger.dbg("txtoutline: search batch failed:", reason, "batch size", batch_size)
                if batch_size > 1 then
                    -- "Expression too complex": retry the same window with
                    -- smaller batches.
                    batch_size = math.max(1, math.floor(batch_size / 2))
                    -- Un-mark the keys so the retry includes them again.
                    for n = 1, #chunk do
                        keys[chunk[n]] = nil
                    end
                else
                    -- Even a single literal failed: give up on this window.
                    i = j
                end
            else
                stats.titles_searched = stats.titles_searched + #chunk
                for _, hit in ipairs(result) do
                    local matched = hit.matched_text
                    local key = matched and Recognizer.normalizeText(matched) or nil
                    if key and keys[key] and type(hit.start) == "string" then
                        local bucket = hits_by_key[key]
                        if not bucket then
                            bucket = {}
                            hits_by_key[key] = bucket
                        end
                        bucket[#bucket + 1] = {
                            xpointer = hit.start,
                            end_xpointer = hit["end"],
                            page = nil, -- filled in below
                            ordinal = #bucket + 1,
                        }
                    end
                end
                i = j
            end
        end
    end

    -- findAllText returns each bucket in document order. Do not ask for page
    -- numbers here: this runs during PreRenderDocument, before layout exists.
    -- Pages are filled after rendering in main.lua:onReaderReady().
    local total = 0
    for key, bucket in pairs(hits_by_key) do
        local seen = {}
        -- Drop exact duplicate xpointers (can happen when a title matches two
        -- alternatives in the same batch).
        local deduped = {}
        for _, hit in ipairs(bucket) do
            if not seen[hit.xpointer] then
                seen[hit.xpointer] = true
                deduped[#deduped + 1] = hit
                total = total + 1
            else
                stats.duplicates_dropped = stats.duplicates_dropped + 1
            end
        end
        hits_by_key[key] = deduped
    end
    stats.hits = total
    return hits_by_key, stats
end

-- ---------------------------------------------------------------------------
-- DOM probing (read-only)
-- ---------------------------------------------------------------------------

--- Convert a fragment of crengine HTML into comparable plain text.
function Adapter.htmlToText(html)
    local s = html:gsub("<[^>]*>", " ")
    s = s:gsub("&nbsp;", " "):gsub("&#160;", " ")
    s = s:gsub("&shy;", ""):gsub("&#173;", "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&apos;", "'")
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        if n and n < 256 then return string.char(n) end
        return ""
    end)
    s = s:gsub("&amp;", "&")
    return Recognizer.normalizeText(s)
end

--- Read the enclosing block of an xpointer. Read-only.
---
--- @return table|nil with fields:
---   too_large = true         -- the block is too big to be a single paragraph
---   tag                      -- name of the outermost element, e.g. "p", "h1"
---   text                     -- normalized text content
---   html                     -- raw HTML (for logging/debugging)
function Adapter.getBlockInfo(document, xpointer, opts)
    opts = merge(Adapter.DEFAULT_BLOCK_OPTIONS, opts)
    if type(document.getHTMLFromXPointer) ~= "function" then
        return nil
    end
    if type(xpointer) ~= "string" then
        return nil
    end
    local ok, html = pcall(document.getHTMLFromXPointer, document, xpointer, opts.html_flags, true)
    if not ok or type(html) ~= "string" or html == "" then
        return nil
    end
    if #html > opts.max_html_chars then
        -- Typical for a preformatted TXT document: the whole book is one node,
        -- so there is no per-line DOM structure to inspect. Report it once and
        -- let the caller stop probing.
        return { too_large = true }
    end
    return {
        tag = html:match("<%s*([%w]+)"),
        text = Adapter.htmlToText(html),
        html = html,
    }
end

--- Discard hits whose enclosing DOM block is not actually the heading text.
---
--- This is the cheapest way to keep prose mentions ("在第一章中，我们…" whose
--- block happens to contain the phrase) from shifting the occurrence counter.
--- If the DOM has no usable block structure the function is a no-op. Once DOM
--- probing is available, uncertain hits are dropped: a missing item is safer
--- than a TOC entry that jumps into an arbitrary prose mention.
function Adapter.validateHits(document, hits_by_key, opts)
    opts = merge(Adapter.DEFAULT_BLOCK_OPTIONS, opts)
    local stats = { checked = 0, kept = 0, dropped = 0, unavailable = false, fallbacks = 0 }
    if type(document.getHTMLFromXPointer) ~= "function" then
        stats.unavailable = true
        return stats
    end
    for key, bucket in pairs(hits_by_key) do
        if stats.checked >= opts.max_checks then
            stats.unavailable = true
            break
        end
        local kept = {}
        for _, hit in ipairs(bucket) do
            if stats.checked >= opts.max_checks then
                -- Out of budget: keep the rest untouched rather than guessing.
                kept[#kept + 1] = hit
            else
                local info = Adapter.getBlockInfo(document, hit.xpointer, opts)
                if info and info.too_large then
                    stats.unavailable = true
                    kept[#kept + 1] = hit
                else
                    stats.checked = stats.checked + 1
                    if info and info.text == key then
                        kept[#kept + 1] = hit
                    else
                        stats.dropped = stats.dropped + 1
                    end
                end
            end
        end
        hits_by_key[key] = kept
        stats.kept = stats.kept + #kept
        if stats.unavailable then break end
    end
    return stats
end

--- Annotate TOC items with the real DOM element that crengine rendered for
--- them, and count how many already are real heading elements.
---
--- This is the honest version of "apply h1/h2/h3 styling": we report what the
--- document actually contains instead of pretending to change it. See
--- applyHeadingStyles() below.
function Adapter.inspectHeadingTags(document, items, opts)
    opts = merge(Adapter.DEFAULT_BLOCK_OPTIONS, opts)
    local stats = { checked = 0, heading_tags = 0, tags = {}, unavailable = false }
    if type(document.getHTMLFromXPointer) ~= "function" then
        stats.unavailable = true
        return stats
    end
    for _, item in ipairs(items) do
        if stats.checked >= opts.max_checks then break end
        local info = Adapter.getBlockInfo(document, item.xpointer, opts)
        if info and info.too_large then
            -- Preformatted TXT: the whole book is one node, so "is this a
            -- heading element?" has no per-line answer. Stop probing.
            stats.unavailable = true
            break
        end
        if info then
            stats.checked = stats.checked + 1
            item.dom_tag = info.tag
            if info.tag and info.tag:match("^h[1-6]$") then
                stats.heading_tags = stats.heading_tags + 1
                stats.tags[info.tag] = (stats.tags[info.tag] or 0) + 1
            end
        end
    end
    return stats
end

-- ---------------------------------------------------------------------------
-- Heading visual style
-- ---------------------------------------------------------------------------

-- Convert a normalized crengine XPointer such as
-- /FictionBook/body[1]/pre[42]/text()[1].0 into an exact structural selector.
-- XPointer indices count siblings of the same element type, which maps to
-- :nth-of-type(). Text nodes and character offsets are intentionally omitted.
function Adapter.xpointerToSelector(xpointer)
    if type(xpointer) ~= "string" or xpointer == "" then return nil end
    local parts = {}
    for segment in xpointer:gmatch("/([^/]+)") do
        segment = segment:gsub("%.%-?%d+$", "")
        if not segment:match("^text%(%)") then
            local name, index = segment:match("^([%w_:%-]+)%[(%d+)%]$")
            if not name then name = segment:match("^([%w_:%-]+)$") end
            if not name then return nil end
            -- The synthetic FictionBook root is not useful in selectors.
            if name:lower() ~= "fictionbook" then
                local selector = name
                if index then selector = selector .. ":nth-of-type(" .. index .. ")" end
                parts[#parts + 1] = selector
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " > ")
end

local HEADING_LEFT_BAR = "text-align: left !important; border-left: 0.18em solid currentColor !important; padding-left: 0.5em !important;"
local LEVEL_STYLE = {
    -- Match KOReader's built-in EPUB/TXT stylesheet: top two heading levels
    -- start on a fresh page, while lower-level sections stay in flow. TXT
    -- headings also mirror styletweaks/heading_left_bar.css because their real
    -- DOM nodes are <pre> and therefore cannot match its h1...h9 selector.
    [1] = "font-size: 1.5em; font-weight: bold; text-indent: 0; margin-top: 1em; margin-bottom: 0.6em; page-break-before: always; page-break-after: avoid; " .. HEADING_LEFT_BAR,
    [2] = "font-size: 1.3em; font-weight: bold; text-indent: 0; margin-top: 0.8em; margin-bottom: 0.5em; page-break-before: always; page-break-after: avoid; " .. HEADING_LEFT_BAR,
    [3] = "font-size: 1.15em; font-weight: bold; text-indent: 0; margin-top: 0.7em; margin-bottom: 0.4em; page-break-after: avoid; " .. HEADING_LEFT_BAR,
}

--- Build CSS that targets only the exact DOM elements containing mapped
--- headings. This does not mutate tags, but gives them h1/h2/h3-like visuals.
--- If an XPointer cannot be converted safely, that item is left unstyled.
function Adapter.buildHeadingCss(items)
    local by_depth, seen = { {}, {}, {} }, {}
    for _, item in ipairs(items or {}) do
        local depth = math.max(1, math.min(3, tonumber(item.depth) or 1))
        local selector = Adapter.xpointerToSelector(item.xpointer)
        if selector and not seen[selector] then
            seen[selector] = true
            by_depth[depth][#by_depth[depth] + 1] = selector
        end
    end
    local rules, count = {}, 0
    for depth = 1, 3 do
        if #by_depth[depth] > 0 then
            rules[#rules + 1] = table.concat(by_depth[depth], ",\n")
                .. " { " .. LEVEL_STYLE[depth] .. " }"
            count = count + #by_depth[depth]
        end
    end
    return table.concat(rules, "\n"), count
end

--- Apply exact-node heading CSS alongside the user's current style tweaks.
function Adapter.applyHeadingStyles(document, items, base_css, existing_tweaks)
    if type(document.setStyleSheet) ~= "function" then
        return false, "no-stylesheet-api"
    end
    local css, count = Adapter.buildHeadingCss(items)
    if count == 0 then return false, "no-safe-selectors" end
    local appended = existing_tweaks or ""
    if appended ~= "" then appended = appended .. "\n" end
    appended = appended .. css
    local ok, err = pcall(document.setStyleSheet, document, base_css, appended)
    if not ok then return false, tostring(err) end
    return true, count, css
end

return Adapter

--[[--
txtoutline.koplugin / cache.lua

Optional per-book cache of the computed outline.

The outline is stored in KOReader's per-document sidecar settings
(`self.ui.doc_settings`, i.e. the `<book>.sdr/metadata.*.lua` file). The `.txt`
source file is never written to -- that is a hard requirement of this plugin.

Why a cache at all: turning the recognised titles into xpointers costs a handful
of full-document crengine searches. Re-opening a big book would pay that cost
again, so the resulting item list is stored and reused when nothing relevant
changed.

Safety rules (a stale cache must never produce a wrong TOC):

  * The cache is only used when its signature matches. The signature covers the
    plugin/recognizer versions, the file size and mtime, the TXT preformatting
    setting and the requested crengine DOM version.
  * Cached xpointers are trusted when the complete signature matches. The
    signature already covers every input that can change the TXT DOM; probing
    hundreds of xpointers one by one made cache hits slower than loading the
    book itself on e-ink devices.
  * Page numbers are never cached: they depend on the current font/margin
    settings and are always recomputed from the live document.
  * When `libs/libkoreader-lfs` is unavailable, the cache is skipped and the
    plugin falls back to a full scan.
--]]--

local Recognizer = require("txtoutline_recognizer")

local Cache = {}

--- Bump when the stored item shape changes.
Cache.VERSION = 1
Cache.KEY = "txtoutline_cache"

local function get_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then return lfs end
    return nil
end

--- Build the signature of the current analysis conditions.
--- @param path string path of the .txt file
--- @param parts table|nil extra fields that must invalidate the cache when
---              they change (txt_preformatted, cre_dom_version, ...)
--- @return table|nil signature
function Cache.buildSignature(path, parts)
    if type(path) ~= "string" or path == "" then return nil end
    local lfs = get_lfs()
    if not lfs then return nil end
    local ok, size = pcall(lfs.attributes, path, "size")
    local ok2, mtime = pcall(lfs.attributes, path, "modification")
    if not ok or not ok2 or not size or not mtime then return nil end

    local signature = {
        version = Cache.VERSION,
        recognizer = Recognizer.VERSION,
        size = size,
        mtime = mtime,
    }
    if parts then
        for k, v in pairs(parts) do signature[k] = v end
    end
    return signature
end

--- Shallow comparison of two signatures.
function Cache.signaturesMatch(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(b) do
        if a[k] ~= v then return false end
    end
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    return true
end

--- Load a cached outline.
--- @return items|nil, reason
function Cache.load(doc_settings, document, signature)
    if not doc_settings or type(signature) ~= "table" then
        return nil, "no-signature"
    end
    local data = doc_settings:readSetting(Cache.KEY)
    if type(data) ~= "table" or type(data.items) ~= "table" or #data.items == 0 then
        return nil, "empty"
    end
    if not Cache.signaturesMatch(data.signature, signature) then
        return nil, "stale"
    end

    local items = {}
    for _, entry in ipairs(data.items) do
        if type(entry.title) ~= "string" or type(entry.xpointer) ~= "string" then
            return nil, "corrupt"
        end
        items[#items + 1] = {
            title = entry.title,
            xpointer = entry.xpointer,
            kind = entry.kind,
            level = entry.level,
            number = entry.number,
            depth = entry.depth,
        }
    end
    return items
end

--- Store an outline. Only items that already have an xpointer are stored.
function Cache.save(doc_settings, signature, items, meta)
    if not doc_settings or type(signature) ~= "table" then return false end
    if type(items) ~= "table" or #items == 0 then return false end

    local stored = {}
    for _, item in ipairs(items) do
        if type(item.xpointer) == "string" and type(item.title) == "string" then
            stored[#stored + 1] = {
                title = item.title,
                xpointer = item.xpointer,
                kind = item.kind,
                level = item.level,
                number = item.number,
                depth = item.depth,
            }
        end
    end
    if #stored == 0 then return false end

    doc_settings:saveSetting(Cache.KEY, {
        signature = signature,
        items = stored,
        meta = meta,
    })
    return true
end

function Cache.clear(doc_settings)
    if doc_settings and doc_settings.delSetting then
        doc_settings:delSetting(Cache.KEY)
    end
end

return Cache

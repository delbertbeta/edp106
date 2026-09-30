local script = arg and arg[0] or "tests/lifecycle.lua"
local root = script:match("^(.*)/tests/lifecycle%.lua$") or "."
package.path = root .. "/?.lua;" .. package.path

package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, class) return class end }
end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["util"] = function()
    local function copy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for k, v in pairs(value) do out[copy(k)] = copy(v) end
        return out
    end
    return { tableDeepCopy = copy }
end
package.preload["gettext"] = function()
    return function(s) return s end
end
_G.G_reader_settings = {
    nilOrTrue = function() return true end,
    saveSetting = function() end,
}

local Class = dofile(root .. "/main.lua")
local document = {
    getPageFromXPointer = function(_, xp) return xp == "xp1" and 4 or 9 end,
}
local events = {}
local post_ready
local toc = {
    resetToc = function(self) self.toc = nil end,
    fillToc = function(self) self.toc = document:getToc() end,
}
local plugin = setmetatable({
    document = document,
    outline = {
        { title = "Chapter 1", xpointer = "xp1", page = 0, depth = 1 },
        { title = "Chapter 2", xpointer = "xp2", page = 0, depth = 1 },
    },
    original_get_toc = nil,
    ui = {
        handmade = { isHandmadeTocEnabled = function() return false end },
        toc = toc,
        registerPostReaderReadyCallback = function(_, callback) post_ready = callback end,
        handleEvent = function(_, event) events[#events + 1] = event.name end,
    },
}, { __index = Class })

assert(plugin:_installToc(), "initial custom TOC install failed")
assert(#document:getToc() == 2, "initial TOC missing")

-- KOReader's built-in ReaderHandMade runs before third-party plugins on
-- ReaderReady/DocumentRerendered. When handmade TOC is disabled, setupToc()
-- removes the instance override with `document.getToc = nil`.
document.getToc = nil
plugin:onReaderReady()
assert(type(post_ready) == "function", "ReaderReady must register a finalizer")
assert(document.getToc == nil, "TOC should be installed after all ReaderReady listeners")
post_ready()
assert(type(document.getToc) == "function",
    "ReaderReady finalizer must reinstall TOC after ReaderHandMade reset")
assert(#document:getToc() == 2, "TOC empty after ReaderReady")
assert(document:getToc()[1].page == 4, "TOC pages were not updated")
assert(toc.toc and #toc.toc == 2, "ReaderToc must be eagerly populated for ZenOS")
assert(events[#events] == "TocReset", "TOC listeners were not refreshed")

document.getToc = nil
plugin:onDocumentRerendered()
assert(type(document.getToc) == "function",
    "DocumentRerendered must reinstall TOC after ReaderHandMade reset")
assert(#document:getToc() == 2, "TOC empty after rerender")

print("txtoutline lifecycle: all tests passed")

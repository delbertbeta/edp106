local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Recognizer = require("txtoutline_recognizer")
local Adapter = require("txtoutline_adapter")
local Cache = require("txtoutline_cache")

local TxtOutline = WidgetContainer:extend{
    name = "txtoutline",
    is_doc_only = true,
}

local PLUGIN_VERSION = 1
local SETTING_OUTLINE_ENABLED = "txtoutline_outline_enabled"
local SETTING_STYLE_ENABLED = "txtoutline_style_enabled"

function TxtOutline:init()
    self.Recognizer = Recognizer
    self.Adapter = Adapter
    self.Cache = Cache
    self.active = self.Adapter.isPlainTxt(self.document)
    self.outline = nil
    self.original_get_toc = nil
    self.original_get_css_text = nil
    self.plugin_css = nil
    self.source_text = nil
    self.add_paragraph_indent = true
    if self.active then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TxtOutline:_outlineEnabled()
    return G_reader_settings:nilOrTrue(SETTING_OUTLINE_ENABLED)
end

function TxtOutline:_styleEnabled()
    return G_reader_settings:nilOrTrue(SETTING_STYLE_ENABLED)
end

function TxtOutline:_setGlobalSetting(key, enabled)
    G_reader_settings:saveSetting(key, enabled and true or false)
    self.ui:reloadDocument(nil, true)
end

function TxtOutline:addToMainMenu(menu_items)
    if not self.active then return end
    menu_items.txtoutline = {
        sorting_hint = "more_tools",
        text = _("TXT chapter outline"),
        sub_item_table = {
            {
                text = _("Automatically build chapter outline"),
                checked_func = function() return self:_outlineEnabled() end,
                callback = function()
                    self:_setGlobalSetting(SETTING_OUTLINE_ENABLED,
                        not self:_outlineEnabled())
                end,
            },
            {
                text = _("Apply TXT paragraph style"),
                checked_func = function() return self:_styleEnabled() end,
                callback = function()
                    self:_setGlobalSetting(SETTING_STYLE_ENABLED,
                        not self:_styleEnabled())
                end,
            },
            {
                text = _("Rescan chapters"),
                enabled_func = function() return self:_outlineEnabled() end,
                separator = true,
                callback = function()
                    self.Cache.clear(self.ui.doc_settings)
                    self.ui:reloadDocument(nil, true)
                end,
            },
        },
    }
end

function TxtOutline:_handmadeTocIsEnabled()
    return self.ui.handmade
        and self.ui.handmade.isHandmadeTocEnabled
        and self.ui.handmade:isHandmadeTocEnabled()
end

function TxtOutline:_signature()
    return self.Cache.buildSignature(self.document.file, {
        plugin = PLUGIN_VERSION,
        txt_preformatted = self.ui.typeset and self.ui.typeset.txt_preformatted or "unknown",
        cre_dom_version = self.ui.doc_settings:readSetting("cre_dom_version") or "unknown",
    })
end

function TxtOutline:_updatePages()
    if not self.outline then return end
    for _, item in ipairs(self.outline) do
        local ok, page = pcall(self.document.getPageFromXPointer, self.document, item.xpointer)
        item.page = ok and type(page) == "number" and page or 0
    end
end

function TxtOutline:_installToc()
    if not self.outline or #self.outline == 0 then return end
    if self.original_get_toc == nil then
        -- A pre-existing instance override belongs to another feature/plugin.
        -- Do not replace it: this also protects KOReader's handmade TOC.
        local existing = rawget(self.document, "getToc")
        if existing then
            logger.info("txtoutline: another custom TOC is active; leaving it untouched")
            return false
        end
        self.original_get_toc = false
    end
    self.document.getToc = function()
        return util.tableDeepCopy(self.outline)
    end
    return true
end

function TxtOutline:_restoreToc()
    if self.original_get_toc ~= nil then
        self.document.getToc = self.original_get_toc ~= false and self.original_get_toc or nil
        self.original_get_toc = nil
    end
end

function TxtOutline:_readBundledCss(add_indent)
    local file = io.open(self.path .. "/pre.css", "rb")
    if not file then return nil, "bundled-css-unavailable" end
    local css = file:read("*all")
    file:close()
    if not css or css == "" then return nil, "bundled-css-empty" end
    css = css:gsub("{{TEXT_INDENT}}", add_indent and "2em" or "0")
    return css
end

function TxtOutline:_installPluginCss(css)
    local styletweak = self.ui.styletweak
    local typeset = self.ui.typeset
    if not styletweak or not typeset or type(styletweak.getCssText) ~= "function" then
        return false, "style-modules-unavailable"
    end

    local base_get_css_text = styletweak.getCssText
    self.original_get_css_text = rawget(styletweak, "getCssText") or false
    self.plugin_css = css
    local owner = self
    styletweak.getCssText = function(this)
        local base = base_get_css_text(this) or ""
        if base ~= "" then base = base .. "\n" end
        return base .. (owner.plugin_css or "")
    end

    -- ReaderTypeset has already installed the normal stylesheet during
    -- ReadSettings. Calling setStyleSheet here updates the stylesheet before
    -- the first render and preserves all current user tweaks.
    local ok, err = pcall(self.document.setStyleSheet, self.document,
        typeset.css or self.document.default_css, styletweak:getCssText())
    if not ok then
        styletweak.getCssText = self.original_get_css_text ~= false
            and self.original_get_css_text or nil
        self.original_get_css_text = nil
        self.plugin_css = nil
        return false, tostring(err)
    end
    return true
end

function TxtOutline:_restorePluginCss()
    if self.original_get_css_text ~= nil and self.ui.styletweak then
        self.ui.styletweak.getCssText = self.original_get_css_text ~= false
            and self.original_get_css_text or nil
        self.original_get_css_text = nil
        self.plugin_css = nil
    end
end

local function uniqueTitles(items)
    local titles, seen = {}, {}
    for _, item in ipairs(items) do
        local key = item.normalized_title
        if key ~= "" and not seen[key] then
            seen[key] = true
            titles[#titles + 1] = { title = item.title, key = key }
        end
    end
    return titles
end

local function mapCandidates(items, hits_by_key)
    local used, mapped = {}, {}
    for _, item in ipairs(items) do
        local key = item.normalized_title
        used[key] = (used[key] or 0) + 1
        local hit = hits_by_key[key] and hits_by_key[key][used[key]]
        if hit and hit.xpointer then
            mapped[#mapped + 1] = {
                title = item.title,
                xpointer = hit.xpointer,
                page = hit.page or 0,
                depth = item.depth,
                level = item.level,
                kind = item.kind,
                number = item.number,
            }
        end
    end
    return mapped
end

function TxtOutline:_buildOutline()
    local signature = self:_signature()
    local cached = self.Cache.load(
        self.ui.doc_settings, self.document, signature)
    if cached then
        logger.info("txtoutline: loaded", #cached, "headings from cache")
        return cached
    end

    local text, source, read_reason = self.source_text, "shared", nil
    if not text then
        text, source, read_reason = self.Adapter.readSourceText(self.document)
    end
    if not text then
        logger.warn("txtoutline: skipped", self.document.file, "reason:", read_reason)
        return nil
    end

    self.source_text = text
    local candidates, scan_stats = self.Recognizer.scan(text)
    if #candidates == 0 then
        logger.info("txtoutline: no chapter headings found in", self.document.file)
        return nil
    end

    local hits_by_key, search_stats = self.Adapter.searchTitles(
        self.document, uniqueTitles(candidates))
    self.Adapter.validateHits(self.document, hits_by_key)
    local outline = mapCandidates(candidates, hits_by_key)

    if #outline == 0 then
        logger.warn("txtoutline: headings were recognized but could not be mapped to the document")
        return nil
    end

    self.Cache.save(self.ui.doc_settings, signature, outline, {
        source = source,
        scanned_lines = scan_stats.lines,
        candidates = #candidates,
        mapped = #outline,
        search_batches = search_stats.batches,
    })
    logger.info("txtoutline: mapped", #outline, "of", #candidates,
        "headings from", scan_stats.lines, "lines")
    return outline
end

function TxtOutline:onPreRenderDocument()
    if not self.active then return end

    -- Read once when either feature needs source analysis. Outline generation
    -- reuses this value on cache misses; indentation only samples the prefix.
    if self:_styleEnabled() then
        local text = self.source_text
        if not text then
            text = self.Adapter.readSourceText(self.document)
            self.source_text = text
        end
        if text then
            local indent_stats
            self.add_paragraph_indent, indent_stats = self.Recognizer.analyzeIndentation(text)
            logger.info(string.format(
                "txtoutline: paragraph indent %s (%d/%d source-indented lines)",
                self.add_paragraph_indent and "enabled" or "suppressed",
                indent_stats.indented, indent_stats.sampled))
        end
    end

    -- Paragraph styling and outline generation are independent global options.
    local bundled_css = ""
    if self:_styleEnabled() then
        local css, css_reason = self:_readBundledCss(self.add_paragraph_indent)
        if css then
            bundled_css = css
        else
            logger.warn("txtoutline: could not load bundled TXT style:", css_reason)
        end
    end

    if not self:_outlineEnabled() or self:_handmadeTocIsEnabled() then
        if bundled_css ~= "" then self:_installPluginCss(bundled_css) end
        return
    end

    local ok, outline = pcall(self._buildOutline, self)
    if not ok then
        logger.err("txtoutline: analysis failed:", outline)
        if bundled_css ~= "" then self:_installPluginCss(bundled_css) end
        return
    end
    self.outline = outline

    local heading_css, selector_count = "", 0
    if self.outline then
        if not self:_installToc() then
            self.outline = nil
        else
            -- Convert each mapped XPointer into an exact structural CSS
            -- selector. This changes presentation only; the DOM tags remain.
            heading_css, selector_count = self.Adapter.buildHeadingCss(self.outline)
        end
    end

    local plugin_css = bundled_css
    if heading_css ~= "" then
        if plugin_css ~= "" then plugin_css = plugin_css .. "\n" end
        plugin_css = plugin_css .. heading_css
    end
    local styled, reason = false, "no-plugin-css"
    if plugin_css ~= "" then
        styled, reason = self:_installPluginCss(plugin_css)
    end
    if styled then
        logger.info("txtoutline: applied bundled TXT style and", selector_count,
            "heading visual rules")
    else
        logger.warn("txtoutline: stylesheet unavailable:", reason)
    end
end

function TxtOutline:_finalizeToc()
    if not self.outline or self:_handmadeTocIsEnabled() then return end
    -- ReaderHandMade may remove the document override during ReaderReady.
    if not self:_installToc() then return end
    self:_updatePages()
    if self.ui.toc then
        self.ui.toc:resetToc()
        self.ui.toc:fillToc()
    end
    self.ui:handleEvent(Event:new("TocReset"))
end

function TxtOutline:onReaderReady()
    if not self.outline or self:_handmadeTocIsEnabled() then return end
    -- Run after every ReaderReady listener, including device plugins. This also
    -- eagerly fills ReaderToc for ZenOS, whose custom widget reads ui.toc.toc
    -- directly instead of calling fillToc().
    if self.ui.registerPostReaderReadyCallback then
        self.ui:registerPostReaderReadyCallback(function()
            if self.document then self:_finalizeToc() end
        end)
    else
        self:_finalizeToc()
    end
end

function TxtOutline:onDocumentRerendered()
    if not self.outline or self:_handmadeTocIsEnabled() then return end
    -- ReaderToc and ReaderHandMade have already processed this event because
    -- built-in modules are registered before plugins.
    self:_finalizeToc()
end

function TxtOutline:onCloseDocument()
    self:_restoreToc()
    self:_restorePluginCss()
end

return TxtOutline

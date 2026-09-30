local script = arg and arg[0] or "tests/run.lua"
local root = script:match("^(.*)/tests/run%.lua$") or "."
package.path = root .. "/?.lua;" .. package.path

package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end }
end

local R = require("txtoutline_recognizer")
local Adapter = require("txtoutline_adapter")

local cases = {
    { "第一卷 风起", "volume", 1 },
    { "第十二章：归来", "chapter", 2 },
    { "第一章初入江湖", "chapter", 2 },
    { "第三节 旧事", "section", 3 },
    { "卷五", "volume", 1 },
    { "章三 初遇", "chapter", 2 },
    { "序章", "matter", nil },
    { "番外一：雪夜", "matter", nil },
    { "附录 A", "matter", nil },
    { "Chapter 12: The Fall", "chapter", 2 },
    { "Part IV", "volume", 1 },
    { "Section 2 — Details", "section", 3 },
    { "Prologue", "matter", nil },
    { "Epilogue: Home", "matter", nil },
}

for _, case in ipairs(cases) do
    local got, reason = R.matchLine(case[1], R.withDefaults())
    assert(got, case[1] .. " should match: " .. tostring(reason))
    assert(got.kind == case[2], case[1] .. " kind mismatch")
    assert(got.level == case[3], case[1] .. " level mismatch")
end

local rejected = {
    "普通正文段落。",
    "第一章说到了这里，他说。",
    "Chapter 1 was the first thing he read",
    "第1步 打开文件",
    "前言不搭后语",
}
for _, line in ipairs(rejected) do
    assert(not R.matchLine(line, R.withDefaults()), line .. " should not match")
end

local items = R.scan("第一章 开始\n第一节 相遇\n第二章 继续\n")
assert(#items == 3, "scan count mismatch")
assert(items[1].depth == 1 and items[2].depth == 2 and items[3].depth == 1,
    "compressed hierarchy mismatch")

local add_indent, indent_stats = R.analyzeIndentation(
    "第一章\n　　已有缩进。\n　　第二段。\n", { indent_min_lines = 1 })
assert(not add_indent and indent_stats.indented == 2,
    "source indentation should suppress CSS indentation")
add_indent = R.analyzeIndentation(
    "第一章\n没有缩进。\n第二段。\n", { indent_min_lines = 1 })
assert(add_indent, "plain paragraphs should receive CSS indentation")

assert(Adapter.escapePattern("Chapter (1): a+b?") == "Chapter \\(1\\): a\\+b\\?",
    "regex escaping mismatch")
assert(Adapter.xpointerToSelector(
    "/FictionBook/body[1]/section[2]/title[1]/p[1]/text()[1].0")
    == "body:nth-of-type(1) > section:nth-of-type(2) > title:nth-of-type(1) > p:nth-of-type(1)",
    "xpointer selector mismatch")
local css, count = Adapter.buildHeadingCss({
    { xpointer = "/FictionBook/body[1]/pre[2]/text()[1].0", depth = 1 },
    { xpointer = "/FictionBook/body[1]/pre[8]/text()[1].0", depth = 2 },
})
assert(count == 2 and css:find("pre:nth%-of%-type%(2%)") and css:find("font%-size: 1%.3em"),
    "heading CSS mismatch")
assert(select(2, css:gsub("page%-break%-before: always", "")) == 2,
    "only level 1 and 2 headings should force a page break")
assert(select(2, css:gsub("border%-left: 0%.18em solid currentColor !important", "")) == 2,
    "all generated TXT heading groups should mirror heading_left_bar.css")
assert(css:find("text%-align: left !important") and css:find("padding%-left: 0%.5em !important"),
    "TXT headings should use the left-bar alignment and padding")

local utf8_text, utf8_reason = Adapter.decodeBytes("珍宝馆")
assert(utf8_text == "珍宝馆" and utf8_reason == nil, "valid UTF-8 must pass through untouched")

local GBK_ZHENBAOGUAN = "\182\213\228\177\166\185\221" -- 珍宝馆 in GBK

-- Legacy CJK decoding (charset.lua). ICU itself only exists on the device
-- (Android ships libicuuc.so), so offline these assertions pin the parts that
-- do not need it: the replacement counter, and the safe skip when the decoder
-- is unavailable -- which is also what a KOReader build without FFI, or a ROM
-- without ICU, will hit.
local Charset = require("txtoutline_charset")
assert(Charset.countReplacements("abc") == 0, "no replacement characters expected")
assert(Charset.countReplacements("a\239\191\189b\239\191\189") == 2,
    "replacement characters should be counted")
local no_icu, no_icu_reason = Charset.decode(GBK_ZHENBAOGUAN)
assert(no_icu == nil and type(no_icu_reason) == "string",
    "decode without ICU must fail with a reason")
local gbk_text, gbk_reason = Adapter.decodeBytes(GBK_ZHENBAOGUAN)
assert(gbk_text == nil and gbk_reason == "not-utf8",
    "a GBK file without ICU must still be skipped, not mangled")

print("txtoutline: all tests passed")

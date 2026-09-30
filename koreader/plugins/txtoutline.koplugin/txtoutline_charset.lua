--[[--
txtoutline.koplugin / charset.lua

Decoding of legacy CJK .txt files (GBK / GB2312 / GB18030, and any other code
page the system ICU knows) for the outline scanner.

Why this module exists: adapter.lua has to read the raw book bytes, because
crengine's file reader hands them back undecoded, while Recognizer.scan() needs
UTF-8. Pure Lua would need a ~48 KB code table for GBK alone. Every Android ROM
already ships ICU (libicuuc.so, listed in /system/etc/public.libraries.txt so
apps are allowed to dlopen it) and converts in a single call.

Measured on the target device (EPD106, Android 8.1, ICU 58, armv7a):

  * ffi.load("libicuuc.so") works from a KOReader plugin. The only exported
    symbol suffix is _58 -- the ICU release follows the Android version -- so
    the suffix is probed at runtime instead of being hardcoded.
  * ucnv_convert("utf-8", "gb18030", ...) of the real 340 KB novel is
    byte-identical to Python's gb18030 codec (503525 bytes, same rolling hash)
    and takes 12 ms.
  * Invalid or truncated input is substituted with U+FFFD and still reported as
    success, so no sanitising pre-pass is needed: that is the "lenient" policy,
    which the caller bounds with its replacement-ratio limit.
  * A too-small output buffer reports U_BUFFER_OVERFLOW_ERROR plus the required
    length, so the buffer is grown and the call repeated.

None of this is required for the plugin to work: a ROM without ICU, a KOReader
build without FFI, or an unknown symbol suffix makes decode() return nil plus a
reason, and the book is skipped exactly as it was before this module existed.
]]--

local Charset = {}

-- Symbol names to try: the unrenamed spelling first (desktop ICU), then the
-- versioned one ("ucnv_convert_58" is what Android 8.1 exports).
Charset.SYMBOL_NAMES = (function()
    local names = { "ucnv_convert" }
    for version = 56, 80 do
        names[#names + 1] = "ucnv_convert_" .. version
    end
    return names
end)()

-- Bytes of U+FFFD REPLACEMENT CHARACTER: what ICU writes for a byte that does
-- not decode. Counting those is how the caller decides the file is not really
-- GBK (see adapter.lua).
Charset.REPLACEMENT = "\239\191\189"

Charset.ERR_BUFFER_OVERFLOW = 15 -- U_BUFFER_OVERFLOW_ERROR

--- Number of replacement characters in decoded text.
function Charset.countReplacements(text)
    if type(text) ~= "string" then return 0 end
    local _, count = text:gsub(Charset.REPLACEMENT, "")
    return count
end

-- nil = not tried yet, false = tried and unavailable.
local icu, icu_reason

--- Load libicuuc.so and resolve ucnv_convert under whichever name exists.
--- @return table|nil { lib = <cdata namespace>, ffi = ffi, convert = <cdata function>, symbol = string },
---         reason|nil
local function loadIcu()
    if icu ~= nil then return icu, icu_reason end

    icu, icu_reason = false, "no-ffi"
    local ok, ffi = pcall(require, "ffi")
    if not ok then return icu, icu_reason end

    local loaded, lib = pcall(ffi.load, "libicuuc.so")
    if not loaded or lib == nil then
        icu_reason = "no-icu"
        return icu, icu_reason
    end

    -- Declare every candidate name, then ask the library which one it has.
    local decl = {}
    for _, name in ipairs(Charset.SYMBOL_NAMES) do
        decl[#decl + 1] = ("int32_t %s(const char*, const char*, char*, int32_t, const char*, int32_t, int*);")
            :format(name)
    end
    pcall(ffi.cdef, table.concat(decl, "\n"))

    for _, name in ipairs(Charset.SYMBOL_NAMES) do
        local resolved, convert = pcall(function() return lib[name] end)
        if resolved and convert ~= nil then
            icu = { lib = lib, ffi = ffi, convert = convert, symbol = name }
            return icu
        end
    end

    icu_reason = "no-icu-symbol"
    return icu, icu_reason
end

--- Decode raw file bytes into UTF-8 with a system ICU converter.
--- Invalid input does not fail: ICU substitutes U+FFFD and reports success, so
--- only a real ICU error (or a missing ICU) returns nil.
--- @param bytes string raw file bytes
--- @param encoding string ICU converter name, e.g. "gb18030"
--- @return text|nil, reason|nil, stats|nil
function Charset.decode(bytes, encoding)
    if type(bytes) ~= "string" or #bytes == 0 then
        return nil, "empty"
    end
    local lib, reason = loadIcu()
    if not lib then return nil, reason end

    -- 2x covers the worst real expansion: a 2-byte pair becomes 3 UTF-8 bytes.
    local capacity = #bytes * 2 + 64
    local err = lib.ffi.new("int[1]", 0)
    local out = lib.ffi.new("char[?]", capacity)
    local length = lib.convert("utf-8", encoding, out, capacity, bytes, #bytes, err)
    if err[0] == Charset.ERR_BUFFER_OVERFLOW and length > 0 then
        -- ICU returns the length it needs instead of a partial result.
        capacity = length + 64
        err[0] = 0
        out = lib.ffi.new("char[?]", capacity)
        length = lib.convert("utf-8", encoding, out, capacity, bytes, #bytes, err)
    end
    if err[0] ~= 0 or length <= 0 then
        return nil, "icu-error-" .. tostring(err[0])
    end

    return lib.ffi.string(out, length), nil, {
        encoding = encoding,
        bytes = #bytes,
        symbol = lib.symbol,
    }
end

return Charset

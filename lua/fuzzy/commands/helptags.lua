local M = {}

local function parse_helplang()
    local langs, seen = {}, {}
    for raw in (vim.o.helplang or ""):gmatch("[^,]+") do
        local lang = vim.trim(raw)
        if lang ~= "" and not seen[lang] then
            langs[#langs + 1] = lang
            seen[lang] = true
        end
    end
    if not seen["en"] then langs[#langs + 1] = "en" end
    return langs
end

-- Strip excmd's ;"-extended fields (ctags format 2) and return base.
local function strip_extended(excmd)
    return excmd:match("^(.-)%s*;\"") or excmd
end

-- Convert a tags-file excmd to a { lnum?, pattern? } quickfix target.
local function excmd_to_qf_target(excmd)
    local n = tonumber(excmd)
    if n then return { lnum = n } end
    local base = strip_extended(excmd)
    local pat = base:match("^/(.-)/$") or base:match("^%?(.-)%?$")
    if pat then return { pattern = pat, lnum = 0 } end
    return { lnum = 1 }
end

---@class FuzzyHelpEntry
---@field tag string
---@field file string   Full path to the help file
---@field filename_short string  Basename of the help file
---@field excmd string  Raw excmd from the tags file (search pattern or line number)

--- Collect help tags from all runtimepath doc/tags files, deduped by tag name.
--- Language priority follows vim.o.helplang; "en" is always the final fallback.
--- Within each language bucket, runtimepath order is preserved.
---@return FuzzyHelpEntry[]
function M.collect()
    local langs = parse_helplang()
    local lang_order = {}
    for i, l in ipairs(langs) do lang_order[l] = i end

    local tag_files = {}

    for _, f in ipairs(vim.fn.globpath(vim.o.runtimepath, "doc/tags", false, true)) do
        tag_files[#tag_files + 1] = {
            path = f,
            order = lang_order["en"] or (#langs + 1),
            idx = #tag_files,
        }
    end
    for _, f in ipairs(vim.fn.globpath(vim.o.runtimepath, "doc/tags-*", false, true)) do
        local lang = f:match("tags%-(%a+)$")
        if lang then
            tag_files[#tag_files + 1] = {
                path = f,
                order = lang_order[lang] or (#langs + 1),
                idx = #tag_files,
            }
        end
    end

    -- Stable sort: language priority first, then rtp insertion order.
    table.sort(tag_files, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.idx < b.idx
    end)

    local seen, tags = {}, {}
    for _, tf in ipairs(tag_files) do
        local ok, lines = pcall(vim.fn.readfile, tf.path)
        if ok and lines then
            local doc_dir = vim.fn.fnamemodify(tf.path, ":h")
            for _, line in ipairs(lines) do
                if line ~= "" and not line:match("^!_TAG_") then
                    local tag, filename, excmd = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
                    if tag and filename and not seen[tag] then
                        seen[tag] = true
                        tags[#tags + 1] = {
                            tag = tag,
                            file = doc_dir .. "/" .. filename,
                            filename_short = filename,
                            excmd = excmd or "",
                        }
                    end
                end
            end
        end
    end
    return tags
end

--- Build quickfix items from a list of FuzzyHelpEntry values.
---@param entries FuzzyHelpEntry[]
---@return table[] quickfix items
function M.to_qf_items(entries)
    local items = {}
    for _, entry in ipairs(entries) do
        local target = excmd_to_qf_target(entry.excmd)
        items[#items + 1] = vim.tbl_extend("force", {
            filename = entry.file,
            col = 1,
            text = entry.tag,
        }, target)
    end
    return items
end

return M

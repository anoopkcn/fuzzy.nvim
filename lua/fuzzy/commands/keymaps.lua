local M = {}

local GAP = " │ "
local MODE_WIDTH = 2
local LHS_WIDTH_FRACTION = 0.25

local HL = {
    mode   = "FuzzyPickerPaletteLabel",
    flag   = "FuzzyPickerPaletteAlias",
    lhs    = "FuzzyPickerPaletteName",
    detail = "FuzzyPickerPaletteDetail",
    sep    = "FuzzyPickerPaletteSep",
}

-- Each Neovim "registration mode" we query separately. Maps set with `:map`
-- (no prefix) come back with `mode = " "` (space, meaning NVO); querying any
-- of n/v/o returns them, so we dedupe by (mode, lhs, buffer) below.
local MODES = { "n", "i", "v", "x", "s", "o", "c", "t", "l", "!" }

local function normalize_text(text)
    if type(text) ~= "string" then return nil end
    text = vim.trim(text:gsub("%s+", " "))
    if text == "" then return nil end
    return text
end

local function truncate(text, max_width)
    text = tostring(text or "")
    if max_width <= 0 then return "" end
    if #text <= max_width then return text end
    if max_width <= 3 then return text:sub(1, max_width) end
    return text:sub(1, max_width - 3) .. "..."
end

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then return text end
    return text .. (" "):rep(width - #text)
end

local function join_filter_text(parts)
    return table.concat(vim.tbl_filter(function(part)
        return type(part) == "string" and part ~= ""
    end, parts), " ")
end

local function detail_for(map)
    local desc = normalize_text(map.desc)
    if desc then return desc end
    local rhs = normalize_text(map.rhs)
    if rhs then return rhs end
    if type(map.callback) == "function" then return "<function>" end
    return ""
end

---@class FuzzyKeymapEntry
---@field mode string  single mode char (or " " for NVO maps from `:map`)
---@field lhs string
---@field detail string
---@field buffer boolean  true when buffer-local
---@field filter_text string

local function make_entry(map)
    local mode = map.mode
    if type(mode) ~= "string" or mode == "" then mode = " " end
    mode = mode:sub(1, 1)

    local entry = {
        mode = mode,
        lhs = map.lhs or "",
        detail = detail_for(map),
        buffer = (map.buffer or 0) ~= 0,
    }
    entry.filter_text = join_filter_text({
        entry.mode,
        entry.lhs,
        entry.detail,
        entry.buffer and "buffer" or "",
    })
    return entry
end

local function dedupe_key(map)
    return (map.mode or " ") .. "\0" .. (map.lhs or "") .. "\0" .. tostring(map.buffer or 0)
end

---@return FuzzyKeymapEntry[]
function M.collect()
    local entries = {}
    local seen = {}

    local function add_maps(maps)
        if type(maps) ~= "table" then return end
        for _, map in ipairs(maps) do
            local key = dedupe_key(map)
            if not seen[key] then
                seen[key] = true
                entries[#entries + 1] = make_entry(map)
            end
        end
    end

    for _, mode in ipairs(MODES) do
        local ok_g, gm = pcall(vim.api.nvim_get_keymap, mode)
        if ok_g then add_maps(gm) end
        local ok_b, bm = pcall(vim.api.nvim_buf_get_keymap, 0, mode)
        if ok_b then add_maps(bm) end
    end

    table.sort(entries, function(a, b)
        if a.mode ~= b.mode then return a.mode < b.mode end
        if a.buffer ~= b.buffer then return not a.buffer end
        return a.lhs < b.lhs
    end)

    return entries
end

---@param entry FuzzyKeymapEntry
---@return string
function M.filter_text(entry)
    return entry.filter_text or entry.lhs or ""
end

---@param entries FuzzyKeymapEntry[]
---@param width integer
---@return { lhs_width: integer }
function M.make_render_context(entries, width)
    local max_lhs = 0
    for _, entry in ipairs(entries) do
        if #entry.lhs > max_lhs then max_lhs = #entry.lhs end
    end
    local lhs_width = math.max(8, math.floor(width * LHS_WIDTH_FRACTION))
    return {
        lhs_width = math.min(max_lhs, lhs_width),
    }
end

---@param entry FuzzyKeymapEntry
---@param ctx? { lhs_width: integer }
---@param width? integer
---@return string
function M.format_entry(entry, ctx, width)
    ctx = ctx or { lhs_width = #(entry.lhs or "") }
    local mode_char = entry.mode or " "
    local flag_char = entry.buffer and "*" or " "
    local mode_field = mode_char .. flag_char
    local lhs = pad(truncate(entry.lhs or "", math.max(1, ctx.lhs_width)), ctx.lhs_width)
    local row = mode_field .. GAP .. lhs

    local detail = entry.detail or ""
    if width then
        local available = width - #row - #GAP
        if available > 0 then
            row = row .. GAP .. truncate(detail, available)
        end
    else
        row = row .. GAP .. detail
    end

    if width and #row > width then
        return truncate(row, width)
    end
    return row
end

---@param entry FuzzyKeymapEntry
---@param ctx { lhs_width: integer }
---@param text string
---@return { start_col: integer, end_col: integer, group: string }[]
function M.highlight_ranges(entry, ctx, text)
    local ranges = {}
    local n = #text
    local col = 1

    local function add_sep(after_col)
        local sep_start = after_col + 1
        local sep_end = math.min(n, after_col + #GAP)
        if sep_end >= sep_start then
            ranges[#ranges + 1] = { start_col = sep_start, end_col = sep_end, group = HL.sep }
        end
    end

    ranges[#ranges + 1] = { start_col = col, end_col = math.min(n, col), group = HL.mode }
    if entry.buffer then
        ranges[#ranges + 1] = {
            start_col = col + 1,
            end_col = math.min(n, col + 1),
            group = HL.flag,
        }
    end
    col = col + MODE_WIDTH
    add_sep(col - 1)
    col = col + #GAP

    local lhs_width = math.max(1, ctx.lhs_width)
    local lhs_text = truncate(entry.lhs or "", lhs_width)
    if lhs_text ~= "" then
        ranges[#ranges + 1] = {
            start_col = col,
            end_col = math.min(n, col + #lhs_text - 1),
            group = HL.lhs,
        }
    end
    col = col + lhs_width
    add_sep(col - 1)
    col = col + #GAP

    if col <= n then
        ranges[#ranges + 1] = { start_col = col, end_col = n, group = HL.detail }
    end

    return ranges
end

return M

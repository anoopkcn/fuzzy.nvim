-- FuzzyLspProjectSymbols: LSP workspace symbols (project-wide).
-- Non-bang path runs a one-shot query and populates the quickfix list.
-- Picker source (bang) is in lua/fuzzy/picker/sources/lsp_project_symbols.lua
-- and reuses the format helpers below.

local lsp = require("fuzzy.lsp")
local quickfix = require("fuzzy.quickfix")

local COMMAND_NAME = "FuzzyLspProjectSymbols"
local METHOD = "workspace/symbol"

local GAP = " │ "
local NAME_WIDTH_FRACTION = 0.45

local HL = {
    kind   = "FuzzyPickerPaletteLabel",
    name   = "FuzzyPickerPaletteName",
    depr   = "FuzzyPickerPaletteAlias",
    path   = "FuzzyPickerPaletteDetail",
    sep    = "FuzzyPickerPaletteSep",
}

local M = {
    COMMAND_NAME = COMMAND_NAME,
    METHOD = METHOD,
}

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then return text end
    return text .. (" "):rep(width - #text)
end

local function rel_path(abs)
    if not abs or abs == "" then return "" end
    return vim.fn.fnamemodify(abs, ":.")
end

---@param entry FuzzyLspEntry
function M.filter_text(entry)
    local path = entry.rel_path or rel_path(entry.qf and entry.qf.filename)
    return (entry.filter_text or "") .. " " .. path
end

---@param entries FuzzyLspEntry[]
---@param width integer
function M.make_render_context(entries, width)
    local max_kind = 0
    for _, e in ipairs(entries) do
        local n = #("[" .. (e.kind or "") .. "]")
        if n > max_kind then max_kind = n end
    end
    local name_cap = math.max(16, math.floor(width * NAME_WIDTH_FRACTION))
    return { kind_width = max_kind, name_width = name_cap }
end

---@param entry FuzzyLspEntry
---@param ctx? { kind_width: integer, name_width: integer }
---@param width? integer
function M.format_entry(entry, ctx, width)
    ctx = ctx or { kind_width = #("[" .. entry.kind .. "]"), name_width = #entry.display_name }
    local kind_field = pad("[" .. (entry.kind or "") .. "]", ctx.kind_width)
    local name = entry.display_name or ""
    if entry.deprecated then name = name .. " (deprecated)" end
    local name_field = pad(truncate(name, ctx.name_width), ctx.name_width)
    local rel = entry.rel_path or rel_path(entry.qf and entry.qf.filename)
    local loc = ("%s:%d"):format(rel, (entry.qf and entry.qf.lnum) or 1)
    local row = kind_field .. " " .. name_field .. GAP .. loc
    if width and #row > width then return truncate(row, width) end
    return row
end

---@param entry FuzzyLspEntry
---@param ctx { kind_width: integer, name_width: integer }
---@param text string
function M.highlight_ranges(entry, ctx, text)
    local ranges = {}
    local n = #text
    local kind_label = "[" .. (entry.kind or "") .. "]"
    local kind_width = ctx.kind_width or #kind_label
    local name_width = ctx.name_width or #(entry.display_name or "")

    ranges[#ranges + 1] = {
        start_col = 1,
        end_col = math.min(n, #kind_label),
        group = HL.kind,
    }
    local name_start = kind_width + 2

    if entry.container and entry.container ~= "" then
        local container_end = math.min(n, name_start + #entry.container - 1)
        ranges[#ranges + 1] = {
            start_col = name_start,
            end_col = container_end,
            group = HL.path,
        }
        local dot_col = container_end + 1
        if dot_col <= n then
            ranges[#ranges + 1] = { start_col = dot_col, end_col = dot_col, group = HL.sep }
        end
        local name_col = dot_col + 1
        local name_end = math.min(n, name_col + #(entry.name or "") - 1)
        if name_col <= n then
            ranges[#ranges + 1] = { start_col = name_col, end_col = name_end, group = HL.name }
        end
    else
        local name_end = math.min(n, name_start + #(entry.name or "") - 1)
        if name_start <= n then
            ranges[#ranges + 1] = { start_col = name_start, end_col = name_end, group = HL.name }
        end
    end

    -- Separator + path:lnum trail
    local sep_start = kind_width + 1 + name_width + 1  -- 1-based col where GAP starts
    if sep_start <= n then
        local sep_end = math.min(n, sep_start + #GAP - 1)
        ranges[#ranges + 1] = { start_col = sep_start, end_col = sep_end, group = HL.sep }
        local path_start = sep_end + 1
        if path_start <= n then
            ranges[#ranges + 1] = { start_col = path_start, end_col = n, group = HL.path }
        end
    end
    return ranges
end

---@param args string
function M.run(args)
    local bufnr = vim.api.nvim_get_current_buf()
    if not lsp.require_any_workspace_client(COMMAND_NAME) then return end

    local query = vim.trim(args or "")
    lsp.request_workspace_symbols(bufnr, query, function(items, err)
        if err then
            vim.notify(COMMAND_NAME .. ": " .. err, vim.log.levels.WARN)
            return
        end
        local title = (query ~= "" and (COMMAND_NAME .. " [" .. query .. "]")) or COMMAND_NAME
        local count = quickfix.update(items, { title = title, command = COMMAND_NAME })
        quickfix.open_if_results(count, COMMAND_NAME .. ": no symbols.")
    end)
end

return M

-- FuzzyLspSymbols: LSP document symbols for the current buffer.
-- Non-bang path populates the quickfix list; picker source (bang) is in
-- lua/fuzzy/picker/sources/lsp_symbols.lua and reuses the format helpers below.

local lsp = require("fuzzy.lsp")
local quickfix = require("fuzzy.quickfix")

local COMMAND_NAME = "FuzzyLspSymbols"
local METHOD = "textDocument/documentSymbol"

local NAME_WIDTH_FRACTION = 0.5

local HL = {
    kind   = "FuzzyPickerPaletteLabel",
    name   = "FuzzyPickerPaletteName",
    depr   = "FuzzyPickerPaletteAlias",
    detail = "FuzzyPickerPaletteDetail",
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

---@param entry FuzzyLspEntry
function M.filter_text(entry)
    return entry.filter_text or ""
end

---@param entries FuzzyLspEntry[]
---@param width integer
function M.make_render_context(entries, width)
    local max_kind = 0
    for _, e in ipairs(entries) do
        local n = #("[" .. (e.kind or "") .. "]")
        if n > max_kind then max_kind = n end
    end
    local name_cap = math.max(12, math.floor(width * NAME_WIDTH_FRACTION))
    return { kind_width = max_kind, name_width = name_cap }
end

---@param entry FuzzyLspEntry
---@param ctx? { kind_width: integer, name_width: integer }
---@param width? integer
function M.format_entry(entry, ctx, width)
    ctx = ctx or { kind_width = #("[" .. entry.kind .. "]"), name_width = #entry.display_name }
    local kind_field = pad("[" .. (entry.kind or "") .. "]", ctx.kind_width)
    local row = kind_field .. " " .. (entry.display_name or "")
    if entry.deprecated then row = row .. " (deprecated)" end
    if width and #row > width then return truncate(row, width) end
    return row
end

---@param entry FuzzyLspEntry
---@param ctx { kind_width: integer, name_width: integer }
---@param text string
function M.highlight_ranges(entry, ctx, text)
    local ranges = {}
    local n = #text
    local kind_width = ctx.kind_width or #("[" .. entry.kind .. "]")
    -- "[Kind]..." — highlight up to the closing bracket
    local kind_label = "[" .. (entry.kind or "") .. "]"
    ranges[#ranges + 1] = {
        start_col = 1,
        end_col = math.min(n, #kind_label),
        group = HL.kind,
    }
    local name_start = kind_width + 2  -- 1-indexed col after padding + space
    if name_start <= n then
        local container_end = name_start
        if entry.container and entry.container ~= "" then
            container_end = math.min(n, name_start + #entry.container - 1)
            ranges[#ranges + 1] = {
                start_col = name_start,
                end_col = container_end,
                group = HL.detail,
            }
            local dot_col = container_end + 1
            if dot_col <= n then
                ranges[#ranges + 1] = {
                    start_col = dot_col,
                    end_col = dot_col,
                    group = HL.sep,
                }
            end
            container_end = dot_col
        else
            container_end = name_start - 1
        end
        local name_col = container_end + 1
        if name_col <= n then
            local name_end = math.min(n, name_col + #(entry.name or "") - 1)
            ranges[#ranges + 1] = {
                start_col = name_col,
                end_col = name_end,
                group = HL.name,
            }
            if entry.deprecated then
                local depr_col = name_end + 2
                if depr_col <= n then
                    ranges[#ranges + 1] = {
                        start_col = depr_col,
                        end_col = n,
                        group = HL.depr,
                    }
                end
            end
        end
    end
    return ranges
end

---@param args? string  literal substring filter on the symbol label
function M.run(args)
    local bufnr = vim.api.nvim_get_current_buf()
    if not lsp.require_clients(bufnr, METHOD, COMMAND_NAME) then return end

    local pattern = vim.trim(args or "")
    lsp.request_document_symbols(bufnr, function(items, err)
        if err then
            vim.notify(COMMAND_NAME .. ": " .. err, vim.log.levels.WARN)
            return
        end
        local filtered = items
        local title = COMMAND_NAME
        if pattern ~= "" then
            local needle = pattern:lower()
            filtered = {}
            for _, item in ipairs(items) do
                if (item.text or ""):lower():find(needle, 1, true) then
                    filtered[#filtered + 1] = item
                end
            end
            title = COMMAND_NAME .. " [" .. pattern .. "]"
        end
        local count = quickfix.update(filtered, { title = title, command = COMMAND_NAME })
        quickfix.open_if_results(count, COMMAND_NAME .. ": no symbols.")
    end)
end

return M

local M = {}

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then return text end
    return text .. (" "):rep(width - #text)
end

local function truncate(text, max_width)
    text = tostring(text or "")
    if max_width <= 0 then return "" end
    if #text <= max_width then return text end
    if max_width <= 3 then return text:sub(1, max_width) end
    return text:sub(1, max_width - 3) .. "..."
end

local function read_line(bufnr, lnum)
    if not (bufnr and lnum and lnum > 0) then return "" end
    if not vim.api.nvim_buf_is_valid(bufnr) then return "" end
    if not vim.api.nvim_buf_is_loaded(bufnr) then return "" end
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum - 1, lnum, false)
    if not ok or not lines or not lines[1] then return "" end
    return (lines[1]:gsub("^%s+", ""))
end

---@class FuzzyMarkEntry
---@field name string         -- single char (e.g. "A", "a", ".", "'")
---@field scope "global"|"local"
---@field bufnr integer
---@field lnum integer
---@field col integer
---@field rel_path string
---@field abs_path string
---@field line_text string
---@field filter_text string

local function entry_from_mark(mark, scope, ctx_bufnr)
    if type(mark) ~= "table" or type(mark.pos) ~= "table" then return nil end
    local name = mark.mark and mark.mark:sub(2) or ""
    if name == "" then return nil end
    local pos = mark.pos
    local bufnr = pos[1] ~= 0 and pos[1] or ctx_bufnr
    local lnum = pos[2] or 0
    if lnum <= 0 then return nil end
    local col = (pos[3] or 0)
    local abs_path
    if mark.file and mark.file ~= "" then
        abs_path = vim.fn.fnamemodify(mark.file, ":p")
    elseif bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
        local name_ = vim.api.nvim_buf_get_name(bufnr)
        abs_path = name_ ~= "" and vim.fn.fnamemodify(name_, ":p") or ""
    else
        abs_path = ""
    end
    local rel = abs_path ~= "" and vim.fn.fnamemodify(abs_path, ":.") or ("[buf #%d]"):format(bufnr or 0)
    local line_text = read_line(bufnr, lnum)
    return {
        name = name,
        scope = scope,
        bufnr = bufnr or 0,
        lnum = lnum,
        col = col,
        rel_path = rel,
        abs_path = abs_path,
        line_text = line_text,
        filter_text = name .. " " .. scope .. " " .. rel .. " " .. line_text,
    }
end

local function order_key(name)
    -- Group: A-Z first, a-z next, 0-9, then specials.
    local b = name:byte()
    if b >= 65 and b <= 90 then return 1, name end       -- A-Z
    if b >= 97 and b <= 122 then return 2, name end      -- a-z
    if b >= 48 and b <= 57 then return 3, name end       -- 0-9
    return 4, name
end

---@return FuzzyMarkEntry[]
function M.collect()
    local entries = {}
    local cur_buf = vim.api.nvim_get_current_buf()

    local ok_g, globals = pcall(vim.fn.getmarklist)
    if ok_g and type(globals) == "table" then
        for _, m in ipairs(globals) do
            local e = entry_from_mark(m, "global", nil)
            if e then entries[#entries + 1] = e end
        end
    end

    local ok_l, locals = pcall(vim.fn.getmarklist, cur_buf)
    if ok_l and type(locals) == "table" then
        for _, m in ipairs(locals) do
            local e = entry_from_mark(m, "local", cur_buf)
            if e then entries[#entries + 1] = e end
        end
    end

    table.sort(entries, function(a, b)
        local ag, an = order_key(a.name)
        local bg, bn = order_key(b.name)
        if ag ~= bg then return ag < bg end
        return an < bn
    end)
    return entries
end

function M.filter_text(entry) return entry.filter_text or entry.name or "" end

function M.make_render_context(entries, width)
    local max_path = 0
    for _, e in ipairs(entries) do
        if #e.rel_path > max_path then max_path = #e.rel_path end
    end
    local path_cap = math.max(12, math.floor(width * 0.35))
    return { path_width = math.min(max_path, path_cap) }
end

function M.format_entry(entry, ctx, width)
    ctx = ctx or { path_width = #(entry.rel_path or "") }
    local scope_glyph = entry.scope == "global" and "G" or "L"
    local loc = ("%d:%d"):format(entry.lnum or 0, entry.col or 0)
    local name_field = pad(entry.name, 2)
    local path = pad(truncate(entry.rel_path or "", ctx.path_width), ctx.path_width)
    local row = name_field .. " " .. scope_glyph .. " " .. pad(loc, 10) .. " " .. path
    local line_text = entry.line_text or ""
    if width then
        local available = width - #row - 1
        if available > 0 then row = row .. " " .. truncate(line_text, available) end
    else
        row = row .. " " .. line_text
    end
    if width and #row > width then return truncate(row, width) end
    return row
end

return M

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
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        local ok = pcall(vim.fn.bufload, bufnr)
        if not ok then return "" end
    end
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum - 1, lnum, false)
    if not ok or not lines or not lines[1] then return "" end
    return (lines[1]:gsub("^%s+", ""))
end

---@class FuzzyJumpEntry
---@field current boolean       -- true for the entry at the current jump-list position
---@field bufnr integer
---@field lnum integer
---@field col integer
---@field path string           -- buffer name (may be empty/anonymous)
---@field rel_path string       -- shortened to cwd
---@field abs_path string       -- absolute path or empty for unnamed buffer
---@field line_text string
---@field filter_text string

---@return FuzzyJumpEntry[]
function M.collect()
    local jl = vim.fn.getjumplist()
    local jumps, curidx = jl[1], jl[2]
    if type(jumps) ~= "table" then return {} end
    local entries = {}
    -- :jumps shows oldest first; reverse for newest-first picker order.
    -- curidx is 0-based into the original list; convert to a 1-based index
    -- on the reversed list.
    local current_orig_idx = (curidx or 0) + 1
    for i = #jumps, 1, -1 do
        local j = jumps[i]
        if type(j) == "table" and j.bufnr and j.bufnr > 0 and vim.api.nvim_buf_is_valid(j.bufnr) then
            local name = vim.api.nvim_buf_get_name(j.bufnr)
            local rel = name ~= "" and vim.fn.fnamemodify(name, ":.") or ("[No Name #%d]"):format(j.bufnr)
            local line_text = read_line(j.bufnr, j.lnum)
            entries[#entries + 1] = {
                current = i == current_orig_idx,
                bufnr = j.bufnr,
                lnum = j.lnum or 1,
                col = (j.col or 0) + 1,
                path = name,
                rel_path = rel,
                abs_path = name ~= "" and vim.fn.fnamemodify(name, ":p") or "",
                line_text = line_text,
                filter_text = rel .. " " .. line_text,
            }
        end
    end
    return entries
end

---@param entry FuzzyJumpEntry
function M.filter_text(entry) return entry.filter_text or entry.rel_path or "" end

---@param entries FuzzyJumpEntry[]
---@param width integer
function M.make_render_context(entries, width)
    local max_path = 0
    for _, e in ipairs(entries) do
        if #e.rel_path > max_path then max_path = #e.rel_path end
    end
    local path_cap = math.max(12, math.floor(width * 0.35))
    return { path_width = math.min(max_path, path_cap) }
end

---@param entry FuzzyJumpEntry
---@param ctx? { path_width: integer }
---@param width? integer
function M.format_entry(entry, ctx, width)
    ctx = ctx or { path_width = #(entry.rel_path or "") }
    local mark = entry.current and ">" or " "
    local loc = ("%d:%d"):format(entry.lnum or 0, entry.col or 0)
    local path = pad(truncate(entry.rel_path or "", ctx.path_width), ctx.path_width)
    local row = mark .. " " .. pad(loc, 10) .. " " .. path
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

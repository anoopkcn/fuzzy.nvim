-- Treesitter syntax highlighting for the matched text in fuzzy-created
-- quickfix lists. Mirrors the picker's grep highlighting so the qf window
-- reads the same way the live-grep picker does.
--
-- Highlights are applied via extmarks in a dedicated namespace. The text
-- portion of each qf line is located by suffix-matching item.text against
-- the rendered line (works with the default qf format and with most
-- quickfixtextfunc setups; bails cleanly when the suffix doesn't match).

local M = {}

local ns = vim.api.nvim_create_namespace("fuzzy_qf_highlight")
M.namespace = ns

-- Cache: bufnr -> last applied qf list id. Used by the autocmd hook to skip
-- re-highlighting when the list hasn't changed (cursor moves within a list).
local last_applied = {}

-- qf_id -> true while a streaming updater owns highlight application. The
-- autocmd defers to the streamer to avoid double-applying when :copen fires
-- BufWinEnter mid-stream.
local streaming = {}

--- Mark a qf list as actively streamed. While set, the autocmd hook leaves
--- highlight management to the streaming updater.
---@param qf_id integer
---@param on boolean
function M.set_streaming(qf_id, on)
    if on then streaming[qf_id] = true else streaming[qf_id] = nil end
end

local function enabled()
    local ok, config = pcall(require, "fuzzy.config")
    return ok and config.get().grep_syntax_highlight ~= false
end

local function find_qf_window(qf_id)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local info = vim.fn.getwininfo(win)
        if info[1] and info[1].quickfix == 1 and info[1].loclist == 0 then
            local list = vim.fn.getqflist({ winid = win, id = 0 })
            if list and list.id == qf_id then
                return win
            end
        end
    end
    return nil
end

-- The default qf renderer strips leading whitespace from item.text, so the
-- on-buffer text is the left-trimmed version. Locate that trimmed text at the
-- end of the rendered line. Returns the 0-indexed byte offset where the
-- displayed text begins and the trimmed text itself, or nil if it doesn't
-- align (e.g. text spans a newline, or quickfixtextfunc reshaped the line).
local function text_offset(line, text)
    if not text or text == "" then return nil end
    local trimmed = text:gsub("^%s+", "")
    if trimmed == "" then return nil end
    if #line < #trimmed then return nil end
    if line:sub(#line - #trimmed + 1) == trimmed then
        return #line - #trimmed, trimmed
    end
    return nil
end

local function highlight_lines(bufnr, items, start_row, end_row)
    local ts_highlight = require("fuzzy.picker.ts_highlight")
    if end_row > #items then end_row = #items end
    if start_row >= end_row then return end

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
    for offset, line in ipairs(lines) do
        local row = start_row + offset - 1
        local item = items[row + 1]
        if item and item.text and item.text ~= "" then
            local filename = item.filename
            if (not filename or filename == "") and item.bufnr and item.bufnr > 0 then
                filename = vim.api.nvim_buf_get_name(item.bufnr)
            end
            if filename and filename ~= "" then
                local off, displayed = text_offset(line, item.text)
                if off then
                    local hls = ts_highlight.get_line_highlights(filename, displayed)
                    if hls then
                        for _, cap in ipairs(hls) do
                            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, off + cap.col, {
                                end_col = off + cap.end_col,
                                hl_group = cap.hl_group,
                                priority = 120,
                                strict = false,
                            })
                        end
                    end
                end
            end
        end
    end
end

local function get_list_if_fuzzy(qf_id)
    local list = vim.fn.getqflist({ id = qf_id, items = 1, context = 1 })
    if not list or not list.items or #list.items == 0 then return nil end
    if not (type(list.context) == "table" and list.context.fuzzy) then return nil end
    return list
end

--- Apply highlights to a specific row range of the qf buffer for `qf_id`.
--- Used by streaming flushes to color only newly-appended rows.
---@param qf_id integer
---@param start_row integer 0-indexed start row (inclusive)
---@param end_row integer 0-indexed end row (exclusive)
function M.apply_range(qf_id, start_row, end_row)
    if not enabled() then return end
    local list = get_list_if_fuzzy(qf_id)
    if not list then return end
    local winid = find_qf_window(qf_id)
    if not winid then return end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    highlight_lines(bufnr, list.items, start_row, end_row)
    last_applied[bufnr] = qf_id
end

--- Clear and re-apply highlights for the full qf buffer of `qf_id`.
---@param qf_id integer
function M.apply_all(qf_id)
    if not enabled() then return end
    local list = get_list_if_fuzzy(qf_id)
    if not list then return end
    local winid = find_qf_window(qf_id)
    if not winid then return end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    highlight_lines(bufnr, list.items, 0, #list.items)
    last_applied[bufnr] = qf_id
end

--- Autocmd entry point. Refreshes highlights when the qf buffer's list id
--- has changed since the last apply. Cheap when nothing changed (only a
--- getqflist + table lookup). Clears old extmarks when switching to a list
--- that isn't ours so they don't sit misaligned on the new content.
function M.maybe_refresh()
    if vim.bo.buftype ~= "quickfix" then return end
    local id = vim.fn.getqflist({ id = 0 }).id
    if streaming[id] then return end
    local bufnr = vim.api.nvim_get_current_buf()
    if last_applied[bufnr] == id then return end

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    last_applied[bufnr] = id  -- record now so a non-fuzzy list doesn't retry
    if id and id > 0 and get_list_if_fuzzy(id) then
        M.apply_all(id)
    end
end

return M

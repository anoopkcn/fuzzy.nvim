local lsp = require("fuzzy.lsp")
local quickfix = require("fuzzy.quickfix")
local util = require("fuzzy.util")
local doc_symbols = require("fuzzy.commands.lsp_symbols")
local live_grep = require("fuzzy.picker.live_grep")

local COMMAND_NAME = doc_symbols.COMMAND_NAME
local METHOD = doc_symbols.METHOD

-- Brief synchronous wait so warm LSPs (responding in <250ms) open the
-- picker already populated — no visible empty/loading flash. If the
-- server doesn't respond in this window we fall through to the
-- empty-then-poll path so we still feel responsive on cold/slow servers.
local SYNC_WAIT_MS = 250

-- On a freshly-opened buffer most language servers return null/empty for
-- documentSymbol until they finish indexing. Poll until either results
-- arrive, the picker closes, or we hit MAX_WAIT_MS (safety cap so a
-- never-responding server doesn't leak a timer).
local POLL_INTERVAL_MS = 500
local MAX_WAIT_MS = 30000

local M = {}

local function jump_to(entry)
    local qf = entry and entry.qf
    if not qf or not qf.filename then return end
    if not util.open_file(qf.filename) then return end
    pcall(vim.api.nvim_win_set_cursor, 0, { qf.lnum or 1, math.max((qf.col or 1) - 1, 0) })
    pcall(vim.cmd, "normal! zv")
end

local function build_entries(items)
    local entries = {}
    for i, item in ipairs(items) do entries[i] = lsp.make_entry(item) end
    return entries
end

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local bufnr = vim.api.nvim_get_current_buf()
    if not lsp.require_clients(bufnr, METHOD, COMMAND_NAME) then return end

    local picker
    local cancel_request = nil
    local retry_timer = vim.uv.new_timer()
    local retry_timer_closed = false
    local start_ms = vim.uv.now()

    -- Stash for the first response: it may arrive during the synchronous
    -- pre-open wait (before `picker` exists) or after.
    local first_arrived = false
    local first_items = nil
    local first_err = nil

    local function close_timer()
        if retry_timer_closed then return end
        retry_timer_closed = true
        retry_timer:stop()
        retry_timer:close()
    end

    local function apply_response(items, err)
        if not picker or picker.is_closed() then return end
        if err then
            if picker.set_loading then picker.set_loading(false) end
            vim.notify(COMMAND_NAME .. ": " .. err, vim.log.levels.WARN)
            picker.set_title(COMMAND_NAME .. " (error)")
            return
        end
        if items and #items > 0 then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_items(build_entries(items))
            return
        end
        local elapsed = vim.uv.now() - start_ms
        if elapsed >= MAX_WAIT_MS then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_title(COMMAND_NAME .. " (no symbols)")
            return
        end
        picker.set_title(("%s (waiting for LSP… %ds)"):format(
            COMMAND_NAME, math.floor(elapsed / 1000)))
        if retry_timer_closed then return end
        retry_timer:start(POLL_INTERVAL_MS, 0, vim.schedule_wrap(function()
            if picker.is_closed() or retry_timer_closed then return end
            cancel_request = lsp.request_document_symbols(bufnr, apply_response)
        end))
    end

    -- Fire the request first, then wait briefly for it. If the response
    -- arrives before the picker is opened it's stashed; the open-path
    -- consumes it. If it arrives after, apply_response handles it directly.
    cancel_request = lsp.request_document_symbols(bufnr, function(items, err)
        if picker then
            apply_response(items, err)
        else
            first_arrived = true
            first_items = items
            first_err = err
        end
    end)

    vim.wait(SYNC_WAIT_MS, function() return first_arrived end, 10)

    local initial_items = {}
    if first_items and #first_items > 0 then
        initial_items = build_entries(first_items)
    end

    picker = picker_open({
        items = initial_items,
        prompt = "DocSymbols",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = doc_symbols.format_entry,
        filter_text = doc_symbols.filter_text,
        make_render_context = doc_symbols.make_render_context,
        row_highlight = function(buf, ns, row, entry, text, ctx, prefix_len)
            if not ctx then return end
            for _, range in ipairs(doc_symbols.highlight_ranges(entry, ctx, text)) do
                if range.end_col >= range.start_col then
                    vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len + range.start_col - 1, {
                        end_col = prefix_len + range.end_col,
                        hl_group = range.group,
                        priority = 120,
                    })
                end
            end
        end,
        preview_source = {
            kind = "file",
            resolve = function(entry)
                local qf = entry and entry.qf
                if not qf or not qf.filename then return nil end
                return { path = qf.filename, lnum = qf.lnum, col = qf.col }
            end,
        },
        on_select = function(entry) jump_to(entry) end,
        on_marked = function(marked, picked)
            local paths = vim.iter(marked)
                :map(function(e) return e.qf and e.qf.filename or nil end)
                :filter(function(p) return p ~= nil end)
                :totable()
            util.load_files(paths)
            local target = live_grep.pick_marked_target(marked, picked, function(e)
                return e.qf and e.qf.filename or nil
            end)
            if target then jump_to(target) end
        end,
        on_quickfix = function(visible)
            if #visible == 0 then
                vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                return
            end
            local qf_items = vim.iter(visible)
                :map(function(e) return e.qf end)
                :filter(function(qf) return qf ~= nil end)
                :totable()
            quickfix.update(qf_items, { title = COMMAND_NAME, command = COMMAND_NAME })
            quickfix.open_if_results(#qf_items)
        end,
        on_close = function()
            if cancel_request then pcall(cancel_request) end
            close_timer()
        end,
    })

    if not picker then
        close_timer()
        return
    end

    -- Already populated → done. No loading, no polling.
    if #initial_items > 0 then return picker end

    -- Empty path. Show loading, drain the stashed empty/error response
    -- (which sets up the first retry), or wait for the in-flight one.
    if picker.set_loading then picker.set_loading(true) end
    if first_arrived then
        apply_response(first_items, first_err)
    end

    return picker
end

return M

local lsp = require("fuzzy.lsp")
local quickfix = require("fuzzy.quickfix")
local util = require("fuzzy.util")
local proj_symbols = require("fuzzy.commands.lsp_project_symbols")
local live_grep = require("fuzzy.picker.live_grep")

local COMMAND_NAME = proj_symbols.COMMAND_NAME
local METHOD = proj_symbols.METHOD

local DEBOUNCE_MS = 150

local M = {}

local function jump_to(entry)
    local qf = entry and entry.qf
    if not qf or not qf.filename then return end
    if not util.open_file(qf.filename) then return end
    pcall(vim.api.nvim_win_set_cursor, 0, { qf.lnum or 1, math.max((qf.col or 1) - 1, 0) })
    pcall(vim.cmd, "normal! zv")
end

local function items_to_entries(items)
    local entries = {}
    for i, item in ipairs(items) do
        local entry = lsp.make_entry(item)
        entry.rel_path = item.filename and vim.fn.fnamemodify(item.filename, ":.") or ""
        entries[i] = entry
    end
    return entries
end

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local bufnr = vim.api.nvim_get_current_buf()
    if not lsp.require_any_workspace_client(COMMAND_NAME) then return end

    local timer = vim.uv.new_timer()
    local timer_closed = false
    local generation = 0
    local cancel_in_flight = nil
    local last_settled_query = ""

    local function stop_timer(close)
        if timer_closed then return end
        timer:stop()
        if close then
            timer:close()
            timer_closed = true
        end
    end

    local function cancel_request()
        if cancel_in_flight then
            pcall(cancel_in_flight)
            cancel_in_flight = nil
        end
    end

    local function schedule_search(query, picker)
        generation = generation + 1
        local gen = generation
        stop_timer(false)
        cancel_request()

        if not query:match("%S") then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_items({})
            return
        end

        if picker.set_loading then picker.set_loading(true) end
        timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            if gen ~= generation or picker.is_closed() then return end
            cancel_in_flight = lsp.request_workspace_symbols(bufnr, query, function(items, err)
                if gen ~= generation or picker.is_closed() then return end
                cancel_in_flight = nil
                if picker.set_loading then picker.set_loading(false) end
                if err then
                    vim.notify(COMMAND_NAME .. ": " .. err, vim.log.levels.WARN)
                    return
                end
                last_settled_query = query
                picker.set_items(items_to_entries(items))
            end)
        end))
    end

    local function stop_all()
        generation = generation + 1
        stop_timer(true)
        cancel_request()
    end

    return picker_open({
        items = {},
        prompt = "ProjectSymbols",
        initial_query = opts.initial_query,
        filter_items = false,
        highlight_paths = false,
        format_item = proj_symbols.format_entry,
        filter_text = proj_symbols.filter_text,
        make_render_context = proj_symbols.make_render_context,
        row_highlight = function(buf, ns, row, entry, text, ctx, prefix_len)
            if not ctx then return end
            for _, range in ipairs(proj_symbols.highlight_ranges(entry, ctx, text)) do
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
            kind = "grep",
            resolve = function(entry)
                local qf = entry and entry.qf
                if not qf or not qf.filename then return nil end
                return { path = qf.filename, lnum = qf.lnum, col = qf.col }
            end,
        },
        on_change = schedule_search,
        on_close = stop_all,
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
            local title = (last_settled_query ~= "" and (COMMAND_NAME .. " [" .. last_settled_query .. "]"))
                or COMMAND_NAME
            quickfix.update(qf_items, { title = title, command = COMMAND_NAME })
            quickfix.open_if_results(#qf_items)
        end,
    })
end

return M

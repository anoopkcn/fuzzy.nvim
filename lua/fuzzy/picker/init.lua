local config = require("fuzzy.config")
local match = require("fuzzy.match")
local quickfix = require("fuzzy.quickfix")
local util = require("fuzzy.util")

local highlight = require("fuzzy.picker.highlight")
local window = require("fuzzy.picker.window")
local live_grep = require("fuzzy.picker.live_grep")

local HL = highlight.HL

local M = {}

local picker_sources = {
    git_branches  = "fuzzy.commands.git_branches",
    git_worktrees = "fuzzy.commands.git_worktrees",
    -- Future:
    -- git_commits = "fuzzy.commands.git_commits",
    -- git_status  = "fuzzy.commands.git_status",
    -- git_stashes = "fuzzy.commands.git_stashes",
}

-- Two namespaces so the per-key navigation update can wipe ONLY the cursor
-- highlight without disturbing match/path/row extmarks placed by render().
local ns_content = vim.api.nvim_create_namespace("fuzzy.picker")
local ns_cursor  = vim.api.nvim_create_namespace("fuzzy.picker.cursor")

-- Filter debounce: short, just enough to coalesce keystrokes from key-repeat
-- so a held-down key doesn't queue a synchronous filter pass per repeat.
local FILTER_DEBOUNCE_MS = 30
-- Render throttle: ~30Hz coalescing of streamed appends. Direct user actions
-- (typing, moving cursor, selecting) still render immediately.
local RENDER_THROTTLE_MS = 33

-- Buffer prefix is always two spaces. The visual selection/cursor markers
-- are rendered as overlay virt_text extmarks at col 0 / col 1 so byte
-- offsets in the result buffer stay constant regardless of state or font.
local PREFIX_PAD = "  "
local PREFIX_LEN = #PREFIX_PAD

local function picker_glyphs()
    local win_cfg = config.get().window
    if win_cfg.nerd_font then
        return { sel = "●", cursor = "▌" }
    end
    return { sel = "+", cursor = "│" }
end

---@class FuzzyPickerOpts
---@field items any[]
---@field on_select? fun(item: any, visible_items: any[], all_items: any[])
---@field on_marked? fun(marked_items: any[], picked_item: any, visible_items: any[], all_items: any[])
---@field on_submit? fun(query: string)
---@field on_change? fun(query: string, picker: FuzzyPickerController)
---@field on_close? fun()
---@field on_quickfix? fun(visible_items: any[], all_items: any[])
---@field format_item? fun(item: any, ctx?: table, width?: integer): string
---@field filter_text? fun(item: any): string
---@field make_render_context? fun(items: any[], width: integer): table|nil
---@field row_highlight? fun(buf: integer, ns: integer, row: integer, item: any, text: string, ctx: table|nil)
---@field filter_items? boolean
---@field highlight_matches? boolean
---@field highlight_fn? fun(query: string, line: string): integer[]|nil
---@field highlight_paths? boolean
---@field prompt? string
---@field title? string
---@field height? integer
---@field initial_query? string
---@field on_setup? fun(picker: FuzzyPickerController, imap: fun(lhs: string, rhs: function), input_buf: integer)

---@class FuzzyPickerController
---@field set_items fun(items: any[])
---@field append_items fun(items: any[])
---@field get_items fun(): any[]
---@field get_query fun(): string
---@field is_closed fun(): boolean
---@field set_title fun(title: string)
---@field accept fun()
---@field close fun()

---@param opts FuzzyPickerOpts
---@return FuzzyPickerController
local function open(opts)
    local items = opts.items or {}
    local prompt = opts.prompt or "Fuzzy"
    local title  = opts.title or prompt
    local on_select   = opts.on_select or function() end
    local on_marked   = opts.on_marked
    local on_submit   = opts.on_submit
    local on_change   = opts.on_change
    local on_close    = opts.on_close
    local on_quickfix = opts.on_quickfix
    local on_setup    = opts.on_setup
    local format_item = opts.format_item or function(item) return item end
    local filter_text = opts.filter_text or function(item)
        if type(item) == "string" then return item end
        local ok, text = pcall(format_item, item, nil, nil)
        if not ok then return "" end
        return text and tostring(text) or ""
    end
    local make_render_context = opts.make_render_context
    local row_highlight   = opts.row_highlight
    local filter_items    = opts.filter_items ~= false
    local highlight_matches = opts.highlight_matches ~= false
    local highlight_fn    = opts.highlight_fn or match.positions
    local highlight_paths = opts.highlight_paths ~= false

    local view = window.create({
        title = title,
        ns = ns_content,
        item_count = #items,
    })
    local result_buf = view.result_buf
    local input_buf  = view.input_buf
    local frame_win  = view.frame_win

    local glyphs = picker_glyphs()
    local cursor_indicator = config.get().window.cursor_indicator ~= false
    local show_count = config.get().window.show_count ~= false

    -- Local controller state.
    local current = items
    local cursor = 1
    local scroll = 0
    local closed = false
    local controller = {}
    local selected = {}
    local selected_count = 0

    -- Cap scored results to a small multiple of visible rows. match.filter
    -- still walks every item to score, but trims after sort.
    local match_limit = math.max(view.max_height * 10, 200)

    local filter_timer = vim.uv.new_timer()
    local render_timer = vim.uv.new_timer()
    local timers_closed = false
    local render_pending = false

    local function close_timers()
        if timers_closed then return end
        timers_closed = true
        filter_timer:stop(); filter_timer:close()
        render_timer:stop(); render_timer:close()
    end

    local function read_query()
        return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    end

    -- Run a user-supplied callback without taking down the picker. We notify
    -- on schedule (notify isn't safe from libuv contexts in all cases).
    local function safe_call(fn, ...)
        if not fn then return true end
        local ok, err = pcall(fn, ...)
        if not ok then
            local msg = "Fuzzy: callback error: " .. tostring(err)
            vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
        end
        return ok, err
    end

    local function item_text(item, ctx)
        local ok, text = pcall(format_item, item, ctx, view.width)
        if not ok then
            vim.schedule(function()
                vim.notify("Fuzzy: format_item error: " .. tostring(text),
                    vim.log.levels.ERROR)
            end)
            return ""
        end
        return text and tostring(text) or ""
    end

    -- Update only the cursor highlight extmark. Used by navigation when the
    -- visible page hasn't changed — far cheaper than a full render() because
    -- it touches one extmark in one tiny namespace.
    local function update_cursor_hl()
        vim.api.nvim_buf_clear_namespace(result_buf, ns_cursor, 0, -1)
        local total = #current
        local n = math.min(view.displayed, math.max(0, total - scroll))
        local row = cursor - scroll - 1
        if row >= 0 and row < n then
            vim.api.nvim_buf_set_extmark(result_buf, ns_cursor, row, 0, {
                end_row = row + 1, hl_group = HL.sel, hl_eol = true, priority = 50,
            })
            if cursor_indicator then
                vim.api.nvim_buf_set_extmark(result_buf, ns_cursor, row, 0, {
                    virt_text = {{ glyphs.cursor, HL.cursor }},
                    virt_text_pos = "overlay",
                    priority = 220,
                })
            end
        end
    end

    local function render()
        view.resize(#current)
        local total = #current
        local n = math.min(view.displayed, math.max(0, total - scroll))
        if show_count then view.set_count(total, #items) end
        local query = read_query()
        local render_ctx = make_render_context and make_render_context(current, view.width) or nil

        -- Build buffer lines + per-row metadata in a single pass.
        local lines = {}
        local texts = {}
        for i = 1, n do
            local item = current[scroll + i]
            local text = item_text(item, render_ctx)
            texts[i] = text
            lines[i] = PREFIX_PAD .. text
        end
        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(result_buf, ns_content, 0, -1)

        for i = 1, n do
            local row = i - 1
            local text = texts[i]
            local line_len = #lines[i]
            local item = current[scroll + i]

            if selected[item] then
                -- Overlay virt_text at col 1: stays out of the way of the
                -- cursor bar (col 0) so both can coexist on the same row.
                vim.api.nvim_buf_set_extmark(result_buf, ns_content, row, 1, {
                    virt_text = {{ glyphs.sel, HL.selected }},
                    virt_text_pos = "overlay",
                    priority = 150,
                })
            end

            if highlight_paths then
                local slash = text:find("/[^/]*$")
                if slash then
                    vim.api.nvim_buf_set_extmark(result_buf, ns_content, row, PREFIX_LEN, {
                        end_col = PREFIX_LEN + slash, hl_group = HL.dir, priority = 100,
                    })
                end
                vim.api.nvim_buf_set_extmark(result_buf, ns_content, row, PREFIX_LEN + (slash or 0), {
                    end_col = line_len, hl_group = HL.file, priority = 100,
                })
            end

            if row_highlight then
                row_highlight(result_buf, ns_content, row, item, text, render_ctx)
            end

            if highlight_matches and query ~= "" then
                local ok, pos = pcall(highlight_fn, query, text)
                if ok and pos and #pos > 0 then
                    -- Merge contiguous positions into a single extmark range.
                    -- Typical queries match runs of consecutive bytes; one
                    -- extmark per run is a major saving over one per byte.
                    local run_start = pos[1]
                    local run_end = pos[1]
                    for k = 2, #pos do
                        local p = pos[k]
                        if p == run_end + 1 then
                            run_end = p
                        else
                            vim.api.nvim_buf_set_extmark(result_buf, ns_content, row, PREFIX_LEN + run_start - 1, {
                                end_col = PREFIX_LEN + run_end, hl_group = HL.match, priority = 200,
                            })
                            run_start = p
                            run_end = p
                        end
                    end
                    vim.api.nvim_buf_set_extmark(result_buf, ns_content, row, PREFIX_LEN + run_start - 1, {
                        end_col = PREFIX_LEN + run_end, hl_group = HL.match, priority = 200,
                    })
                end
            end
        end

        update_cursor_hl()
    end

    local function update_current(query, reset_cursor)
        if filter_items and query ~= "" then
            local scored = match.filter(query, items, match_limit, filter_text)
            local out = {}
            for i = 1, #scored do out[i] = scored[i].item end
            current = out
        else
            current = items
        end

        if reset_cursor then
            cursor = 1
            scroll = 0
        else
            cursor = math.max(1, math.min(cursor, math.max(1, #current)))
            scroll = math.max(0, math.min(scroll, math.max(0, #current - view.max_height)))
        end
    end

    -- Coalescing renderer for streamed appends: arms a single timer that
    -- fires the next render at ~RENDER_THROTTLE_MS. Direct user actions still
    -- call render() inline so they feel instant.
    local function render_soon()
        if closed or timers_closed then return end
        if render_pending then return end
        render_pending = true
        render_timer:start(RENDER_THROTTLE_MS, 0, vim.schedule_wrap(function()
            render_pending = false
            if closed then return end
            render()
        end))
    end

    function controller.set_items(new_items)
        items = new_items or {}
        selected = {}
        selected_count = 0
        update_current(read_query(), true)
        render()
    end

    function controller.append_items(new_items)
        if not new_items or #new_items == 0 then return end
        vim.list_extend(items, new_items)
        update_current(read_query(), false)
        render_soon()
    end

    function controller.get_items() return items end
    function controller.get_query() return read_query() end
    function controller.is_closed() return closed end

    function controller.set_title(new_title)
        if type(new_title) ~= "string" or new_title == "" then
            new_title = prompt
        end
        title = new_title
        view.set_title(title)
    end

    function controller.set_loading(on)
        view.set_loading(on)
    end

    local function update_filter()
        local query = read_query()
        if on_change then
            -- on_change runs immediately so live-grep can do its own (longer)
            -- internal debounce; we still debounce the local filter+render.
            safe_call(on_change, query, controller)
            if not filter_items then return end
        end
        if timers_closed then return end
        filter_timer:stop()
        filter_timer:start(FILTER_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            if closed then return end
            update_current(read_query(), true)
            render()
        end))
    end

    local cleanup_group  -- assigned after autocmds register

    local function close()
        if closed then return end
        closed = true
        close_timers()
        safe_call(on_close)
        if cleanup_group then pcall(vim.api.nvim_del_augroup_by_id, cleanup_group) end
        pcall(vim.cmd.stopinsert)
        view.close()
    end

    controller.close = close

    local function accept()
        if on_submit then
            local query = read_query()
            close()
            if query:match("%S") then
                safe_call(on_submit, query)
            end
            return
        end

        local picked = current[cursor]
        local visible_items = current
        local all_items = items
        local marked_items = nil
        if selected_count > 0 then
            marked_items = {}
            for _, item in ipairs(items) do
                if selected[item] then
                    marked_items[#marked_items + 1] = item
                end
            end
        end
        close()
        if marked_items then
            if on_marked then
                safe_call(on_marked, marked_items, picked, visible_items, all_items)
            elseif picked then
                safe_call(on_select, picked, visible_items, all_items)
            end
            return
        end
        if picked then safe_call(on_select, picked, visible_items, all_items) end
    end

    controller.accept = accept

    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = input_buf,
        callback = update_filter,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = input_buf,
        once = true,
        callback = close,
    })

    -- Fallbacks if BufLeave doesn't fire (buffer wiped externally) or the user
    -- closes the input window via :q. Keep in one group so we don't leak.
    cleanup_group = vim.api.nvim_create_augroup(
        "fuzzy.picker.cleanup." .. input_buf, { clear = true })

    vim.api.nvim_create_autocmd("BufWipeout", {
        group = cleanup_group,
        buffer = input_buf,
        callback = close,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = cleanup_group,
        pattern = { tostring(view.input_win), tostring(view.result_win), tostring(frame_win) },
        callback = close,
    })

    -- Reflowing floats correctly across resize is more code than it's worth;
    -- close the picker on resize so the user can re-open at the new dims.
    vim.api.nvim_create_autocmd("VimResized", {
        group = cleanup_group,
        callback = close,
    })

    local function imap(lhs, rhs)
        vim.keymap.set("i", lhs, rhs, { buffer = input_buf, nowait = true, silent = true })
    end

    -- Move cursor by `delta`. Fast path: when scroll position doesn't change,
    -- only update the cursor highlight extmark. Full render only happens when
    -- we have to scroll the visible window.
    local function move(delta)
        local total = #current
        if total == 0 then return end
        cursor = math.max(1, math.min(total, cursor + delta))
        local page = math.max(1, view.displayed)
        local prev_scroll = scroll
        if cursor < scroll + 1 then
            scroll = cursor - 1
        elseif cursor > scroll + page then
            scroll = cursor - page
        end
        if scroll == prev_scroll then
            update_cursor_hl()
        else
            render()
        end
    end

    -- Selection toggle: marks the item, advances cursor, then full-renders so
    -- the prefix/highlight stays correct. Selection toggling is rare enough
    -- that the cost of a full render is negligible.
    local function select_current()
        local item = current[cursor]
        if item == nil then return end
        if not selected[item] then
            selected[item] = true
            selected_count = selected_count + 1
        end
        cursor = math.min(#current, cursor + 1)
        local page = math.max(1, view.displayed)
        if cursor > scroll + page then scroll = cursor - page end
        render()
    end

    local function deselect_current()
        local item = current[cursor]
        if item == nil then return end
        if selected[item] then
            selected[item] = nil
            selected_count = selected_count - 1
        end
        cursor = math.max(1, cursor - 1)
        if cursor < scroll + 1 then scroll = cursor - 1 end
        render()
    end

    imap("<CR>",   accept)
    imap("<C-n>",  function() move(1) end)
    imap("<Down>", function() move(1) end)
    imap("<C-p>",  function() move(-1) end)
    imap("<Up>",   function() move(-1) end)
    imap("<Tab>",   select_current)
    imap("<S-Tab>", deselect_current)
    imap("<Esc>",   close)
    imap("<C-c>",   close)

    if on_quickfix then
        local qf_key = config.get().send_to_qf_key
        if qf_key and qf_key ~= "" then
            imap(qf_key, function()
                local to_send = current
                if selected_count > 0 then
                    to_send = {}
                    for _, item in ipairs(items) do
                        if selected[item] then
                            to_send[#to_send + 1] = item
                        end
                    end
                end
                local all = items
                close()
                safe_call(on_quickfix, to_send, all)
            end)
        end
    end

    if on_setup then
        safe_call(on_setup, controller, imap, input_buf)
    end

    render()
    if opts.initial_query and opts.initial_query ~= "" then
        vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { opts.initial_query })
        view.refresh_prompt()
        update_current(opts.initial_query, true)
        if on_change then safe_call(on_change, opts.initial_query, controller) end
        render()
        vim.cmd("startinsert!")
    else
        vim.cmd.startinsert()
    end
    return controller
end

---@param kind "files"|"buffers"|"grep"|"grep_in"|"helptags"|"commands"|"qflist"|"git_branches"|"git_worktrees"|"git_commits"|"git_status"|"git_stashes"
---@param opts? { bang?: boolean, initial_query?: string, initial_flags?: string[], fuzzy_only?: boolean, dir?: string }
local function open_for(kind, opts)
    opts = opts or {}
    local source_name = picker_sources[kind]
    if source_name then
        local source = require(source_name)
        source.collect(function(items)
            if not items or #items == 0 then
                vim.notify((source.empty_message or ((source.prompt or kind) .. ": no items found.")), vim.log.levels.INFO)
                return
            end

            open({
                items = items,
                prompt = source.prompt or kind,
                initial_query = opts.initial_query,
                format_item = source.format_entry,
                filter_text = source.filter_text,
                highlight_paths = source.highlight_paths == true,
                on_select = function(entry) source.select(entry) end,
            })
        end)
        return
    end

    if kind == "files" then
        local complete = require("fuzzy.complete")
        local files = complete.get_files() or {}
        if #files == 0 then
            vim.notify("Fuzzy: file cache is empty (try again in a moment).", vim.log.levels.INFO)
            return
        end
        return open({
            items = files,
            prompt = "Files",
            initial_query = opts.initial_query,
            on_select = function(path) util.open_file(path) end,
            on_marked = function(marked_items, picked_item)
                util.load_files(marked_items)
                local target = live_grep.pick_marked_target(marked_items, picked_item, function(item) return item end)
                if target then util.open_file(target) end
            end,
            on_quickfix = function(visible_items)
                if #visible_items == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = {}
                for i = 1, #visible_items do
                    local path = visible_items[i]
                    qf_items[i] = { filename = vim.fn.fnamemodify(path, ":p"), lnum = 1, col = 1, text = path }
                end
                quickfix.update(qf_items, { title = "FuzzyFiles", command = "FuzzyFiles" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    elseif kind == "buffers" then
        local bufs = util.get_listed_buffers()
        local items, by_path, by_path_abs = {}, {}, {}
        for _, b in ipairs(bufs) do
            local rel = vim.fn.fnamemodify(b.path, ":.")
            items[#items + 1] = rel
            by_path[rel] = b.bufnr
            by_path_abs[rel] = b.path
        end
        if #items == 0 then
            vim.notify("Fuzzy: no listed buffers.", vim.log.levels.INFO)
            return
        end
        return open({
            items = items,
            prompt = "Buffers",
            initial_query = opts.initial_query,
            on_select = function(rel)
                local bufnr = by_path[rel]
                if bufnr then util.switch_to_buffer(bufnr) end
            end,
            on_marked = function() end,
            on_quickfix = function(visible_items)
                if #visible_items == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = {}
                for i = 1, #visible_items do
                    local rel = visible_items[i]
                    local bufnr = by_path[rel]
                    qf_items[i] = { bufnr = bufnr, filename = by_path_abs[rel] or rel, lnum = 1, col = 1, text = rel }
                end
                quickfix.update(qf_items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    elseif kind == "grep" then
        return live_grep.open(opts, open)
    elseif kind == "grep_in" then
        return live_grep.open({
            dir = opts.dir,
            initial_query = opts.initial_query,
            initial_flags = opts.initial_flags,
        }, open)
    elseif kind == "helptags" then
        local helptags = require("fuzzy.commands.helptags")
        local tag_entries = helptags.collect()
        if #tag_entries == 0 then
            vim.notify("FuzzyHelp: no help tags found.", vim.log.levels.INFO)
            return
        end
        return open({
            items = tag_entries,
            prompt = "Help",
            initial_query = opts.initial_query,
            format_item = function(entry) return entry.tag .. "  " .. entry.filename_short end,
            filter_text = function(entry) return entry.tag .. "  " .. entry.filename_short end,
            on_select = function(entry)
                local ok, err = pcall(vim.cmd, { cmd = "help", args = { entry.tag } })
                if not ok then
                    vim.notify("FuzzyHelp: " .. tostring(err), vim.log.levels.ERROR)
                end
            end,
            on_quickfix = function(visible_items)
                if #visible_items == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = helptags.to_qf_items(visible_items)
                quickfix.update(qf_items, { title = "FuzzyHelp", command = "FuzzyHelp" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    elseif kind == "commands" then
        local commands = require("fuzzy.commands.commands")
        local entries = commands.collect()
        if #entries == 0 then
            vim.notify("FuzzyCommands: no commands found.", vim.log.levels.INFO)
            return
        end
        return open({
            items = entries,
            prompt = "Commands",
            initial_query = opts.initial_query,
            format_item = commands.format_entry,
            filter_text = commands.filter_text,
            make_render_context = commands.make_render_context,
            row_highlight = function(buf, row_ns, row, entry, text, ctx)
                if not ctx then return end
                for _, range in ipairs(commands.highlight_ranges(entry, ctx, text)) do
                    if range.end_col >= range.start_col then
                        vim.api.nvim_buf_set_extmark(buf, row_ns, row, PREFIX_LEN + range.start_col - 1, {
                            end_col = PREFIX_LEN + range.end_col,
                            hl_group = range.group,
                            priority = 120,
                        })
                    end
                end
            end,
            highlight_paths = false,
            on_select = function(entry)
                commands.prefill_cmdline(entry and entry.cmdline or nil)
            end,
        })
    elseif kind == "qflist" then
        local lists = quickfix.collect_history(opts.fuzzy_only)
        if #lists == 0 then
            vim.notify("No quickfix history.", vim.log.levels.INFO)
            return
        end
        return open({
            items = lists,
            prompt = "Quickfix",
            initial_query = opts.initial_query,
            highlight_paths = false,
            format_item = function(item) return ("%s (%d items)"):format(item.title, item.size) end,
            filter_text = function(item) return item.title end,
            on_select = function(item)
                quickfix.activate(item.nr)
                vim.cmd.copen()
            end,
        })
    end
end

M.open = open
M.open_for = open_for

return M

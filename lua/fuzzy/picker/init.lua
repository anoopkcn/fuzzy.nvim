local config = require("fuzzy.config")
local match = require("fuzzy.match")

local highlight = require("fuzzy.picker.highlight")
local window = require("fuzzy.picker.window")
local preview_mod = require("fuzzy.picker.preview")

local HL = highlight.HL

local M = {}

-- Registry of picker kinds → source module names. Each source module exports
-- M.open(opts, picker_open) which calls the engine to render its picker.
-- Use M.register_source(kind, modname) to add user-defined sources.
local picker_sources = {
    files               = "fuzzy.picker.sources.files",
    buffers             = "fuzzy.picker.sources.buffers",
    grep                = "fuzzy.picker.live_grep",
    helptags            = "fuzzy.picker.sources.helptags",
    commands            = "fuzzy.picker.sources.commands",
    keymaps             = "fuzzy.picker.sources.keymaps",
    qflist              = "fuzzy.picker.sources.qflist",
    git_branches        = "fuzzy.commands.git_branches",
    git_worktrees       = "fuzzy.commands.git_worktrees",
    lsp_symbols         = "fuzzy.picker.sources.lsp_symbols",
    lsp_project_symbols = "fuzzy.picker.sources.lsp_project_symbols",
    jumps               = "fuzzy.picker.sources.jumps",
    marks               = "fuzzy.picker.sources.marks",
    registers           = "fuzzy.picker.sources.registers",
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
---@field row_highlight? fun(buf: integer, ns: integer, row: integer, item: any, text: string, ctx: table|nil, prefix_len: integer)
---@field group_key? fun(item: any): any  When set together with `format_header`, items whose group_key differs from the previous item's are preceded by a header buffer row. Cursor still indexes items, not buffer rows.
---@field format_header? fun(item: any, ctx: table|nil, width: integer): string  Header text for the first item of a group. Required alongside `group_key` to enable grouped rendering.
---@field header_highlight? fun(buf: integer, ns: integer, row: integer, item: any, header_text: string, ctx: table|nil, prefix_len: integer)
---@field filter_items? boolean
---@field highlight_matches? boolean
---@field highlight_fn? fun(query: string, line: string): integer[]|nil
---@field highlight_paths? boolean
---@field prompt? string
---@field title? string
---@field height? integer
---@field initial_query? string
---@field on_setup? fun(picker: FuzzyPickerController, imap: fun(lhs: string, rhs: function), input_buf: integer)
---@field preview_source? { kind: "file"|"buffer"|"grep"|"help", resolve: fun(item: any): table|nil }

---@class FuzzyPickerController
---@field set_items fun(items: any[])
---@field append_items fun(items: any[])
---@field get_items fun(): any[]
---@field get_marked fun(): any[]
---@field get_cursor fun(): any|nil
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
    local group_key       = opts.group_key
    local format_header   = opts.format_header
    local header_highlight = opts.header_highlight
    local has_groups      = group_key ~= nil and format_header ~= nil
    local filter_items    = opts.filter_items ~= false
    local highlight_matches = opts.highlight_matches ~= false
    local highlight_fn    = opts.highlight_fn or match.positions
    local highlight_paths = opts.highlight_paths ~= false

    local view = window.create({
        title = title,
        ns = ns_content,
        item_count = #items,
        preview = opts.preview_source ~= nil,
        preview_visible = config.get().preview == true,
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
    local preview_ctrl = nil  -- set later if opts.preview_source is provided

    -- Cap scored results to a small multiple of visible rows. match.filter
    -- still walks every item to score, but trims after sort.
    local match_limit = math.max(view.max_height * 10, 200)

    local filter_timer = vim.uv.new_timer()
    local render_timer = vim.uv.new_timer()
    local timers_closed = false
    local render_pending = false

    -- Maps from visible item index (1-based, relative to `scroll`) to the
    -- buffer row where its data line lives. Refreshed by render(). Used by
    -- update_cursor_hl() to attach the cursor extmark at the correct row when
    -- group headers are inserted between items.
    local last_data_rows = {}

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
        local visible_idx = cursor - scroll
        local row
        if has_groups then
            row = last_data_rows[visible_idx]
        else
            local total = #current
            local n = math.min(view.displayed, math.max(0, total - scroll))
            local r = visible_idx - 1
            if r >= 0 and r < n then row = r end
        end
        if row then
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
        if preview_ctrl then preview_ctrl.refresh() end
    end

    -- Single rule used by row_cost / visible_count / render: emit a header
    -- iff `group_key(item)` is non-nil AND differs from the previous item's
    -- key (a nil-keyed previous item counts as "different" — needed for the
    -- "root files block, then first subdir item" transition in :FuzzyFiles).
    --
    -- For a 1-based index into `current`, returns the buffer row cost of
    -- emitting this item (2 if it starts a new group, 1 otherwise, 0 if the
    -- item doesn't exist). When grouping is disabled, every item costs 1.
    local function row_cost(idx)
        if not has_groups then
            return current[idx] and 1 or 0
        end
        local item = current[idx]
        if not item then return 0 end
        local ck = group_key(item)
        if ck == nil then return 1 end
        if idx == 1 then return 2 end
        local prev = current[idx - 1]
        if not prev then return 2 end
        local pk = group_key(prev)
        if pk == ck then return 1 end
        return 2
    end

    -- How many items fit in the visible window when scrolled to `s`, given
    -- the row budget `view.displayed`. Used by render() to admit items and by
    -- move()/select_current() to keep the cursor on-screen.
    local function visible_count(s)
        local total = #current
        if total == 0 or s >= total then return 0 end
        if not has_groups then
            return math.min(view.displayed, total - s)
        end
        local rows_used = 0
        local count = 0
        for i = 1, total - s do
            local item = current[s + i]
            if not item then break end
            local ck = group_key(item)
            local cost
            if ck == nil then
                cost = 1
            elseif i == 1 then
                if s == 0 then
                    cost = 2
                else
                    local pk = group_key(current[s])
                    cost = (pk == ck) and 1 or 2
                end
            else
                local pk = group_key(current[s + i - 1])
                cost = (pk == ck) and 1 or 2
            end
            if rows_used + cost > view.displayed then break end
            rows_used = rows_used + cost
            count = i
        end
        return count
    end

    -- Ensure `cursor` falls within the visible window by shifting `scroll`
    -- minimally. Row-aware: with groups, advancing scroll by 1 may free 1 or
    -- 2 rows depending on whether the leaving item brought a header along.
    local function clamp_scroll_to_cursor()
        local total = #current
        if total == 0 then
            cursor = 1
            scroll = 0
            return
        end
        if cursor < 1 then cursor = 1 end
        if cursor > total then cursor = total end
        if cursor < scroll + 1 then
            scroll = cursor - 1
        else
            while cursor > scroll + visible_count(scroll) do
                scroll = scroll + 1
                if scroll >= cursor then
                    scroll = cursor - 1
                    break
                end
            end
        end
        if scroll < 0 then scroll = 0 end
    end

    local function render()
        -- 1. Compute total buffer rows needed and size the window accordingly.
        local total = #current
        local total_rows
        if not has_groups then
            total_rows = total
        else
            total_rows = 0
            for i = 1, total do total_rows = total_rows + row_cost(i) end
        end
        view.resize(total_rows)

        -- 2. Clamp scroll so cursor is visible against the (possibly resized)
        --    row budget, then determine how many items the window can show.
        clamp_scroll_to_cursor()
        local n = visible_count(scroll)
        if show_count then view.set_count(total, #items) end
        local query = read_query()
        local render_ctx = make_render_context and make_render_context(current, view.width) or nil

        -- 3. Walk admitted items, emitting header + data lines in order and
        --    recording the buffer row of each component for the extmark pass.
        local lines = {}
        local texts = {}
        local data_rows = {}
        local header_rows = {}
        local header_texts = {}
        local row_count = 0

        for i = 1, n do
            local item = current[scroll + i]
            local emit_header = false
            if has_groups then
                local ck = group_key(item)
                if ck ~= nil then
                    if i == 1 then
                        if scroll == 0 then
                            emit_header = true
                        else
                            local pk = group_key(current[scroll])
                            emit_header = pk ~= ck
                        end
                    else
                        local pk = group_key(current[scroll + i - 1])
                        emit_header = pk ~= ck
                    end
                end
            end

            if emit_header then
                local ok, header_text = pcall(format_header, item, render_ctx, view.width)
                if not ok or type(header_text) ~= "string" then header_text = "" end
                header_rows[i] = row_count
                header_texts[i] = header_text
                lines[#lines + 1] = PREFIX_PAD .. header_text
                row_count = row_count + 1
            end

            local text = item_text(item, render_ctx)
            texts[i] = text
            data_rows[i] = row_count
            lines[#lines + 1] = PREFIX_PAD .. text
            row_count = row_count + 1
        end

        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(result_buf, ns_content, 0, -1)

        for i = 1, n do
            local row = data_rows[i]
            local text = texts[i]
            local line_len = #lines[row + 1]
            local item = current[scroll + i]

            -- Header row first (it sits visually above the data row).
            if header_rows[i] then
                local hrow = header_rows[i]
                local htext = header_texts[i]
                if header_highlight then
                    header_highlight(result_buf, ns_content, hrow, item, htext, render_ctx, PREFIX_LEN)
                end
            end

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
                row_highlight(result_buf, ns_content, row, item, text, render_ctx, PREFIX_LEN)
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

        last_data_rows = data_rows
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
            -- Don't bother clamping scroll here — render() calls
            -- clamp_scroll_to_cursor() with the up-to-date row budget.
            scroll = math.max(0, math.min(scroll, math.max(0, cursor - 1)))
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
    function controller.get_marked()
        if selected_count == 0 then return {} end
        local out = {}
        for _, item in ipairs(items) do
            if selected[item] then out[#out + 1] = item end
        end
        return out
    end
    function controller.get_cursor() return current[cursor] end
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
        if preview_ctrl then preview_ctrl.close() end
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

    -- Fallbacks if focus leaves the picker entirely, or the user closes the
    -- input window via :q. Keep in one group so we don't leak.
    cleanup_group = vim.api.nvim_create_augroup(
        "fuzzy.picker.cleanup." .. input_buf, { clear = true })

    -- Close when focus moves to a window the picker doesn't own. Schedule
    -- the check so transient `nvim_win_call` switches (preview uses these
    -- for scrolling/centering) settle before we read the current window.
    vim.api.nvim_create_autocmd("WinEnter", {
        group = cleanup_group,
        callback = function()
            if closed then return end
            vim.schedule(function()
                if closed then return end
                local cur = vim.api.nvim_get_current_win()
                if cur == view.input_win
                    or cur == view.result_win
                    or cur == view.frame_win
                    or cur == view.preview_win then
                    return
                end
                close()
            end)
        end,
    })

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

    -- On terminal resize, reflow the picker (and preview) against the new
    -- editor dimensions, then re-render so result lines reflect any width
    -- change. Layout lives in window.lua; here we just trigger it.
    vim.api.nvim_create_autocmd("VimResized", {
        group = cleanup_group,
        callback = function()
            if closed then return end
            view.reflow_geometry()
            render()
        end,
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
        local prev_scroll = scroll
        clamp_scroll_to_cursor()
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
        clamp_scroll_to_cursor()
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
        clamp_scroll_to_cursor()
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

    if opts.preview_source then
        preview_ctrl = preview_mod.attach({
            view = view,
            source = opts.preview_source,
            get_cursor = function() return current[cursor] end,
            get_query = function() return read_query() end,
            enabled = config.get().preview == true,
            input_win = view.input_win,
        })
        local cfg = config.get()
        if cfg.preview_toggle_key and cfg.preview_toggle_key ~= "" then
            imap(cfg.preview_toggle_key, function() preview_ctrl.toggle() end)
        end
        if cfg.preview_focus_key and cfg.preview_focus_key ~= "" then
            imap(cfg.preview_focus_key, function()
                if not preview_ctrl.is_open() then return end
                local pw = preview_ctrl.get_win()
                if pw and vim.api.nvim_win_is_valid(pw) then
                    pcall(vim.cmd, "stopinsert")
                    pcall(vim.api.nvim_set_current_win, pw)
                end
            end)
        end
        if cfg.preview_scroll_down_key and cfg.preview_scroll_down_key ~= "" then
            imap(cfg.preview_scroll_down_key, function() preview_ctrl.scroll_down() end)
        end
        if cfg.preview_scroll_up_key and cfg.preview_scroll_up_key ~= "" then
            imap(cfg.preview_scroll_up_key, function() preview_ctrl.scroll_up() end)
        end
        imap("<ScrollWheelDown>", function() preview_ctrl.mouse_scroll_down() end)
        imap("<ScrollWheelUp>",   function() preview_ctrl.mouse_scroll_up() end)
    end

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

---@param kind "files"|"buffers"|"grep"|"helptags"|"commands"|"keymaps"|"qflist"|"git_branches"|"git_worktrees"|"lsp_symbols"|"lsp_project_symbols"|string
---@param opts? { bang?: boolean, initial_query?: string, initial_flags?: string[], fuzzy_only?: boolean }
local function open_for(kind, opts)
    local source_name = picker_sources[kind]
    if not source_name then return end
    return require(source_name).open(opts or {}, open)
end

--- Register a source module under the given kind. The module must export
--- `M.open(opts, picker_open)`. Subsequent `M.open_for(kind, ...)` calls
--- dispatch to it.
---@param kind string
---@param modname string  Lua module name passed to `require()`
local function register_source(kind, modname)
    picker_sources[kind] = modname
end

M.open = open
M.open_for = open_for
M.register_source = register_source

return M

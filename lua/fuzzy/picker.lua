local match = require("fuzzy.match")
local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")

local M = {}

local ns = vim.api.nvim_create_namespace("fuzzy.picker")

local HL = {
    normal   = "FuzzyPickerNormal",
    border   = "FuzzyPickerBorder",
    title    = "FuzzyPickerTitle",
    sel      = "FuzzyPickerSelection",
    match    = "FuzzyPickerMatch",
    dir      = "FuzzyPickerDir",
    file     = "FuzzyPickerFile",
    selected = "FuzzyPickerSelected",
}

local WINHL = ("Normal:%s,FloatBorder:%s,FloatTitle:%s"):format(HL.normal, HL.border, HL.title)
local CONTENT_WINHL = ("Normal:%s"):format(HL.normal)

-- Filter debounce: short, just enough to coalesce keystrokes from key-repeat
-- so a held-down key doesn't queue a synchronous filter pass per repeat.
local FILTER_DEBOUNCE_MS = 30
-- Render throttle: ~30Hz coalescing of streamed appends. Direct user actions
-- (typing, moving cursor, selecting) still render immediately.
local RENDER_THROTTLE_MS = 33

local function divider_line(width)
    local fillchars = vim.opt.fillchars:get()
    local horiz = type(fillchars) == "table" and fillchars.horiz or nil
    if type(horiz) ~= "string" or horiz == "" then horiz = "-" end
    return horiz:rep(width)
end

local function set_default_hl(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
end
set_default_hl(HL.normal, "NormalFloat")
set_default_hl(HL.border, "FloatBorder")
set_default_hl(HL.title,  "FloatTitle")
set_default_hl(HL.sel,    "PmenuSel")
set_default_hl(HL.match,  "Special")
set_default_hl(HL.dir,    "Comment")
set_default_hl(HL.file,   "Normal")
set_default_hl(HL.selected, "Statement")

local SEL_PREFIX = "▌ "
local UNSEL_PREFIX = "  "
local SEL_PREFIX_LEN = #SEL_PREFIX
local UNSEL_PREFIX_LEN = #UNSEL_PREFIX

---@class FuzzyPickerOpts
---@field items any[]
---@field on_select? fun(item: any, visible_items: any[], all_items: any[])
---@field on_submit? fun(query: string)
---@field on_change? fun(query: string, picker: FuzzyPickerController)
---@field on_close? fun()
---@field on_quickfix? fun(visible_items: any[], all_items: any[])
---@field format_item? fun(item: any): string
---@field filter_items? boolean
---@field highlight_matches? boolean
---@field highlight_fn? fun(query: string, line: string): integer[]|nil
---@field prompt? string
---@field height? integer
---@field initial_query? string

---@class FuzzyPickerController
---@field set_items fun(items: any[])
---@field append_items fun(items: any[])
---@field get_items fun(): any[]
---@field get_query fun(): string
---@field is_closed fun(): boolean
---@field accept fun()
---@field close fun()

---@param opts FuzzyPickerOpts
---@return FuzzyPickerController
local function open(opts)
    local items = opts.items or {}
    local prompt = opts.prompt or "Fuzzy"
    local on_select = opts.on_select or function() end
    local on_submit = opts.on_submit
    local on_change = opts.on_change
    local on_close = opts.on_close
    local on_quickfix = opts.on_quickfix
    local format_item = opts.format_item or function(item) return item end
    local filter_items = opts.filter_items ~= false
    local highlight_matches = opts.highlight_matches ~= false
    local highlight_fn = opts.highlight_fn or match.positions

    local cmdh = vim.o.cmdheight
    local max_h = vim.o.lines - cmdh - 6
    local max_height = math.max(3, math.min(opts.height or 15, max_h))

    local frame_buf = vim.api.nvim_create_buf(false, true)
    local input_buf = vim.api.nvim_create_buf(false, true)
    local result_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[frame_buf].bufhidden = "wipe"
    vim.bo[input_buf].bufhidden = "wipe"
    vim.bo[result_buf].bufhidden = "wipe"

    local width = math.min(80, math.floor(vim.o.columns * 0.6))
    local frame_row = 0
    local frame_col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2))
    local input_row = frame_row + 1
    local result_row = frame_row + 3
    local content_col = frame_col + 1

    local blank = (" "):rep(width)
    local divider = divider_line(width)

    local function frame_lines_for(n)
        local lines = { blank }
        if n > 0 then
            lines[#lines + 1] = divider
            for _ = 1, n do lines[#lines + 1] = blank end
        end
        return lines
    end

    local function write_frame(n)
        vim.bo[frame_buf].modifiable = true
        vim.api.nvim_buf_set_lines(frame_buf, 0, -1, false, frame_lines_for(n))
        vim.api.nvim_buf_clear_namespace(frame_buf, ns, 0, -1)
        if n > 0 then
            vim.api.nvim_buf_set_extmark(frame_buf, ns, 1, 0, {
                end_col = width, hl_group = HL.border, priority = 100,
            })
        end
        vim.bo[frame_buf].modifiable = false
    end

    local displayed = math.min(#items, max_height)
    write_frame(displayed)

    local frame_win = vim.api.nvim_open_win(frame_buf, false, {
        relative = "editor",
        row = frame_row,
        col = frame_col,
        width = width,
        height = (displayed == 0) and 1 or (displayed + 2),
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 40,
        title = " " .. prompt .. " ",
        title_pos = "center",
    })

    local result_win = vim.api.nvim_open_win(result_buf, false, {
        relative = "editor",
        row = result_row,
        col = content_col,
        width = width,
        height = math.max(1, displayed),
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = 50,
        hide = displayed == 0,
    })

    local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        row = input_row,
        col = content_col,
        width = width,
        height = 1,
        style = "minimal",
        border = "none",
        zindex = 60,
    })

    vim.wo[result_win].wrap = false
    vim.wo[frame_win].winhighlight = WINHL
    vim.wo[result_win].winhighlight = CONTENT_WINHL
    vim.wo[input_win].winhighlight = CONTENT_WINHL

    local current = items
    local cursor = 1
    local scroll = 0
    local closed = false
    local controller = {}
    local selected = {}
    local selected_count = 0

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

    local function item_text(item)
        local ok, text = pcall(format_item, item)
        if not ok then
            vim.schedule(function()
                vim.notify("Fuzzy: format_item error: " .. tostring(text),
                    vim.log.levels.ERROR)
            end)
            return ""
        end
        return text and tostring(text) or ""
    end

    local function resize(target)
        target = math.min(math.max(0, target), max_height)
        if target == displayed then return end
        displayed = target
        write_frame(target)
        pcall(vim.api.nvim_win_set_config, frame_win, {
            relative = "editor",
            row = frame_row,
            col = frame_col,
            width = width,
            height = (target == 0) and 1 or (target + 2),
        })
        pcall(vim.api.nvim_win_set_config, result_win, {
            relative = "editor",
            row = result_row,
            col = content_col,
            width = width,
            height = math.max(1, target),
            hide = target == 0,
        })
    end

    local function render()
        resize(#current)
        local total = #current
        local n = math.min(displayed, math.max(0, total - scroll))
        local lines = {}
        local texts = {}
        local row_plen = {}
        for i = 1, n do
            local item = current[scroll + i]
            local text = item_text(item)
            texts[i] = text
            local is_sel = selected[item] == true
            row_plen[i] = is_sel and SEL_PREFIX_LEN or UNSEL_PREFIX_LEN
            lines[i] = (is_sel and SEL_PREFIX or UNSEL_PREFIX) .. text
        end
        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(result_buf, ns, 0, -1)

        local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""

        for i = 1, n do
            local row = i - 1
            local text = texts[i]
            local plen = row_plen[i]
            local line_len = #lines[i]
            local slash = text:find("/[^/]*$")

            if plen == SEL_PREFIX_LEN then
                vim.api.nvim_buf_set_extmark(result_buf, ns, row, 0, {
                    end_col = plen, hl_group = HL.selected, priority = 150,
                })
            end

            if slash then
                vim.api.nvim_buf_set_extmark(result_buf, ns, row, plen, {
                    end_col = plen + slash, hl_group = HL.dir, priority = 100,
                })
            end
            vim.api.nvim_buf_set_extmark(result_buf, ns, row, plen + (slash or 0), {
                end_col = line_len, hl_group = HL.file, priority = 100,
            })

            if highlight_matches and query ~= "" then
                local ok, pos = pcall(highlight_fn, query, text)
                if ok and pos then
                    for _, p in ipairs(pos) do
                        vim.api.nvim_buf_set_extmark(result_buf, ns, row, plen + p - 1, {
                            end_col = plen + p, hl_group = HL.match, priority = 200,
                        })
                    end
                end
            end
        end

        local cursor_row = cursor - scroll - 1
        if cursor_row >= 0 and cursor_row < n then
            vim.api.nvim_buf_set_extmark(result_buf, ns, cursor_row, 0, {
                end_row = cursor_row + 1, hl_group = HL.sel, hl_eol = true, priority = 50,
            })
        end
    end

    -- Cap scored results to a small multiple of visible rows.
    -- match.filter still walks every item to score, but trims after sort.
    local match_limit = math.max(max_height * 10, 200)

    local function update_current(query, reset_cursor)
        if filter_items and query ~= "" then
            local scored = match.filter(query, items, match_limit)
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
            scroll = math.max(0, math.min(scroll, math.max(0, #current - max_height)))
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
        update_current(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or "", true)
        render()
    end

    function controller.append_items(new_items)
        if not new_items or #new_items == 0 then return end
        vim.list_extend(items, new_items)
        update_current(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or "", false)
        render_soon()
    end

    function controller.get_items()
        return items
    end

    function controller.get_query()
        return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    end

    function controller.is_closed()
        return closed
    end

    local function update_filter()
        local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
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
            local q = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
            update_current(q, true)
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
        if vim.api.nvim_win_is_valid(input_win) then pcall(vim.api.nvim_win_close, input_win, true) end
        if vim.api.nvim_win_is_valid(result_win) then pcall(vim.api.nvim_win_close, result_win, true) end
        if vim.api.nvim_win_is_valid(frame_win) then pcall(vim.api.nvim_win_close, frame_win, true) end
    end

    controller.close = close

    local function accept()
        if on_submit then
            local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
            close()
            if query:match("%S") then
                safe_call(on_submit, query)
            end
            return
        end

        local picked = current[cursor]
        local visible_items = current
        local all_items = items
        close()
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
        pattern = { tostring(input_win), tostring(result_win), tostring(frame_win) },
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

    local function move(delta)
        local total = #current
        if total == 0 then return end
        cursor = math.max(1, math.min(total, cursor + delta))
        local page = math.max(1, displayed)
        if cursor < scroll + 1 then
            scroll = cursor - 1
        elseif cursor > scroll + page then
            scroll = cursor - page
        end
        render()
    end

    local function select_current()
        local item = current[cursor]
        if item == nil then return end
        if not selected[item] then
            selected[item] = true
            selected_count = selected_count + 1
        end
        move(1)
    end

    local function deselect_current()
        local item = current[cursor]
        if item == nil then return end
        if selected[item] then
            selected[item] = nil
            selected_count = selected_count - 1
        end
        move(-1)
    end

    imap("<CR>", accept)
    imap("<C-n>", function() move(1) end)
    imap("<Down>", function() move(1) end)
    imap("<C-p>", function() move(-1) end)
    imap("<Up>", function() move(-1) end)
    imap("<Tab>", select_current)
    imap("<S-Tab>", deselect_current)
    imap("<Esc>", close)
    imap("<C-c>", close)

    if on_quickfix then
        local qf_key = require("fuzzy.config").get().send_to_qf_key
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

    render()
    if opts.initial_query and opts.initial_query ~= "" then
        vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { opts.initial_query })
        update_current(opts.initial_query, true)
        if on_change then safe_call(on_change, opts.initial_query, controller) end
        render()
        vim.cmd("startinsert!")
    else
        vim.cmd.startinsert()
    end
    return controller
end

local LIVE_GREP_DEBOUNCE_MS = 150

local function grep_display(item)
    return item.display
end

-- Highlight the query as a literal substring within the text portion of a
-- grep display line ("filename:lnum:col:text"). Falls back to match.positions
-- if the display cannot be parsed.
local function grep_highlight(query, line)
    -- locate start of text after "filename:lnum:col:"
    local text_start = line:match("^[^:]+:%d+:%d+:()")
    if not text_start then return match.positions(query, line) end

    local text = line:sub(text_start)
    local lower_q = query:lower()
    local lower_t = text:lower()

    local s = lower_t:find(lower_q, 1, true)
    if not s then return nil end

    local offset = text_start - 1
    local positions = {}
    for i = 1, #query do
        positions[i] = offset + s + i - 1
    end
    return positions
end

local function open_live_grep(opts)
    opts = opts or {}

    local dedupe_lines = require("fuzzy.config").get().grep_dedupe
    local netrw_dir = opts.dir or util.get_netrw_dir()
    local label
    if opts.dir then
        label = dedupe_lines and "FuzzyGrepIn" or "FuzzyGrepIn!"
    else
        label = dedupe_lines and "FuzzyGrep" or "FuzzyGrep!"
    end
    local title = netrw_dir and (label .. " [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or label

    local timer = vim.uv.new_timer()
    local timer_closed = false
    local generation = 0
    local handle

    local cache = {}
    local cache_order = {}  -- FIFO insertion order; oldest at index 1
    local MAX_CACHE_SIZE = 30

    local function cache_put(key, entry)
        if cache[key] == nil then
            cache_order[#cache_order + 1] = key
            if #cache_order > MAX_CACHE_SIZE then
                local oldest = table.remove(cache_order, 1)
                cache[oldest] = nil
            end
        end
        cache[key] = entry
    end

    local function find_best_prefix(query)
        local best_key = nil
        local best_len = 0
        for key, entry in pairs(cache) do
            if entry.complete and #key < #query and query:sub(1, #key) == key then
                if #key > best_len then
                    best_key = key
                    best_len = #key
                end
            end
        end
        return best_key
    end

    local function filter_cached(cached_items, query)
        local is_lower = query == query:lower()
        local results = {}
        for _, item in ipairs(cached_items) do
            local text = item.qf and item.qf.text or item.display
            if is_lower then
                if text:lower():find(query, 1, true) then
                    results[#results + 1] = item
                end
            else
                if text:find(query, 1, true) then
                    results[#results + 1] = item
                end
            end
        end
        return results
    end

    local function stop_timer(close_timer)
        if timer_closed then return end
        timer:stop()
        if close_timer then
            timer:close()
            timer_closed = true
        end
    end

    local function cancel_stream()
        if handle then
            pcall(function() handle:kill() end)
            handle = nil
        end
    end

    local function stop_all()
        generation = generation + 1
        stop_timer(true)
        cancel_stream()
    end

    local function result_key(item)
        local qf = item and item.qf
        if not qf then return nil end
        if dedupe_lines then
            return ("%s:%s"):format(qf.filename or "", qf.lnum or "")
        end
        return ("%s:%s:%s:%s"):format(qf.filename or "", qf.lnum or "", qf.col or "", qf.text or "")
    end

    local function to_result(raw_line, seen)
        local e = parse.vimgrep(raw_line)
        if not e then return nil end

        local display_path = e.filename  -- relative path from rg (short, readable)
        e.filename = util.with_root(e.filename, netrw_dir)
        local result = {
            display = ("%s:%d:%d:%s"):format(display_path, e.lnum, e.col, e.text),
            qf = e,
        }
        if seen then
            local key = result_key(result)
            if key and seen[key] then return nil end
            if key then seen[key] = true end
        end

        return result
    end

    local function snapshot_quickfix(results)
        local items = {}
        for _, result in ipairs(results) do
            items[#items + 1] = result.qf
        end
        if #items > 0 then
            quickfix.update(items, { title = title, command = label })
        end
    end

    local function jump_to_result(result)
        local qf = result.qf
        if not qf or not util.open_file(qf.filename) then return end
        pcall(vim.api.nvim_win_set_cursor, 0, { qf.lnum or 1, math.max((qf.col or 1) - 1, 0) })
        pcall(vim.cmd, "normal! zv")
    end

    local function start_stream(query, picker, gen)
        local seen = {}
        for _, item in ipairs(picker.get_items()) do
            local key = result_key(item)
            if key then seen[key] = true end
        end
        local line_batch = {}
        local batch_scheduled = false

        handle = runner.rg_stream(query, {
            cwd = netrw_dir,
            on_line = function(line)
                if gen ~= generation then return end
                line_batch[#line_batch + 1] = line
                if not batch_scheduled then
                    batch_scheduled = true
                    vim.schedule(function()
                        local batch = line_batch
                        line_batch = {}
                        batch_scheduled = false

                        if gen ~= generation or picker.is_closed() then return end

                        local results = {}
                        for _, raw_line in ipairs(batch) do
                            local result = to_result(raw_line, seen)
                            if result then results[#results + 1] = result end
                        end
                        picker.append_items(results)
                    end)
                end
            end,
            on_exit = function()
                if gen == generation then
                    handle = nil
                    cache_put(query, { items = picker.get_items(), complete = true })
                end
            end,
        })
    end

    local function schedule_search(query, picker)
        generation = generation + 1
        local gen = generation

        stop_timer(false)
        cancel_stream()

        if not query:match("%S") then
            picker.set_items({})
            return
        end

        -- Exact cache hit: serve instantly, skip grep
        if cache[query] and cache[query].complete then
            picker.set_items(cache[query].items)
            return
        end

        -- Prefix cache hit: show filtered subset instantly, still run grep for completeness
        local prefix_key = find_best_prefix(query)
        if prefix_key then
            picker.set_items(filter_cached(cache[prefix_key].items, query))
        end

        timer:start(LIVE_GREP_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            if gen ~= generation or picker.is_closed() then return end
            if not prefix_key then picker.set_items({}) end
            start_stream(query, picker, gen)
        end))
    end

    return open({
        items = {},
        prompt = "Grep",
        initial_query = opts.initial_query,
        filter_items = false,
        highlight_matches = true,
        highlight_fn = grep_highlight,
        format_item = grep_display,
        on_change = schedule_search,
        on_close = stop_all,
        on_select = function(item, _, all_items)
            snapshot_quickfix(all_items)
            jump_to_result(item)
        end,
        on_quickfix = function(visible_items)
            if #visible_items == 0 then
                vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                return
            end
            local qf_items = vim.iter(visible_items)
                :map(function(item) return item.qf end)
                :filter(function(qf) return qf ~= nil end)
                :totable()
            quickfix.update(qf_items, { title = title, command = label })
            quickfix.open_if_results(#qf_items)
        end,
    })
end

---@param kind "files"|"buffers"|"grep"|"grep_in"|"helptags"
---@param opts? { bang?: boolean, initial_query?: string }
local function open_for(kind, opts)
    opts = opts or {}
    if kind == "files" then
        local complete = require("fuzzy.complete")
        local items = complete.get_files() or {}
        if #items == 0 then
            vim.notify("Fuzzy: file cache is empty (try again in a moment).", vim.log.levels.INFO)
            return
        end
        return open({
            items = items,
            prompt = "Files",
            initial_query = opts.initial_query,
            on_select = function(path) util.open_file(path) end,
            on_quickfix = function(visible_items)
                if #visible_items == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = vim.iter(visible_items):map(function(path)
                    return { filename = vim.fn.fnamemodify(path, ":p"), lnum = 1, col = 1, text = path }
                end):totable()
                quickfix.update(qf_items, { title = "FuzzyFiles", command = "FuzzyFiles" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    elseif kind == "buffers" then
        local bufs = util.get_listed_buffers()
        local items = {}
        local by_path = {}
        local by_path_abs = {}
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
            on_quickfix = function(visible_items)
                if #visible_items == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = vim.iter(visible_items):map(function(rel)
                    local bufnr = by_path[rel]
                    return { bufnr = bufnr, filename = by_path_abs[rel] or rel, lnum = 1, col = 1, text = rel }
                end):totable()
                quickfix.update(qf_items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    elseif kind == "grep" then
        return open_live_grep(opts)
    elseif kind == "grep_in" then
        return open_live_grep({ dir = opts.dir, initial_query = opts.initial_query })
    elseif kind == "helptags" then
        local helptags = require("fuzzy.commands.helptags")
        local tag_entries = helptags.collect()
        if #tag_entries == 0 then
            vim.notify("FuzzyHelp: no help tags found.", vim.log.levels.INFO)
            return
        end

        -- Items are "tagname  filename.txt" strings — unique because tags are deduped.
        -- Filtering operates on the full string so users can match by tag or by file.
        local display_items = {}
        local display_to_entry = {}
        for _, entry in ipairs(tag_entries) do
            local display = entry.tag .. "  " .. entry.filename_short
            display_items[#display_items + 1] = display
            display_to_entry[display] = entry
        end

        return open({
            items = display_items,
            prompt = "Help",
            initial_query = opts.initial_query,
            on_select = function(display)
                local entry = display_to_entry[display]
                if not entry then return end
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
                local entries = vim.iter(visible_items)
                    :map(function(display) return display_to_entry[display] end)
                    :filter(function(e) return e ~= nil end)
                    :totable()
                local qf_items = helptags.to_qf_items(entries)
                quickfix.update(qf_items, { title = "FuzzyHelp", command = "FuzzyHelp" })
                quickfix.open_if_results(#qf_items)
            end,
        })
    end
end

M.open = open
M.open_for = open_for

return M

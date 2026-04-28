local match = require("fuzzy.match")
local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")

local M = {}

local ns = vim.api.nvim_create_namespace("fuzzy.picker")

local HL = {
    normal = "FuzzyPickerNormal",
    border = "FuzzyPickerBorder",
    title  = "FuzzyPickerTitle",
    sel    = "FuzzyPickerSelection",
    match  = "FuzzyPickerMatch",
    dir    = "FuzzyPickerDir",
    file   = "FuzzyPickerFile",
}

local WINHL = ("Normal:%s,FloatBorder:%s,FloatTitle:%s"):format(HL.normal, HL.border, HL.title)
local CONTENT_WINHL = ("Normal:%s"):format(HL.normal)

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
    local height = math.max(3, math.min(opts.height or 15, max_h))

    local frame_buf = vim.api.nvim_create_buf(false, true)
    local input_buf = vim.api.nvim_create_buf(false, true)
    local result_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[frame_buf].bufhidden = "wipe"
    vim.bo[input_buf].bufhidden = "wipe"
    vim.bo[result_buf].bufhidden = "wipe"

    local width = math.min(80, math.floor(vim.o.columns * 0.6))
    local frame_height = height + 2
    local total_h = frame_height + 2
    local frame_row = 0
    local frame_col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2))
    local input_row = frame_row + 1
    local result_row = frame_row + 3
    local content_col = frame_col + 1

    local blank = (" "):rep(width)
    local frame_lines = { blank, divider_line(width) }
    for i = 1, height do
        frame_lines[#frame_lines + 1] = blank
    end
    vim.api.nvim_buf_set_lines(frame_buf, 0, -1, false, frame_lines)
    vim.api.nvim_buf_set_extmark(frame_buf, ns, 1, 0, {
        end_col = width, hl_group = HL.border, priority = 100,
    })
    vim.bo[frame_buf].modifiable = false

    local frame_win = vim.api.nvim_open_win(frame_buf, false, {
        relative = "editor",
        row = frame_row,
        col = frame_col,
        width = width,
        height = frame_height,
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
        height = height,
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = 50,
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

    local function item_text(item)
        local text = format_item(item)
        return text and tostring(text) or ""
    end

    local function render()
        local total = #current
        local n = math.min(height, math.max(0, total - scroll))
        local lines = {}
        for i = 1, n do lines[i] = item_text(current[scroll + i]) end
        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(result_buf, ns, 0, -1)

        local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""

        for i = 1, n do
            local row = i - 1
            local line = lines[i]
            local slash = line:find("/[^/]*$")

            if slash then
                vim.api.nvim_buf_set_extmark(result_buf, ns, row, 0, {
                    end_col = slash, hl_group = HL.dir, priority = 100,
                })
            end
            vim.api.nvim_buf_set_extmark(result_buf, ns, row, slash or 0, {
                end_col = #line, hl_group = HL.file, priority = 100,
            })

            if highlight_matches and query ~= "" then
                local pos = highlight_fn(query, line)
                if pos then
                    for _, p in ipairs(pos) do
                        vim.api.nvim_buf_set_extmark(result_buf, ns, row, p - 1, {
                            end_col = p, hl_group = HL.match, priority = 200,
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

    local function update_current(query, reset_cursor)
        if filter_items and query ~= "" then
            current = vim.iter(match.filter(query, items))
                :map(function(e) return e.item end)
                :totable()
        else
            current = items
        end

        if reset_cursor then
            cursor = 1
            scroll = 0
        else
            cursor = math.max(1, math.min(cursor, math.max(1, #current)))
            scroll = math.max(0, math.min(scroll, math.max(0, #current - height)))
        end
    end

    function controller.set_items(new_items)
        items = new_items or {}
        update_current(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or "", true)
        render()
    end

    function controller.append_items(new_items)
        if not new_items or #new_items == 0 then return end
        vim.list_extend(items, new_items)
        update_current(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or "", false)
        render()
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
            on_change(query, controller)
            if not filter_items then return end
        end
        update_current(query, true)
        render()
    end

    local function close()
        if closed then return end
        closed = true
        if on_close then on_close() end
        vim.cmd.stopinsert()
        if vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
        if vim.api.nvim_win_is_valid(result_win) then vim.api.nvim_win_close(result_win, true) end
        if vim.api.nvim_win_is_valid(frame_win) then vim.api.nvim_win_close(frame_win, true) end
    end

    controller.close = close

    local function accept()
        if on_submit then
            local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
            close()
            if query:match("%S") then
                on_submit(query)
            end
            return
        end

        local picked = current[cursor]
        local visible_items = current
        local all_items = items
        close()
        if picked then on_select(picked, visible_items, all_items) end
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

    local function imap(lhs, rhs)
        vim.keymap.set("i", lhs, rhs, { buffer = input_buf, nowait = true, silent = true })
    end

    local function move(delta)
        local total = #current
        if total == 0 then return end
        cursor = math.max(1, math.min(total, cursor + delta))
        if cursor < scroll + 1 then
            scroll = cursor - 1
        elseif cursor > scroll + height then
            scroll = cursor - height
        end
        render()
    end

    imap("<CR>", accept)
    imap("<C-n>", function() move(1) end)
    imap("<Down>", function() move(1) end)
    imap("<C-p>", function() move(-1) end)
    imap("<Up>", function() move(-1) end)
    imap("<Esc>", close)
    imap("<C-c>", close)

    if on_quickfix then
        local qf_key = require("fuzzy.config").get().send_to_qf_key
        if qf_key and qf_key ~= "" then
            imap(qf_key, function()
                local vis = current
                local all = items
                close()
                on_quickfix(vis, all)
            end)
        end
    end

    render()
    if opts.initial_query and opts.initial_query ~= "" then
        vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { opts.initial_query })
        update_current(opts.initial_query, true)
        if on_change then on_change(opts.initial_query, controller) end
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
    local cache_count = 0
    local MAX_CACHE_SIZE = 30

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

    local function to_result(raw_line, seen)
        local e = parse.vimgrep(raw_line)
        if not e then return nil end

        local display_path = e.filename  -- relative path from rg (short, readable)
        e.filename = util.with_root(e.filename, netrw_dir)
        if seen then
            local key = e.filename .. ":" .. e.lnum
            if seen[key] then return nil end
            seen[key] = true
        end

        return {
            display = ("%s:%d:%d:%s"):format(display_path, e.lnum, e.col, e.text),
            qf = e,
        }
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
        local seen = dedupe_lines and {} or nil
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
                    if cache_count < MAX_CACHE_SIZE then
                        cache[query] = { items = picker.get_items(), complete = true }
                        cache_count = cache_count + 1
                    end
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

---@param kind "files"|"buffers"|"grep"
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
    end
end

M.open = open
M.open_for = open_for

return M

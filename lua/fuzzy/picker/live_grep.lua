-- Live grep flow: streams ripgrep output into a picker, with a per-session
-- query+flags result cache. Caller passes in `picker_open` so this module
-- doesn't have to require picker/init.lua (avoiding a circular load).

local config = require("fuzzy.config")
local match = require("fuzzy.match")
local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")

local M = {}

local LIVE_GREP_DEBOUNCE_MS = 150
local MAX_CACHE_SIZE = 30

local function grep_display(item) return item.display end

-- Highlight the query as a literal substring within the text portion of a
-- grep display line ("filename:lnum:col:text"). Falls back to match.positions
-- if the display cannot be parsed.
local function grep_highlight(query, line)
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

local function pick_marked_target(marked_items, picked_item, path_fn)
    if picked_item then
        local picked_path = path_fn(picked_item)
        if picked_path then
            for _, item in ipairs(marked_items) do
                if item == picked_item or path_fn(item) == picked_path then
                    return item
                end
            end
        end
    end
    return marked_items[1]
end

---@param opts { dir?: string, initial_query?: string, initial_flags?: string[] }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    opts = opts or {}

    local dedupe_lines = config.get().grep_dedupe
    local netrw_dir = opts.dir or util.get_netrw_dir()
    local grep_flags = parse.normalize(opts.initial_flags or {})
    local label
    if opts.dir then
        label = dedupe_lines and "FuzzyGrepIn" or "FuzzyGrepIn!"
    else
        label = dedupe_lines and "FuzzyGrep" or "FuzzyGrep!"
    end

    local function format_flags() return parse.join(grep_flags) end

    local function picker_title()
        local base = "Grep"
        if opts.dir then
            base = ("Grep in %s"):format(vim.fn.fnamemodify(opts.dir, ":~"))
        end
        local flags = format_flags()
        if flags == "" then return base end
        return ("%s [%s]"):format(base, flags)
    end

    local function quickfix_title()
        local base = netrw_dir and (label .. " [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or label
        local flags = format_flags()
        if flags == "" then return base end
        return ("%s (%s)"):format(base, flags)
    end

    local timer = vim.uv.new_timer()
    local timer_closed = false
    local generation = 0
    local handle

    local cache = {}
    local cache_order = {}  -- FIFO insertion order; oldest at index 1

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

    local function flags_cache_key(flags) return table.concat(flags or {}, "\31") end
    local function cache_key(query, flags) return flags_cache_key(flags) .. "\30" .. query end

    local function find_best_prefix(query, flags)
        local flag_key = flags_cache_key(flags)
        local best_key, best_len = nil, 0
        for key, entry in pairs(cache) do
            if entry.complete
                and entry.flags_key == flag_key
                and #entry.query < #query
                and query:sub(1, #entry.query) == entry.query
                and #entry.query > best_len
            then
                best_key, best_len = key, #entry.query
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

        local display_path = e.filename
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
            quickfix.update(items, { title = quickfix_title(), command = label })
        end
    end

    local function jump_to_result(result)
        local qf = result.qf
        if not qf or not util.open_file(qf.filename) then return end
        pcall(vim.api.nvim_win_set_cursor, 0, { qf.lnum or 1, math.max((qf.col or 1) - 1, 0) })
        pcall(vim.cmd, "normal! zv")
    end

    local function start_stream(query, flags, picker, gen)
        local seen = {}
        for _, item in ipairs(picker.get_items()) do
            local key = result_key(item)
            if key then seen[key] = true end
        end
        local line_batch = {}
        local batch_scheduled = false

        local active_cache_key = cache_key(query, flags)
        local active_flags_key = flags_cache_key(flags)

        -- Shallow copy is sufficient: flags are strings, never mutated through this list.
        local args = {}
        for i = 1, #flags do args[i] = flags[i] end
        args[#args + 1] = query

        if picker.set_loading then picker.set_loading(true) end

        handle = runner.rg_stream(args, {
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
                    cache_put(active_cache_key, {
                        items = picker.get_items(),
                        complete = true,
                        query = query,
                        flags_key = active_flags_key,
                    })
                end
                if picker.set_loading and not picker.is_closed() then
                    vim.schedule(function() picker.set_loading(false) end)
                end
            end,
        })
    end

    local function schedule_search(query, picker)
        generation = generation + 1
        local gen = generation
        -- Shallow copy of flags, sufficient for our use (immutable strings).
        local flags_snapshot = {}
        for i = 1, #grep_flags do flags_snapshot[i] = grep_flags[i] end
        local active_cache_key = cache_key(query, flags_snapshot)

        stop_timer(false)
        cancel_stream()

        if not query:match("%S") then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_items({})
            return
        end

        if cache[active_cache_key] and cache[active_cache_key].complete then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_items(cache[active_cache_key].items)
            return
        end

        local prefix_key = find_best_prefix(query, flags_snapshot)
        if prefix_key then
            picker.set_items(filter_cached(cache[prefix_key].items, query))
        end

        timer:start(LIVE_GREP_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            if gen ~= generation or picker.is_closed() then return end
            if not prefix_key then picker.set_items({}) end
            start_stream(query, flags_snapshot, picker, gen)
        end))
    end

    return picker_open({
        items = {},
        prompt = "Grep",
        title = picker_title(),
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
        on_marked = function(marked_items, picked_item)
            local paths = vim.iter(marked_items)
                :map(function(item) return item.qf and item.qf.filename or nil end)
                :filter(function(path) return path ~= nil end)
                :totable()
            util.load_files(paths)
            local target = pick_marked_target(marked_items, picked_item, function(item)
                return item.qf and item.qf.filename or nil
            end)
            if target then jump_to_result(target) end
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
            quickfix.update(qf_items, { title = quickfix_title(), command = label })
            quickfix.open_if_results(#qf_items)
        end,
        on_setup = function(picker, imap)
            local edit_key = config.get().edit_grep_flags_key
            if not edit_key or edit_key == "" then return end
            imap(edit_key, function()
                vim.ui.input({
                    prompt = "rg flags: ",
                    default = format_flags(),
                }, function(input)
                    vim.schedule(function()
                        if picker.is_closed() then return end
                        if input ~= nil then
                            grep_flags = parse.normalize(input)
                            picker.set_title(picker_title())
                            schedule_search(picker.get_query(), picker)
                        end
                        vim.cmd("startinsert!")
                    end)
                end)
            end)
        end,
    })
end

M.pick_marked_target = pick_marked_target

return M

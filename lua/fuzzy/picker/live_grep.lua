-- Live grep flow: streams ripgrep output into a picker, with a per-session
-- query+flags result cache. Caller passes in `picker_open` so this module
-- doesn't have to require picker/init.lua (avoiding a circular load).

local config = require("fuzzy.config")
local match = require("fuzzy.match")
local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")
local ts_highlight = require("fuzzy.picker.ts_highlight")
local HL = require("fuzzy.picker.highlight").HL

local M = {}

local LIVE_GREP_DEBOUNCE_MS = 150
local MAX_CACHE_SIZE = 30
local CACHE_TTL_SEC = 300

-- Shorten a single directory component to its first character. Hidden
-- directories (".config") keep the leading dot plus the first real char
-- (".c"), so the indicator that this is a hidden dir survives.
local function shorten_component(component)
    if component == "" then return "" end
    if component:sub(1, 1) == "." and vim.fn.strchars(component) > 1 then
        return vim.fn.strcharpart(component, 0, 2)
    end
    return vim.fn.strcharpart(component, 0, 1)
end

-- Collapse "afolder/bfolder/cfolder/file.txt" → "a/b/c/file.txt": every
-- directory component is shortened to its first character; the filename is
-- left untouched. Absolute paths keep their leading "/".
local function shorten_path(path)
    local parts = vim.split(path, "/", { plain = true })
    if #parts <= 1 then return path end
    local out = {}
    for i = 1, #parts - 1 do
        out[i] = shorten_component(parts[i])
    end
    out[#parts] = parts[#parts]
    return table.concat(out, "/")
end

-- Flat-mode (no grouping) display formatter. When the full
-- "path:lnum:col:text" line overflows the picker column budget and
-- `grep_path_truncate` is enabled, shorten directory components so the
-- lnum:col coords and the matched text stay visible. Filename is preserved.
local function grep_display_flat(item, _ctx, width)
    local d = item.display
    if not config.get().grep_path_truncate then return d end
    if not width or width <= 0 then return d end
    local max_cols = width - 2  -- PREFIX_PAD ("  ") in the result buffer
    if vim.fn.strdisplaywidth(d) <= max_cols then return d end
    local _, path_end = d:find("^[^:]+")
    if not path_end then return d end
    local path = d:sub(1, path_end)
    local rest = d:sub(path_end + 1)  -- ":lnum:col:text"
    return shorten_path(path) .. rest
end

-- Grouped-mode display formatter: ":lnum:col  text". Path is rendered in the
-- header line above by `grep_format_header`, so the data line omits it.
local function grep_display_grouped(item, _ctx, _width)
    local qf = item.qf
    return (":%d:%d  %s"):format(qf.lnum or 0, qf.col or 0, qf.text or "")
end

-- Build the header line for a group: "name  dir  count" (or "name  count" if
-- the file is in cwd root). Stores byte offsets on the item so
-- `grep_header_highlight` can color the components without re-parsing.
local function grep_format_header(item, ctx, _width)
    local path = item.display_path or item.qf.filename or ""
    local name = vim.fn.fnamemodify(path, ":t")
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir == "." or dir == "" or dir == name then dir = "" end
    local count = (ctx and ctx.fuzzy_grep_counts and ctx.fuzzy_grep_counts[item.qf.filename]) or 0

    local header_text, parts
    if dir == "" then
        header_text = ("%s  %d"):format(name, count)
        parts = {
            name_end    = #name,
            dir_start   = nil,
            dir_end     = nil,
            count_start = #name + 2,
        }
    else
        header_text = ("%s  %s  %d"):format(name, dir, count)
        parts = {
            name_end    = #name,
            dir_start   = #name + 2,
            dir_end     = #name + 2 + #dir,
            count_start = #name + 2 + #dir + 2,
        }
    end
    parts.total = #header_text
    item._header_parts = parts
    return header_text
end

-- Apply per-component highlights to a header line using offsets stashed on the
-- item by `grep_format_header`.
local function grep_header_highlight(buf, ns, row, item, _header_text, _ctx, prefix_len)
    local p = item._header_parts
    if not p then return end
    vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len, {
        end_col = prefix_len + p.name_end, hl_group = HL.file, priority = 110,
    })
    if p.dir_start then
        vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len + p.dir_start, {
            end_col = prefix_len + p.dir_end, hl_group = HL.dir, priority = 110,
        })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len + p.count_start, {
        end_col = prefix_len + p.total, hl_group = HL.grepHeaderCount, priority = 110,
    })
end

-- Apply line-number prefix + treesitter syntax to a grouped data row. The data
-- line is laid out as ":LNUM:COL  CONTENT" — we color the prefix with LineNr
-- and walk treesitter captures over CONTENT.
local function grep_data_row_highlight(buf, ns, row, item, text, _ctx, prefix_len)
    local content_start = text:match("^:%d+:%d+  ()")
    if content_start then
        -- 1-indexed byte after the trailing whitespace; convert to extmark
        -- byte offset (0-indexed): prefix_len + (content_start - 1).
        vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len, {
            end_col = prefix_len + content_start - 1, hl_group = HL.grepLineNr, priority = 100,
        })
    end
    if not config.get().grep_syntax_highlight then return end
    if not content_start then return end
    local content = item.qf and item.qf.text or nil
    if not content or content == "" then return end
    local hls = ts_highlight.get_line_highlights(item.qf.filename, content)
    if not hls then return end
    local base = prefix_len + content_start - 1  -- 0-indexed byte offset of content start
    for _, cap in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, base + cap.col, {
            end_col = base + cap.end_col, hl_group = cap.hl_group, priority = 120,
        })
    end
end

-- Highlight the query as a literal substring within the text portion of a
-- grep display line. Handles both flat ("file:lnum:col:text") and grouped
-- (":lnum:col  text") layouts. Falls back to match.positions otherwise.
local function grep_highlight(query, line)
    -- Grouped layout: leading colon. Try it first because it's the only one
    -- that starts with `:`. Match the literal 2-space separator (not %s+) so
    -- leading whitespace on the actual content is not consumed.
    local text_start = line:match("^:%d+:%d+  ()")
    if not text_start then
        text_start = line:match("^[^:]+:%d+:%d+:()")
    end
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

---@param opts { initial_query?: string, initial_flags?: string[] }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    opts = opts or {}

    local dedupe_lines = config.get().grep_dedupe
    local netrw_dir = util.get_netrw_dir()
    local grep_flags = parse.normalize(opts.initial_flags or {})
    local label = dedupe_lines and "FuzzyGrep" or "FuzzyGrep!"

    local function format_flags() return parse.join(grep_flags) end

    local function picker_title()
        local base = "Grep"
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
        entry.ts = os.time()
        if cache[key] == nil then
            cache_order[#cache_order + 1] = key
            if #cache_order > MAX_CACHE_SIZE then
                local oldest = table.remove(cache_order, 1)
                cache[oldest] = nil
            end
        end
        cache[key] = entry
    end

    local function is_fresh(entry)
        return os.time() - (entry.ts or 0) <= CACHE_TTL_SEC
    end

    local function flags_cache_key(flags) return table.concat(flags or {}, "\31") end
    local function cache_key(query, flags) return flags_cache_key(flags) .. "\30" .. query end

    local function find_best_prefix(query, flags)
        local flag_key = flags_cache_key(flags)
        local best_key, best_len = nil, 0
        for key, entry in pairs(cache) do
            if entry.complete
                and is_fresh(entry)
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
            display_path = display_path,
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
            skip_global_cancel = true,
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

        local hit = cache[active_cache_key]
        if hit and hit.complete and is_fresh(hit) then
            if picker.set_loading then picker.set_loading(false) end
            picker.set_items(hit.items)
            return
        end

        -- Prefill from any prefix cache entry: filter_cached uses literal
        -- substring matching, which is exact for literal queries and a sound
        -- under-include for regex queries containing `.`/`(`/etc. The
        -- background `rg` always runs to produce the authoritative result,
        -- so any briefly-missing matches snap in within the debounce.
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

    local grouped = config.get().grep_group_by_file ~= false
    local picker_opts = {
        items = {},
        prompt = "Grep",
        title = picker_title(),
        initial_query = opts.initial_query,
        filter_items = false,
        highlight_paths = false,
        highlight_matches = true,
        highlight_fn = grep_highlight,
        format_item = grouped and grep_display_grouped or grep_display_flat,
        preview_source = {
            kind = "grep",
            resolve = function(item)
                local qf = item and item.qf
                if not qf or not qf.filename then return nil end
                return { path = qf.filename, lnum = qf.lnum, col = qf.col }
            end,
        },
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
    }

    if grouped then
        picker_opts.group_key = function(item) return item.qf and item.qf.filename or nil end
        picker_opts.format_header = grep_format_header
        picker_opts.header_highlight = grep_header_highlight
        picker_opts.row_highlight = grep_data_row_highlight
        picker_opts.make_render_context = function(items)
            local counts = {}
            for _, item in ipairs(items) do
                local fn = item.qf and item.qf.filename
                if fn then counts[fn] = (counts[fn] or 0) + 1 end
            end
            return { fuzzy_grep_counts = counts }
        end
    end

    return picker_open(picker_opts)
end

M.pick_marked_target = pick_marked_target

return M

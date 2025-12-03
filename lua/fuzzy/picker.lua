-- Generic interactive floating picker with live filtering

local match = require("fuzzy.match")

local M = {}

-- Reusable namespace (created once per session)
local ns = vim.api.nvim_create_namespace("fuzzy_picker")

-- Cache separator by width to avoid rebuilding
local separator_cache = {}
local function get_separator(width)
    if not separator_cache[width] then
        separator_cache[width] = string.rep("─", width)
    end
    return separator_cache[width]
end

local function create_picker_win(opts)
    opts = opts or {}
    local width = opts.width or math.floor(vim.o.columns * 0.7)
    local height = opts.height or math.floor(vim.o.lines * 0.5)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = opts.title or " Fuzzy ",
        title_pos = "center",
    })

    -- Window-local options
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false

    return { buf = buf, win = win, width = width }
end

local function close_picker(state)
    if state.closed then
        return
    end
    state.closed = true

    -- Stop debounce timer if running
    if state.debounce_timer then
        state.debounce_timer:stop()
        state.debounce_timer:close()
        state.debounce_timer = nil
    end

    -- Cancel in-flight search
    if state.current_handle then
        pcall(function() state.current_handle:kill() end)
        state.current_handle = nil
    end

    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, state.win, true)
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
end

local function render_results(state)
    if state.closed then
        return
    end

    local items = state.display_items
    local item_count = #items
    state.selected = math.min(state.selected, math.max(1, item_count))

    -- Pre-allocate lines table
    local lines = { get_separator(state.width) }
    local line_idx = 2

    for i, entry in ipairs(items) do
        local prefix = i == state.selected and "> " or "  "
        local text = type(entry) == "table"
            and (entry.display or entry.text or entry.item or tostring(entry))
            or entry
        lines[line_idx] = prefix .. text
        line_idx = line_idx + 1
    end

    if item_count == 0 then
        lines[line_idx] = "  No matches"
    end

    -- Batch buffer updates
    vim.api.nvim_buf_set_lines(state.buf, 1, -1, false, lines)

    -- Clear and set highlights in batch
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

    -- Highlight prompt prefix
    vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, {
        end_col = 2,
        hl_group = "Comment",
    })

    -- Highlight separator
    vim.api.nvim_buf_set_extmark(state.buf, ns, 1, 0, {
        end_col = #lines[1],
        hl_group = "FloatBorder",
    })

    -- Highlight selected result line and scroll into view
    if item_count > 0 then
        local sel_row = state.selected + 1  -- +1 for separator line
        vim.api.nvim_buf_set_extmark(state.buf, ns, sel_row, 0, {
            end_col = #lines[sel_row],
            hl_group = "CursorLine",
            hl_eol = true,
        })

        -- Scroll to keep selected item visible (sel_row is 0-indexed, topline is 1-indexed)
        local win_height = vim.api.nvim_win_get_height(state.win)
        local topline = vim.fn.line("w0", state.win)
        local botline = topline + win_height - 1
        local target_line = sel_row + 1  -- Convert to 1-indexed for comparison

        if target_line > botline then
            -- Scroll down: set topline so target is at bottom
            vim.api.nvim_win_call(state.win, function()
                vim.fn.winrestview({ topline = target_line - win_height + 1 })
            end)
        elseif target_line < topline and target_line > 1 then
            -- Scroll up: set topline to target (but keep prompt visible)
            vim.api.nvim_win_call(state.win, function()
                vim.fn.winrestview({ topline = math.max(1, target_line - 1) })
            end)
        end
    end
end

local function apply_filter(state, items, query)
    if query and query ~= "" then
        local scored = match.filter(query, items, state.max_results)
        state.display_items = vim.iter(scored):map(function(e) return e.item end):totable()
    else
        state.display_items = vim.list_slice(items, 1, state.max_results)
    end
    render_results(state)
end

local function move_selection(state, delta)
    local count = #state.display_items
    if count == 0 then
        return
    end
    state.selected = state.selected + delta
    if state.selected < 1 then
        state.selected = count
    elseif state.selected > count then
        state.selected = 1
    end
    render_results(state)
end

--- Check if new_query is a refinement of base_query (starts with it)
local function is_refinement(new_query, base_query)
    if not base_query or base_query == "" then
        return false
    end
    return vim.startswith(new_query, base_query)
end

--- Open an interactive picker
--- @param opts table Options:
---   - source: table|function - Items to pick from, or function(query, callback) for dynamic sources
---   - streaming_source: function(query, on_lines, on_done) - Streaming source with query refinement
---   - on_select: function(item) - Called when user selects an item
---   - title: string - Window title
---   - max_results: number - Max items to show (default 50)
---   - debounce_ms: number - Debounce time for external searches (default 100)
function M.open(opts)
    opts = opts or {}
    local source = opts.source or {}
    local streaming_source = opts.streaming_source
    local on_select = opts.on_select or function() end
    local max_results = opts.max_results or 50
    local debounce_ms = opts.debounce_ms or 100

    local win_info = create_picker_win({ title = opts.title })

    local state = {
        buf = win_info.buf,
        win = win_info.win,
        width = win_info.width,
        query = "",
        selected = 1,
        display_items = {},
        max_results = max_results,
        closed = false,
        debounce_timer = nil,
        current_handle = nil,
        -- Query refinement cache
        cache_query = nil,    -- The query used to fetch from external source
        cached_items = {},    -- Results from that query
    }

    local function cancel_search()
        if state.current_handle then
            pcall(function() state.current_handle:kill() end)
            state.current_handle = nil
        end
    end

    --- Run external search and cache results
    local function run_external_search(query)
        cancel_search()
        state.cache_query = query
        state.cached_items = {}

        if streaming_source then
            state.current_handle = streaming_source(query, function(lines)
                if state.closed then return end
                for _, line in ipairs(lines) do
                    state.cached_items[#state.cached_items + 1] = line
                end
                -- Filter with current query (may be more refined than cache_query)
                apply_filter(state, state.cached_items, state.query)
            end, function(_code, _stderr)
                state.current_handle = nil
            end)
        elseif type(source) == "function" then
            source(query, function(items)
                if state.closed then return end
                vim.schedule(function()
                    state.cached_items = items or {}
                    apply_filter(state, state.cached_items, state.query)
                end)
            end)
        end
    end

    local function on_query_change(new_query, old_query)
        state.selected = 1

        -- Static source (no dynamic/streaming): always filter locally
        if not streaming_source and type(source) == "table" then
            apply_filter(state, source, new_query)
            return
        end

        -- Dynamic/streaming source: use query refinement
        if new_query == "" then
            -- Empty query: clear cache and results
            cancel_search()
            state.cache_query = nil
            state.cached_items = {}
            state.display_items = {}
            render_results(state)
            return
        end

        -- Check if we can refine locally (new query extends cached query)
        if is_refinement(new_query, state.cache_query) then
            -- Filter cached results locally (instant)
            apply_filter(state, state.cached_items, new_query)
            return
        end

        -- Need new external search - debounce it
        cancel_search()
        if state.debounce_timer then
            state.debounce_timer:stop()
        else
            state.debounce_timer = vim.uv.new_timer()
        end
        state.debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(function()
            run_external_search(state.query)
        end))
    end

    -- Initialize prompt line
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "> " })

    -- Initial render
    render_results(state)

    -- Keymaps
    local function map(modes, lhs, rhs)
        vim.keymap.set(modes, lhs, rhs, { buffer = state.buf, nowait = true })
    end

    map({ "i", "n" }, "<Esc>", function() close_picker(state) end)
    map("n", "q", function() close_picker(state) end)

    map({ "i", "n" }, "<CR>", function()
        if #state.display_items > 0 then
            local selected = state.display_items[state.selected]
            close_picker(state)
            on_select(selected, state.query)
        end
    end)

    local function nav_down() move_selection(state, 1) end
    local function nav_up() move_selection(state, -1) end

    map("i", "<C-n>", nav_down)
    map("i", "<C-p>", nav_up)
    map("i", "<Down>", nav_down)
    map("i", "<Up>", nav_up)
    map("i", "<C-j>", nav_down)
    map("i", "<C-k>", nav_up)
    map("i", "<Tab>", nav_down)
    map("i", "<S-Tab>", nav_up)

    -- Handle text changes
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = state.buf,
        callback = function()
            local line = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
            if not vim.startswith(line, "> ") then
                line = "> " .. line:gsub("^>?%s*", "")
                vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { line })
                vim.api.nvim_win_set_cursor(state.win, { 1, #line })
            end
            local new_query = line:sub(3)
            if new_query ~= state.query then
                local old_query = state.query
                state.query = new_query
                on_query_change(new_query, old_query)
            end
        end,
    })

    -- Start in insert mode
    vim.cmd.startinsert({ bang = true })
    vim.api.nvim_win_set_cursor(state.win, { 1, 2 })

    return state
end

return M

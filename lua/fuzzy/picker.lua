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

    -- Highlight selected result line
    if item_count > 0 then
        local sel_row = state.selected + 1
        vim.api.nvim_buf_set_extmark(state.buf, ns, sel_row, 0, {
            end_col = #lines[sel_row],
            hl_group = "CursorLine",
            hl_eol = true,
        })
    end
end

local function apply_filter(state)
    if state.filter_locally and state.query ~= "" then
        local scored = match.filter(state.query, state.source_items, state.max_results)
        state.display_items = vim.iter(scored):map(function(e) return e.item end):totable()
    else
        state.display_items = vim.list_slice(state.source_items, 1, state.max_results)
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

--- Open an interactive picker
--- @param opts table Options:
---   - source: table|function - Items to pick from, or function(query, callback) for dynamic sources
---   - on_select: function(item) - Called when user selects an item
---   - title: string - Window title
---   - max_results: number - Max items to show (default 50)
---   - filter_locally: boolean - Filter items locally with fuzzy match (default true)
---   - debounce_ms: number - Debounce time for dynamic sources (default 150)
function M.open(opts)
    opts = opts or {}
    local source = opts.source or {}
    local on_select = opts.on_select or function() end
    local max_results = opts.max_results or 50
    local filter_locally = opts.filter_locally ~= false
    local debounce_ms = opts.debounce_ms or 150

    local win_info = create_picker_win({ title = opts.title })

    local state = {
        buf = win_info.buf,
        win = win_info.win,
        width = win_info.width,
        query = "",
        selected = 1,
        source_items = {},
        display_items = {},
        max_results = max_results,
        filter_locally = filter_locally,
        closed = false,
        debounce_timer = nil,
    }

    local function update_source(query)
        if type(source) == "function" then
            source(query, function(items)
                if state.closed then
                    return
                end
                vim.schedule(function()
                    state.source_items = items or {}
                    apply_filter(state)
                end)
            end)
        else
            state.source_items = source
            apply_filter(state)
        end
    end

    local function on_query_change()
        state.selected = 1
        if type(source) == "function" and not filter_locally then
            -- Use vim.uv timer instead of vim.fn.timer_*
            if state.debounce_timer then
                state.debounce_timer:stop()
            else
                state.debounce_timer = vim.uv.new_timer()
            end
            state.debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(function()
                update_source(state.query)
            end))
        else
            update_source(state.query)
        end
    end

    -- Initialize prompt line
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "> " })

    -- Initial load
    update_source("")

    -- Keymaps using modern API
    local function map(modes, lhs, rhs)
        vim.keymap.set(modes, lhs, rhs, { buffer = state.buf, nowait = true })
    end

    -- Close
    map({ "i", "n" }, "<Esc>", function() close_picker(state) end)
    map("n", "q", function() close_picker(state) end)

    -- Select
    map({ "i", "n" }, "<CR>", function()
        if #state.display_items > 0 then
            local selected = state.display_items[state.selected]
            close_picker(state)
            on_select(selected, state.query)
        end
    end)

    -- Navigation - define once and reuse
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

    -- Handle text changes via autocmd
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = state.buf,
        callback = function()
            local line = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
            -- Ensure prompt prefix exists
            if not vim.startswith(line, "> ") then
                line = "> " .. line:gsub("^>?%s*", "")
                vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { line })
                vim.api.nvim_win_set_cursor(state.win, { 1, #line })
            end
            local query = line:sub(3)
            if query ~= state.query then
                state.query = query
                on_query_change()
            end
        end,
    })

    -- Start in insert mode at end of prompt
    vim.cmd.startinsert({ bang = true })
    vim.api.nvim_win_set_cursor(state.win, { 1, 2 })

    return state
end

return M

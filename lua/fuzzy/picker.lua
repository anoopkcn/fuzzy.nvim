-- Generic interactive floating picker with live filtering

local match = require("fuzzy.match")

local M = {}

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

    return { buf = buf, win = win, width = width }
end

local function build_separator(width)
    return "─" .. string.rep("─", width - 2) .. "─"
end

local function close_picker(state)
    if state.closed then
        return
    end
    state.closed = true
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_win_close, state.win, true)
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
end

local function render(state)
    if state.closed then
        return
    end

    local items = state.display_items
    state.selected = math.min(state.selected, math.max(1, #items))

    local lines = {}
    -- Line 1: prompt
    lines[1] = "> " .. state.query
    -- Line 2: separator
    lines[2] = build_separator(state.width)
    -- Lines 3+: results
    for i, entry in ipairs(items) do
        local prefix = i == state.selected and "> " or "  "
        local text = type(entry) == "table" and (entry.display or entry.text or entry.item or tostring(entry)) or entry
        lines[#lines + 1] = prefix .. text
    end

    if #items == 0 then
        lines[#lines + 1] = "  No matches"
    end

    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

    -- Highlight prompt line
    vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, 0, 0, {
        end_row = 0,
        end_col = 2,
        hl_group = "Comment",
    })

    -- Highlight separator
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, 1, 0, {
        end_row = 1,
        end_col = #lines[2],
        hl_group = "FloatBorder",
    })

    -- Highlight selected result line (offset by 2 for prompt + separator)
    if #items > 0 then
        local sel_row = state.selected + 1 -- +2 for prompt/separator, -1 for 0-index = +1
        vim.api.nvim_buf_set_extmark(state.buf, state.ns, sel_row, 0, {
            end_row = sel_row,
            end_col = #lines[sel_row + 1],
            hl_group = "CursorLine",
            hl_eol = true,
        })
    end

    -- Position cursor at end of prompt
    pcall(vim.api.nvim_win_set_cursor, state.win, { 1, #lines[1] })
end

local function apply_filter(state)
    if state.filter_locally and state.query ~= "" then
        local scored = match.filter(state.query, state.source_items, state.max_results)
        state.display_items = vim.iter(scored):map(function(e) return e.item end):totable()
    else
        state.display_items = vim.list_slice(state.source_items, 1, state.max_results)
    end
    render(state)
end

local function move_selection(state, delta)
    if #state.display_items == 0 then
        return
    end
    state.selected = state.selected + delta
    if state.selected < 1 then
        state.selected = #state.display_items
    elseif state.selected > #state.display_items then
        state.selected = 1
    end
    render(state)
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
    local on_select = opts.on_select or function(_item, _query) end
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
        ns = vim.api.nvim_create_namespace("fuzzy_picker"),
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
            if state.debounce_timer then
                vim.fn.timer_stop(state.debounce_timer)
            end
            state.debounce_timer = vim.fn.timer_start(debounce_ms, function()
                vim.schedule(function()
                    update_source(state.query)
                end)
            end)
        else
            update_source(state.query)
        end
    end

    -- Initial load
    update_source("")

    -- Keymaps
    local kopts = { buffer = state.buf, noremap = true, silent = true }

    -- Close
    vim.keymap.set({ "i", "n" }, "<Esc>", function()
        close_picker(state)
    end, kopts)

    vim.keymap.set("n", "q", function()
        close_picker(state)
    end, kopts)

    -- Select
    local function do_select()
        if #state.display_items > 0 then
            local selected = state.display_items[state.selected]
            close_picker(state)
            on_select(selected, state.query)
        end
    end

    vim.keymap.set({ "i", "n" }, "<CR>", do_select, kopts)

    -- Navigation
    vim.keymap.set("i", "<C-n>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<C-p>", function() move_selection(state, -1) end, kopts)
    vim.keymap.set("i", "<Down>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<Up>", function() move_selection(state, -1) end, kopts)
    vim.keymap.set("i", "<C-j>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<C-k>", function() move_selection(state, -1) end, kopts)
    vim.keymap.set("i", "<Tab>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<S-Tab>", function() move_selection(state, -1) end, kopts)

    -- Text input handling
    vim.keymap.set("i", "<BS>", function()
        if #state.query > 0 then
            state.query = state.query:sub(1, -2)
            on_query_change()
        end
    end, kopts)

    vim.keymap.set("i", "<C-u>", function()
        state.query = ""
        on_query_change()
    end, kopts)

    vim.keymap.set("i", "<C-w>", function()
        state.query = state.query:gsub("%S+%s*$", "")
        on_query_change()
    end, kopts)

    -- Catch all printable characters
    vim.on_key(function(key)
        if state.closed then
            return
        end
        -- Only handle in insert mode and for this buffer
        if vim.fn.mode() ~= "i" then
            return
        end
        if vim.api.nvim_get_current_buf() ~= state.buf then
            return
        end
        -- Check if it's a printable character (not a special key)
        local byte = key:byte()
        if byte and byte >= 32 and byte < 127 then
            state.query = state.query .. key
            on_query_change()
        end
    end, state.ns)

    -- Start in insert mode
    vim.cmd("startinsert")

    return state
end

return M

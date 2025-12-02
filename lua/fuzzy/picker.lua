-- Generic interactive floating picker with live filtering
-- Can be used with any source (files, grep, buffers, custom)

local match = require("fuzzy.match")

local M = {}

local function create_float_win(opts)
    opts = opts or {}
    local width = opts.width or math.floor(vim.o.columns * 0.7)
    local height = opts.height or math.floor(vim.o.lines * 0.5)
    local row = math.floor((vim.o.lines - height) / 2) - 1
    local col = math.floor((vim.o.columns - width) / 2)

    -- Results buffer (created first, shown below prompt)
    local results_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[results_buf].bufhidden = "wipe"

    local results_win = vim.api.nvim_open_win(results_buf, false, {
        relative = "editor",
        width = width,
        height = height - 3,
        row = row + 3,
        col = col,
        style = "minimal",
        border = "rounded",
    })
    vim.wo[results_win].cursorline = false

    -- Prompt buffer (shown on top)
    local prompt_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[prompt_buf].bufhidden = "wipe"
    vim.bo[prompt_buf].buftype = "prompt"

    local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
        relative = "editor",
        width = width,
        height = 1,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = opts.title or " Fuzzy ",
        title_pos = "center",
    })

    vim.fn.prompt_setprompt(prompt_buf, "> ")

    return {
        prompt_buf = prompt_buf,
        prompt_win = prompt_win,
        results_buf = results_buf,
        results_win = results_win,
    }
end

local function close_picker(state)
    if state.closed then
        return
    end
    state.closed = true

    pcall(vim.api.nvim_win_close, state.prompt_win, true)
    pcall(vim.api.nvim_win_close, state.results_win, true)
    pcall(vim.api.nvim_buf_delete, state.prompt_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, state.results_buf, { force = true })
end

local function render_results(state)
    if state.closed then
        return
    end

    local items = state.display_items
    state.selected = math.min(state.selected, math.max(1, #items))

    local lines = {}
    for i, entry in ipairs(items) do
        local prefix = i == state.selected and "> " or "  "
        local text = type(entry) == "table" and (entry.display or entry.text or entry.item or tostring(entry)) or entry
        lines[i] = prefix .. text
    end

    if #lines == 0 then
        lines = { "  No matches" }
    end

    vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)

    -- Highlight selected line
    vim.api.nvim_buf_clear_namespace(state.results_buf, state.ns, 0, -1)
    if #items > 0 then
        vim.api.nvim_buf_add_highlight(state.results_buf, state.ns, "CursorLine", state.selected - 1, 0, -1)
    end

    -- Scroll results window to keep selection visible
    if #items > 0 and vim.api.nvim_win_is_valid(state.results_win) then
        local win_height = vim.api.nvim_win_get_height(state.results_win)
        local top_line = math.max(1, state.selected - math.floor(win_height / 2))
        pcall(vim.api.nvim_win_set_cursor, state.results_win, { math.min(state.selected, #items), 0 })
        vim.api.nvim_win_call(state.results_win, function()
            vim.cmd("normal! zz")
        end)
    end
end

local function apply_filter(state, query)
    if state.filter_locally and query ~= "" then
        local scored = match.filter(query, state.source_items, state.max_results)
        state.display_items = vim.tbl_map(function(e) return e.item end, scored)
    else
        state.display_items = vim.list_slice(state.source_items, 1, state.max_results)
    end
    render_results(state)
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
    render_results(state)
end

local function get_query(state)
    if not vim.api.nvim_buf_is_valid(state.prompt_buf) then
        return ""
    end
    local line = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ""
    return line:gsub("^> ", "")
end

--- Open an interactive picker
--- @param opts table Options:
---   - source: table|function - Items to pick from, or function(query, callback) for dynamic sources
---   - on_select: function(item) - Called when user selects an item
---   - title: string - Window title
---   - max_results: number - Max items to show (default 50)
---   - filter_locally: boolean - Filter items locally with fuzzy match (default true)
---                               Set to false for dynamic sources that filter themselves (e.g., grep)
---   - debounce_ms: number - Debounce time for dynamic sources (default 150)
function M.open(opts)
    opts = opts or {}
    local source = opts.source or {}
    local on_select = opts.on_select or function() end
    local max_results = opts.max_results or 50
    local filter_locally = opts.filter_locally ~= false
    local debounce_ms = opts.debounce_ms or 150

    local wins = create_float_win({ title = opts.title })

    local state = {
        prompt_buf = wins.prompt_buf,
        prompt_win = wins.prompt_win,
        results_buf = wins.results_buf,
        results_win = wins.results_win,
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
            -- Dynamic source - call function with query
            source(query, function(items)
                if state.closed then
                    return
                end
                vim.schedule(function()
                    state.source_items = items or {}
                    apply_filter(state, filter_locally and query or "")
                end)
            end)
        else
            -- Static source
            state.source_items = source
            apply_filter(state, query)
        end
    end

    local function on_query_change()
        local query = get_query(state)
        state.selected = 1

        if type(source) == "function" and not filter_locally then
            -- Debounce dynamic sources
            if state.debounce_timer then
                vim.fn.timer_stop(state.debounce_timer)
            end
            state.debounce_timer = vim.fn.timer_start(debounce_ms, function()
                vim.schedule(function()
                    update_source(query)
                end)
            end)
        else
            update_source(query)
        end
    end

    -- Initial load
    update_source("")

    -- Handle text changes
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = state.prompt_buf,
        callback = on_query_change,
    })

    -- Keymaps
    local kopts = { buffer = state.prompt_buf, noremap = true, silent = true }

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
            on_select(selected, get_query(state))
        end
    end

    vim.keymap.set("i", "<CR>", do_select, kopts)
    vim.keymap.set("n", "<CR>", do_select, kopts)

    -- Navigation
    vim.keymap.set("i", "<C-n>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<C-p>", function() move_selection(state, -1) end, kopts)
    vim.keymap.set("i", "<Down>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<Up>", function() move_selection(state, -1) end, kopts)
    vim.keymap.set("i", "<C-j>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<C-k>", function() move_selection(state, -1) end, kopts)

    -- Tab to cycle
    vim.keymap.set("i", "<Tab>", function() move_selection(state, 1) end, kopts)
    vim.keymap.set("i", "<S-Tab>", function() move_selection(state, -1) end, kopts)

    -- Start in insert mode
    vim.cmd("startinsert!")

    return state
end

return M

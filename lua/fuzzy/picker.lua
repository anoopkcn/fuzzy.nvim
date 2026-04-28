local match = require("fuzzy.match")
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
---@field items string[]
---@field on_select fun(item: string)
---@field prompt? string
---@field height? integer

---@param opts FuzzyPickerOpts
local function open(opts)
    local items = opts.items or {}
    local prompt = opts.prompt or "Fuzzy"
    local on_select = opts.on_select or function() end

    local cmdh = vim.o.cmdheight
    local max_h = vim.o.lines - cmdh - 6
    local height = math.max(3, math.min(opts.height or 15, max_h))

    local input_buf = vim.api.nvim_create_buf(false, true)
    local result_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].bufhidden = "wipe"
    vim.bo[result_buf].bufhidden = "wipe"

    local width = math.min(80, math.floor(vim.o.columns * 0.6))
    local total_h = height + 5
    local input_row = math.max(0, math.floor((vim.o.lines - total_h) / 2)) + 1
    local result_row = input_row + 3
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local result_win = vim.api.nvim_open_win(result_buf, false, {
        relative = "editor",
        row = result_row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        focusable = false,
    })

    local input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        row = input_row,
        col = col,
        width = width,
        height = 1,
        style = "minimal",
        border = "rounded",
        title = " " .. prompt .. " ",
        title_pos = "left",
    })

    vim.wo[result_win].wrap = false
    vim.wo[result_win].winhighlight = WINHL
    vim.wo[input_win].winhighlight = WINHL

    local current = items
    local cursor = 1
    local closed = false

    local function visible_count() return math.min(height, #current) end

    local function render()
        local n = visible_count()
        local lines = {}
        for i = 1, n do lines[i] = current[i] end
        vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(result_buf, ns, 0, -1)

        local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""

        for i = 1, n do
            local row = i - 1
            local line = current[i]
            local slash = line:find("/[^/]*$")

            if slash then
                vim.api.nvim_buf_set_extmark(result_buf, ns, row, 0, {
                    end_col = slash, hl_group = HL.dir, priority = 100,
                })
            end
            vim.api.nvim_buf_set_extmark(result_buf, ns, row, slash or 0, {
                end_col = #line, hl_group = HL.file, priority = 100,
            })

            if query ~= "" then
                local pos = match.positions(query, line)
                if pos then
                    for _, p in ipairs(pos) do
                        vim.api.nvim_buf_set_extmark(result_buf, ns, row, p - 1, {
                            end_col = p, hl_group = HL.match, priority = 200,
                        })
                    end
                end
            end
        end

        if cursor >= 1 and cursor <= n then
            vim.api.nvim_buf_set_extmark(result_buf, ns, cursor - 1, 0, {
                end_row = cursor, hl_group = HL.sel, hl_eol = true, priority = 50,
            })
        end
    end

    local function update_filter()
        local query = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
        if query == "" then
            current = items
        else
            current = vim.iter(match.filter(query, items, height))
                :map(function(e) return e.item end)
                :totable()
        end
        cursor = 1
        render()
    end

    local function close()
        if closed then return end
        closed = true
        vim.cmd.stopinsert()
        if vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
        if vim.api.nvim_win_is_valid(result_win) then vim.api.nvim_win_close(result_win, true) end
    end

    local function accept()
        local picked = current[cursor]
        close()
        if picked then on_select(picked) end
    end

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
        local n = visible_count()
        if n == 0 then return end
        cursor = math.max(1, math.min(n, cursor + delta))
        render()
    end

    imap("<CR>", accept)
    imap("<C-n>", function() move(1) end)
    imap("<Down>", function() move(1) end)
    imap("<C-p>", function() move(-1) end)
    imap("<Up>", function() move(-1) end)
    imap("<Esc>", close)
    imap("<C-c>", close)

    render()
    vim.cmd.startinsert()
end

---@param kind "files"|"buffers"
local function open_for(kind)
    if kind == "files" then
        local complete = require("fuzzy.complete")
        local items = complete.get_files() or {}
        if #items == 0 then
            vim.notify("Fuzzy: file cache is empty (try again in a moment).", vim.log.levels.INFO)
            return
        end
        open({
            items = items,
            prompt = "Files",
            on_select = function(path) util.open_file(path) end,
        })
    elseif kind == "buffers" then
        local bufs = util.get_listed_buffers()
        local items = {}
        local by_path = {}
        for _, b in ipairs(bufs) do
            local rel = vim.fn.fnamemodify(b.path, ":.")
            items[#items + 1] = rel
            by_path[rel] = b.bufnr
        end
        if #items == 0 then
            vim.notify("Fuzzy: no listed buffers.", vim.log.levels.INFO)
            return
        end
        open({
            items = items,
            prompt = "Buffers",
            on_select = function(rel)
                local bufnr = by_path[rel]
                if bufnr then util.switch_to_buffer(bufnr) end
            end,
        })
    end
end

M.open = open
M.open_for = open_for

return M

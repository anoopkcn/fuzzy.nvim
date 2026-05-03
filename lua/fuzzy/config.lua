local M = {}

---@class FuzzyWindowConfig
---@field height number Max fraction of vim.o.lines used for the picker (0..1)
---@field width number Fraction of vim.o.columns used for the picker (0..1)
---@field row number Vertical position, 0=top, 1=bottom of free space
---@field col number Horizontal position, 0=left, 1=right of free space
---@field border string|table Border passed to nvim_open_win
---@field title_pos "left"|"center"|"right" Title alignment passed to nvim_open_win
---@field prompt string Sigil rendered before the input query (e.g. "> ", "❯ ")
---@field nerd_font boolean Use Unicode glyphs for selection/cursor markers
---@field cursor_indicator boolean Show a left-edge bar on the cursor row
---@field keys_hint boolean|string Footer cheatsheet (true = default text, string = custom)
---@field show_count boolean Show "visible/total" counter in title

---@class FuzzyConfig
---@field open_single_result boolean Auto-open when only one result matches
---@field file_match_limit integer Maximum number of files to return from fd
---@field grep_dedupe boolean Deduplicate grep results by file:line (default: true)
---@field send_to_qf_key string|false Key to send picker results to quickfix (false to disable)
---@field edit_grep_flags_key string|false Key to edit ripgrep flags in live grep pickers (false to disable)
---@field window FuzzyWindowConfig Picker window geometry and border
local defaults = {
    open_single_result = false,
    file_match_limit = 10000,
    grep_dedupe = true,
    send_to_qf_key = "<M-q>",
    edit_grep_flags_key = "<M-r>",
    window = {
        height = 0.4,
        width  = 0.6,
        row    = 0.0,
        col    = 0.5,
        border = "rounded",
        title_pos = "center",
        prompt = "> ",
        nerd_font = false,
        cursor_indicator = true,
        keys_hint = false,
        show_count = true,
    },
}

---@type FuzzyConfig
local config = vim.deepcopy(defaults)

-- Command names (centralized for consistency)
M.commands = {
    GREP = "FuzzyGrep",
    GREP_IN = "FuzzyGrepIn",
    FILES = "FuzzyFiles",
    BUFFERS = "FuzzyBuffers",
    COMMANDS = "FuzzyCommands",
    LIST = "FuzzyList",
}

---@param opts? FuzzyConfig
function M.setup(opts)
    if opts then
        vim.validate("open_single_result", opts.open_single_result, "boolean", true)
        vim.validate("file_match_limit", opts.file_match_limit, "number", true)
        vim.validate("grep_dedupe", opts.grep_dedupe, "boolean", true)
        if opts.send_to_qf_key ~= nil then
            assert(
                opts.send_to_qf_key == false or type(opts.send_to_qf_key) == "string",
                "send_to_qf_key must be a string or false"
            )
        end
        if opts.edit_grep_flags_key ~= nil then
            assert(
                opts.edit_grep_flags_key == false or type(opts.edit_grep_flags_key) == "string",
                "edit_grep_flags_key must be a string or false"
            )
        end
        if opts.window ~= nil then
            vim.validate("window", opts.window, "table")
            local w = opts.window
            local function unit(name, v, must_be_positive)
                if v == nil then return end
                assert(type(v) == "number", name .. " must be a number")
                assert(v >= 0 and v <= 1, name .. " must be between 0 and 1")
                if must_be_positive then
                    assert(v > 0, name .. " must be greater than 0")
                end
            end
            unit("window.height", w.height, true)
            unit("window.width", w.width, true)
            unit("window.row", w.row, false)
            unit("window.col", w.col, false)
            if w.border ~= nil then
                assert(
                    type(w.border) == "string" or type(w.border) == "table",
                    "window.border must be a string or table"
                )
            end
            if w.title_pos ~= nil then
                assert(
                    w.title_pos == "left" or w.title_pos == "center" or w.title_pos == "right",
                    'window.title_pos must be "left", "center" or "right"'
                )
            end
        end
    end
    config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@return FuzzyConfig
function M.get()
    return config
end

return M

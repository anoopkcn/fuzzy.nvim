-- Window/buffer scaffolding for the picker.
--
-- Returns a `view` table with the three buffers, the three windows, geometry
-- numbers and a couple of helpers (`write_frame`, `resize`). The render layer
-- and the controller in picker/init.lua treat this as opaque state.

local config = require("fuzzy.config")
local highlight = require("fuzzy.picker.highlight")

local HL = highlight.HL
local WINHL = highlight.WINHL
local CONTENT_WINHL = highlight.CONTENT_WINHL

local M = {}

local function divider_line(width)
    local fillchars = vim.opt.fillchars:get()
    local horiz = type(fillchars) == "table" and fillchars.horiz or nil
    if type(horiz) ~= "string" or horiz == "" then horiz = "-" end
    return horiz:rep(width)
end

---@param opts { title: string, ns: integer, item_count: integer }
---@return table view
function M.create(opts)
    local win_cfg = config.get().window
    local cmdh = vim.o.cmdheight
    local total_lines = vim.o.lines - cmdh
    local total_cols = vim.o.columns
    local max_h_lines = math.floor(total_lines * win_cfg.height)
    local max_height = math.max(3, math.min(max_h_lines - 2, total_lines - 6))

    local frame_buf  = vim.api.nvim_create_buf(false, true)
    local input_buf  = vim.api.nvim_create_buf(false, true)
    local result_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[frame_buf].bufhidden  = "wipe"
    vim.bo[input_buf].bufhidden  = "wipe"
    vim.bo[result_buf].bufhidden = "wipe"

    local width = math.max(10, math.floor(total_cols * win_cfg.width))
    -- Anchor against max frame height so the picker doesn't jitter as results filter.
    local frame_h_max = max_height + 2
    local frame_row = math.max(0, math.floor((total_lines - frame_h_max) * win_cfg.row))
    local frame_col = math.max(0, math.floor((total_cols - (width + 2)) * win_cfg.col))
    local input_row  = frame_row + 1
    local result_row = frame_row + 3
    local content_col = frame_col + 1

    local blank = (" "):rep(width)
    local divider = divider_line(width)

    local ns = opts.ns

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

    local displayed = math.min(opts.item_count, max_height)
    write_frame(displayed)

    local frame_win = vim.api.nvim_open_win(frame_buf, false, {
        relative = "editor",
        row = frame_row,
        col = frame_col,
        width = width,
        height = (displayed == 0) and 1 or (displayed + 2),
        style = "minimal",
        border = win_cfg.border,
        focusable = false,
        zindex = 40,
        title = " " .. opts.title .. " ",
        title_pos = win_cfg.title_pos,
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
    vim.wo[frame_win].winhighlight  = WINHL
    vim.wo[result_win].winhighlight = CONTENT_WINHL
    vim.wo[input_win].winhighlight  = CONTENT_WINHL

    local view = {
        ns          = ns,
        width       = width,
        max_height  = max_height,
        displayed   = displayed,
        frame_row   = frame_row,
        frame_col   = frame_col,
        result_row  = result_row,
        content_col = content_col,
        frame_buf   = frame_buf,
        input_buf   = input_buf,
        result_buf  = result_buf,
        frame_win   = frame_win,
        input_win   = input_win,
        result_win  = result_win,
        write_frame = write_frame,
    }

    --- Resize the result/frame windows when the visible item count changes.
    function view.resize(target)
        target = math.min(math.max(0, target), view.max_height)
        if target == view.displayed then return end
        view.displayed = target
        write_frame(target)
        pcall(vim.api.nvim_win_set_config, view.frame_win, {
            relative = "editor",
            row = view.frame_row,
            col = view.frame_col,
            width = view.width,
            height = (target == 0) and 1 or (target + 2),
        })
        pcall(vim.api.nvim_win_set_config, view.result_win, {
            relative = "editor",
            row = view.result_row,
            col = view.content_col,
            width = view.width,
            height = math.max(1, target),
            hide = target == 0,
        })
    end

    function view.set_title(new_title)
        if vim.api.nvim_win_is_valid(view.frame_win) then
            pcall(vim.api.nvim_win_set_config, view.frame_win, { title = " " .. new_title .. " " })
        end
    end

    function view.close()
        if vim.api.nvim_win_is_valid(view.input_win)  then pcall(vim.api.nvim_win_close, view.input_win,  true) end
        if vim.api.nvim_win_is_valid(view.result_win) then pcall(vim.api.nvim_win_close, view.result_win, true) end
        if vim.api.nvim_win_is_valid(view.frame_win)  then pcall(vim.api.nvim_win_close, view.frame_win,  true) end
    end

    return view
end

return M

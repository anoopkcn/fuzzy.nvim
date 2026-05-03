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

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_TICK_MS = 80

local function divider_line(width)
    local fillchars = vim.opt.fillchars:get()
    local horiz = type(fillchars) == "table" and fillchars.horiz or nil
    if type(horiz) ~= "string" or horiz == "" then horiz = "─" end
    return horiz:rep(width)
end

---@param opts { title: string, ns: integer, item_count: integer, prompt_sigil?: string }
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
    local prompt_sigil = opts.prompt_sigil or win_cfg.prompt or "> "

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
                end_col = #divider, hl_group = HL.border, priority = 100,
            })
        end
        vim.bo[frame_buf].modifiable = false
    end

    local displayed = math.min(opts.item_count, max_height)
    write_frame(displayed)

    -- Title is always rebuilt by build_title_chunks() so the initial frame uses
    -- a placeholder. Real title goes in after open_win.
    local title_chunks = {{ " " .. opts.title .. " ", HL.title }}

    -- Hint footer is opt-in. Built once; doesn't change.
    local footer_chunks
    if win_cfg.keys_hint then
        local hint
        if type(win_cfg.keys_hint) == "string" then
            hint = win_cfg.keys_hint
        else
            hint = " <CR> open  <Tab> mark  <M-q> qf  <Esc> close "
        end
        footer_chunks = {{ hint, HL.hint }}
    end

    local frame_open_opts = {
        relative = "editor",
        row = frame_row,
        col = frame_col,
        width = width,
        height = (displayed == 0) and 1 or (displayed + 2),
        style = "minimal",
        border = win_cfg.border,
        focusable = false,
        zindex = 40,
        title = title_chunks,
        title_pos = win_cfg.title_pos,
    }
    if footer_chunks then
        frame_open_opts.footer = footer_chunks
        frame_open_opts.footer_pos = "right"
    end
    local frame_win = vim.api.nvim_open_win(frame_buf, false, frame_open_opts)

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

    -- Prompt sigil: inline virt_text anchored at col 0 of the input buffer.
    -- right_gravity=false keeps it pinned to start when the user types.
    local prompt_extmark
    local function refresh_prompt()
        if not vim.api.nvim_buf_is_valid(input_buf) then return end
        prompt_extmark = vim.api.nvim_buf_set_extmark(input_buf, ns, 0, 0, {
            id = prompt_extmark,
            virt_text = {{ prompt_sigil, HL.prompt }},
            virt_text_pos = "inline",
            right_gravity = false,
            priority = 100,
        })
    end
    refresh_prompt()

    -- Title state: title text, optional {visible,total} count, optional spinner.
    local title_text = opts.title
    local count_state = nil  -- { visible, total } or nil
    local loading = false
    local spinner_idx = 1
    local spinner_timer
    local last_title_chunks

    local function build_title_chunks()
        local chunks = { { " ", HL.title }, { title_text, HL.title } }
        if count_state then
            local v, t = count_state[1], count_state[2]
            local s
            if t and t ~= v then
                s = ("  %d/%d"):format(v, t)
            else
                s = ("  %d"):format(v)
            end
            chunks[#chunks + 1] = { s, HL.count }
        end
        if loading then
            chunks[#chunks + 1] = { "  " .. SPINNER_FRAMES[spinner_idx], HL.hint }
        end
        chunks[#chunks + 1] = { " ", HL.title }
        return chunks
    end

    local function apply_title()
        if not vim.api.nvim_win_is_valid(frame_win) then return end
        local chunks = build_title_chunks()
        last_title_chunks = chunks
        pcall(vim.api.nvim_win_set_config, frame_win, { title = chunks })
    end

    local function start_spinner()
        if spinner_timer then return end
        spinner_timer = vim.uv.new_timer()
        spinner_timer:start(SPINNER_TICK_MS, SPINNER_TICK_MS, vim.schedule_wrap(function()
            if not loading or not vim.api.nvim_win_is_valid(frame_win) then return end
            spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
            apply_title()
        end))
    end

    local function stop_spinner()
        if not spinner_timer then return end
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
    end

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
        refresh_prompt = refresh_prompt,
    }

    --- Resize the result/frame windows when the visible item count changes.
    function view.resize(target)
        target = math.min(math.max(0, target), view.max_height)
        if target == view.displayed then return end
        view.displayed = target
        write_frame(target)
        -- Coalesce into one redraw flush so frame and result resize together.
        pcall(vim.api.nvim__redraw, { flush = false })
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
        pcall(vim.api.nvim__redraw, { win = view.frame_win, flush = true })
    end

    function view.set_title(new_title)
        if type(new_title) ~= "string" or new_title == "" then return end
        title_text = new_title
        apply_title()
    end

    function view.set_count(visible, total)
        if visible == nil then
            count_state = nil
        else
            count_state = { visible, total }
        end
        apply_title()
    end

    function view.set_loading(on)
        on = not not on
        if on == loading then return end
        loading = on
        if loading then
            spinner_idx = 1
            start_spinner()
        else
            stop_spinner()
        end
        apply_title()
    end

    apply_title()

    function view.close()
        stop_spinner()
        if vim.api.nvim_win_is_valid(view.input_win)  then pcall(vim.api.nvim_win_close, view.input_win,  true) end
        if vim.api.nvim_win_is_valid(view.result_win) then pcall(vim.api.nvim_win_close, view.result_win, true) end
        if vim.api.nvim_win_is_valid(view.frame_win)  then pcall(vim.api.nvim_win_close, view.frame_win,  true) end
    end

    return view
end

return M

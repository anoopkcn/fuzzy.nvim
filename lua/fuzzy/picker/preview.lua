-- Picker preview pane.
--
-- Attaches a single floating window below the picker that renders the contents
-- of whichever item is currently focused. The picker owns nothing about the
-- preview lifecycle except calling refresh() on cursor moves and close() on
-- teardown -- everything else lives here.
--
-- Source dispatch: the picker passes a `source` = { kind, resolve } table.
-- `resolve(item)` returns a target { path?, bufnr?, lnum?, col?, pattern? } or
-- nil. Kind ∈ { "file", "buffer", "grep", "help" } drives the read strategy.

local config    = require("fuzzy.config")
local highlight = require("fuzzy.picker.highlight")

local HL          = highlight.HL
local CONTENT_WINHL = ("Normal:%s,FloatBorder:%s"):format(HL.normal, HL.border)

local REFRESH_DEBOUNCE_MS = 50
local FT_LINE_LIMIT       = 1500   -- skip filetype assignment beyond this

local M = {}

-- ---------- target key (used to skip identical re-renders) ----------

local function target_key(kind, t)
    if not t then return nil end
    if kind == "buffer" then
        return ("buf:%s:%s"):format(tostring(t.bufnr or ""), t.path or "")
    elseif kind == "grep" then
        return ("grep:%s:%d"):format(t.path or "", t.lnum or 0)
    elseif kind == "help" then
        return ("help:%s:%s:%s"):format(t.path or "", t.lnum or "", t.pattern or "")
    end
    return ("file:%s"):format(t.path or "")
end

-- ---------- file readers ----------

-- Read up to `max` lines from `path`. Returns lines or nil on error.
local function read_file(path, max)
    if not path or path == "" then return nil end
    local ok, lines = pcall(vim.fn.readfile, path, "", max)
    if not ok or type(lines) ~= "table" then return nil end
    return lines
end

-- Cheap binary detection: NUL byte in the first few lines.
local function looks_binary(lines)
    local probe = table.concat(lines, "\n", 1, math.min(#lines, 4))
    return probe:find("\0", 1, true) ~= nil
end

-- ---------- render builders ----------

-- Build the (lines, match_row, ft) tuple for a resolved target.
-- match_row is 0-based row inside the returned lines, or nil if no match line.
local function build_file(target, max_lines)
    local lines = read_file(target.path, max_lines)
    if not lines then return { "(no preview)" }, nil, nil end
    if #lines == 0 then return { "(empty file)" }, nil, nil end
    if looks_binary(lines) then return { "(binary file)" }, nil, nil end
    local ft = vim.filetype.match({ filename = target.path }) or ""
    return lines, nil, ft
end

local function build_buffer(target, max_lines)
    local bufnr = target.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, max_lines, false)
        if #lines == 0 then return { "(empty buffer)" }, nil, vim.bo[bufnr].filetype end
        return lines, nil, vim.bo[bufnr].filetype
    end
    -- Fall back to on-disk contents.
    return build_file(target, max_lines)
end

local function build_grep(target, ctx, max_lines)
    local lnum = target.lnum or 1
    local start_l = math.max(1, lnum - ctx)
    local end_l   = lnum + ctx
    local head = read_file(target.path, math.min(end_l, max_lines))
    if not head then return { "(no preview)" }, nil, nil end
    if looks_binary(head) then return { "(binary file)" }, nil, nil end
    local out = {}
    for i = start_l, math.min(end_l, #head) do
        out[#out + 1] = head[i]
    end
    if #out == 0 then return { "(line out of range)" }, nil, nil end
    local match_row = lnum - start_l   -- 0-based offset within `out`
    local ft = vim.filetype.match({ filename = target.path }) or ""
    return out, match_row, ft
end

local function build_help(target, ctx, max_lines)
    if target.lnum and target.lnum > 0 then
        return build_grep(target, ctx, max_lines)
    end
    if not target.pattern or target.pattern == "" then
        return build_file(target, max_lines)
    end
    local all = read_file(target.path, max_lines)
    if not all then return { "(no preview)" }, nil, nil end
    if looks_binary(all) then return { "(binary file)" }, nil, nil end
    local hit
    for i, line in ipairs(all) do
        if line:find(target.pattern, 1, true) then
            hit = i
            break
        end
    end
    if not hit then return all, nil, vim.filetype.match({ filename = target.path }) or "" end
    local start_l = math.max(1, hit - 2)
    local end_l   = math.min(#all, hit + ctx)
    local out = {}
    for i = start_l, end_l do out[#out + 1] = all[i] end
    return out, hit - start_l, vim.filetype.match({ filename = target.path }) or ""
end

local function build(source_kind, target, cfg)
    local max_lines = cfg.preview_max_lines or 5000
    if source_kind == "buffer" then
        return build_buffer(target, max_lines)
    elseif source_kind == "grep" then
        return build_grep(target, cfg.preview_grep_context or 10, max_lines)
    elseif source_kind == "help" then
        return build_help(target, cfg.preview_grep_context or 10, max_lines)
    end
    return build_file(target, max_lines)
end

-- ---------- geometry ----------

local function geometry(view)
    local win_cfg     = config.get().window
    local total_lines = vim.o.lines - vim.o.cmdheight
    local border      = win_cfg.border
    local has_border  = border ~= nil and border ~= "none"
    local border_h    = has_border and 2 or 0
    local picker_bot  = view.frame_row + view.max_height + 2 + border_h
    local desired_h   = math.max(3, math.floor(total_lines * (win_cfg.preview_height or 0.3)))
    local row         = picker_bot
    local col         = view.frame_col
    local room        = total_lines - row - border_h
    if room < 3 then return nil end
    return {
        relative  = "editor",
        row       = row,
        col       = col,
        width     = view.width,
        height    = math.min(desired_h, room),
        style     = "minimal",
        border    = border,
        -- focusable=true lets the user click the preview to select/yank
        -- without dismissing the picker. The picker's WinEnter handler
        -- whitelists this window so focus shifts here don't close it.
        focusable = true,
        zindex    = 45,
        noautocmd = true,
    }
end

-- ---------- attach ----------

---@param args { view: table, source: table, get_cursor: fun(): any?, get_query: fun(): string, enabled: boolean, input_win: integer|nil }
---@return table preview_ctrl
function M.attach(args)
    local view       = args.view
    local source     = args.source
    local get_cursor = args.get_cursor
    local get_query  = args.get_query
    local input_win  = args.input_win
    local kind       = source and source.kind or "file"
    local resolve    = source and source.resolve or function(_) return nil end

    local match_ns      = vim.api.nvim_create_namespace("fuzzy.picker.preview_match")
    local enabled       = args.enabled == true
    local closed        = false
    local notified_full = false
    local win, buf
    local last_key      = nil
    local current_ft    = nil
    local pending       = false
    local timer         = vim.uv.new_timer()
    local own_augroup

    local ctrl = {}

    local function teardown_win()
        current_ft = nil
        if own_augroup then
            pcall(vim.api.nvim_del_augroup_by_id, own_augroup)
            own_augroup = nil
        end
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        win = nil
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        buf = nil
        last_key = nil
    end

    local function ensure_win()
        if win and vim.api.nvim_win_is_valid(win) then return true end
        local geom = geometry(view)
        if not geom then
            if not notified_full then
                notified_full = true
                vim.schedule(function()
                    vim.notify("Fuzzy: not enough room for preview", vim.log.levels.INFO)
                end)
            end
            return false
        end
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].modifiable = false
        if input_win then
            local function return_to_input()
                if vim.api.nvim_win_is_valid(input_win) then
                    pcall(vim.api.nvim_set_current_win, input_win)
                    pcall(vim.cmd, "startinsert")
                end
            end
            for _, lhs in ipairs({ "<Esc>", "q", "<CR>" }) do
                vim.keymap.set("n", lhs, return_to_input,
                    { buffer = buf, nowait = true, silent = true })
            end
        end
        win = vim.api.nvim_open_win(buf, false, geom)
        vim.wo[win].wrap = false
        vim.wo[win].number = false
        vim.wo[win].signcolumn = "no"
        vim.wo[win].winhighlight = CONTENT_WINHL
        vim.wo[win].cursorline = false
        own_augroup = vim.api.nvim_create_augroup(
            "fuzzy.picker.preview." .. buf, { clear = true })
        vim.api.nvim_create_autocmd("WinClosed", {
            group = own_augroup,
            pattern = tostring(win),
            callback = function()
                -- Externally closed; clear local refs so we re-open on next refresh.
                win = nil
                buf = nil
                last_key = nil
                current_ft = nil
            end,
        })
        return true
    end

    local function apply_match_highlight(match_row, query)
        if not match_row then return end
        if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
        vim.api.nvim_buf_set_extmark(buf, match_ns, match_row, 0, {
            end_row = match_row + 1,
            hl_group = HL.previewMatch,
            hl_eol = true,
            priority = 200,
        })
        if query and query ~= "" then
            local line = vim.api.nvim_buf_get_lines(buf, match_row, match_row + 1, false)[1]
            if line then
                local s, e = line:lower():find(query:lower(), 1, true)
                if s and e then
                    vim.api.nvim_buf_set_extmark(buf, match_ns, match_row, s - 1, {
                        end_col = e,
                        hl_group = HL.match,
                        priority = 220,
                    })
                end
            end
        end
    end

    local function set_lines(lines)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
    end

    local function do_render()
        if closed or not enabled then return end
        if not ensure_win() then return end

        local item = get_cursor and get_cursor() or nil
        local target = item ~= nil and resolve(item) or nil

        local key = target_key(kind, target)
        if key == last_key then return end
        last_key = key

        if not target then
            set_lines({ "(no preview)" })
            vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)
            if current_ft ~= "" then
                pcall(function() vim.bo[buf].filetype = "" end)
                current_ft = ""
            end
            return
        end

        local cfg = config.get()
        local lines, match_row, ft = build(kind, target, cfg)
        lines = lines or { "(no preview)" }

        set_lines(lines)
        vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)

        local want_ft = (#lines > FT_LINE_LIMIT) and "" or (ft or "")
        if want_ft ~= current_ft then
            current_ft = want_ft
            pcall(function() vim.bo[buf].filetype = want_ft end)
        end

        local query = get_query and get_query() or ""
        apply_match_highlight(match_row, kind == "grep" and query or nil)

        -- Center the matched (or first) line.
        local cursor_line = (match_row or 0) + 1
        cursor_line = math.min(cursor_line, math.max(1, #lines))
        pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
        if match_row then
            pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
        else
            pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! gg") end)
        end
    end

    function ctrl.refresh()
        if closed or not enabled then return end
        if pending then return end
        pending = true
        timer:start(REFRESH_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            pending = false
            if closed then return end
            do_render()
        end))
    end

    function ctrl.toggle()
        if closed then return end
        enabled = not enabled
        if enabled then
            do_render()
        else
            teardown_win()
        end
    end

    function ctrl.close()
        if closed then return end
        closed = true
        if timer then
            timer:stop()
            timer:close()
            timer = nil
        end
        teardown_win()
    end

    function ctrl.is_open()
        return enabled and win ~= nil and vim.api.nvim_win_is_valid(win)
    end

    function ctrl.get_win()
        if win and vim.api.nvim_win_is_valid(win) then return win end
        return nil
    end

    local function scroll(termcode)
        if closed or not ctrl.is_open() then return end
        local keys = vim.api.nvim_replace_termcodes("normal! " .. termcode, true, false, true)
        pcall(vim.api.nvim_win_call, win, function() vim.cmd(keys) end)
    end

    local function mousescroll_ver()
        for part in (vim.o.mousescroll or ""):gmatch("[^,]+") do
            local n = part:match("^ver:(%d+)$")
            if n then return tonumber(n) end
        end
        return 3
    end

    function ctrl.scroll_down() scroll("<C-d>") end
    function ctrl.scroll_up()   scroll("<C-u>") end
    function ctrl.mouse_scroll_down() scroll(("%d<C-e>"):format(mousescroll_ver())) end
    function ctrl.mouse_scroll_up()   scroll(("%d<C-y>"):format(mousescroll_ver())) end

    if enabled then
        -- Defer initial render so the picker has time to populate the first cursor.
        vim.schedule(function() if not closed then do_render() end end)
    end

    return ctrl
end

return M

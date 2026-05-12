-- Picker preview content.
--
-- The picker's `view` (picker/window.lua) owns the preview buffer/window and
-- their geometry; this module only computes content. attach() returns a small
-- controller the picker calls on cursor moves, toggles, and scroll.
--
-- Source dispatch: the picker passes a `source` = { kind, resolve } table.
-- `resolve(item)` returns a target { path?, bufnr?, lnum?, col?, pattern? }
-- or nil. Kind ∈ { "file", "buffer", "grep", "help" } drives the read
-- strategy. The view writes lines via view.set_preview_lines(); we just
-- decide WHAT to write and where to place the matched-line highlight.

local config    = require("fuzzy.config")
local highlight = require("fuzzy.picker.highlight")

local HL = highlight.HL

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

local function read_file(path, max)
    if not path or path == "" then return nil end
    local ok, lines = pcall(vim.fn.readfile, path, "", max)
    if not ok or type(lines) ~= "table" then return nil end
    return lines
end

local function looks_binary(lines)
    local probe = table.concat(lines, "\n", 1, math.min(#lines, 4))
    return probe:find("\0", 1, true) ~= nil
end

-- ---------- per-kind builders ----------

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
    local match_row = lnum - start_l
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

    local match_ns   = vim.api.nvim_create_namespace("fuzzy.picker.preview_match")
    local enabled    = args.enabled == true
    local closed     = false
    local last_key   = nil
    local current_ft = nil
    local pending    = false
    local timer      = vim.uv.new_timer()

    local ctrl = {}

    -- Return-to-input keymaps on the preview buffer. Lets the user click into
    -- the preview to select/yank text, then press <Esc>/q/<CR> to resume
    -- typing in the picker without dismissing it.
    if input_win and view.preview_buf and vim.api.nvim_buf_is_valid(view.preview_buf) then
        local function return_to_input()
            if vim.api.nvim_win_is_valid(input_win) then
                pcall(vim.api.nvim_set_current_win, input_win)
                pcall(vim.cmd, "startinsert")
            end
        end
        for _, lhs in ipairs({ "<Esc>", "q", "<CR>" }) do
            vim.keymap.set("n", lhs, return_to_input,
                { buffer = view.preview_buf, nowait = true, silent = true })
        end
    end

    local function apply_match_highlight(match_row, query)
        local b = view.preview_buf
        if not match_row or not (b and vim.api.nvim_buf_is_valid(b)) then return end
        vim.api.nvim_buf_set_extmark(b, match_ns, match_row, 0, {
            end_row = match_row + 1,
            hl_group = HL.previewMatch,
            hl_eol = true,
            priority = 200,
        })
        if query and query ~= "" then
            local line = vim.api.nvim_buf_get_lines(b, match_row, match_row + 1, false)[1]
            if line then
                local s, e = line:lower():find(query:lower(), 1, true)
                if s and e then
                    vim.api.nvim_buf_set_extmark(b, match_ns, match_row, s - 1, {
                        end_col = e, hl_group = HL.match, priority = 220,
                    })
                end
            end
        end
    end

    local function do_render()
        if closed or not enabled then return end
        local b, w = view.preview_buf, view.preview_win
        if not (b and w and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_win_is_valid(w)) then
            return
        end

        local item = get_cursor and get_cursor() or nil
        local target = item ~= nil and resolve(item) or nil

        local key = target_key(kind, target)
        if key == last_key then return end
        last_key = key

        if not target then
            view.set_preview_lines({ "(no preview)" })
            vim.api.nvim_buf_clear_namespace(b, match_ns, 0, -1)
            if current_ft ~= "" then
                pcall(function() vim.bo[b].filetype = "" end)
                current_ft = ""
            end
            return
        end

        local cfg = config.get()
        local lines, match_row, ft = build(kind, target, cfg)
        lines = lines or { "(no preview)" }

        view.set_preview_lines(lines)
        vim.api.nvim_buf_clear_namespace(b, match_ns, 0, -1)

        local want_ft = (#lines > FT_LINE_LIMIT) and "" or (ft or "")
        if want_ft ~= current_ft then
            current_ft = want_ft
            pcall(function() vim.bo[b].filetype = want_ft end)
        end

        local query = get_query and get_query() or ""
        apply_match_highlight(match_row, kind == "grep" and query or nil)

        local cursor_line = (match_row or 0) + 1
        cursor_line = math.min(cursor_line, math.max(1, #lines))
        pcall(vim.api.nvim_win_set_cursor, w, { cursor_line, 0 })
        if match_row then
            pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! zz") end)
        else
            pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! gg") end)
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
        view.set_preview_visible(enabled)
        if enabled then
            -- Force a fresh render so the next show doesn't skip on a stale key.
            last_key = nil
            do_render()
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
        -- Buffer + window are owned by the view; view.close() tears them down.
    end

    function ctrl.is_open()
        return enabled
            and view.preview_win ~= nil
            and vim.api.nvim_win_is_valid(view.preview_win)
    end

    function ctrl.get_win()
        if view.preview_win and vim.api.nvim_win_is_valid(view.preview_win) then
            return view.preview_win
        end
        return nil
    end

    local function scroll(termcode)
        if closed or not ctrl.is_open() then return end
        local keys = vim.api.nvim_replace_termcodes("normal! " .. termcode, true, false, true)
        pcall(vim.api.nvim_win_call, view.preview_win, function() vim.cmd(keys) end)
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
        vim.schedule(function() if not closed then do_render() end end)
    end

    return ctrl
end

return M

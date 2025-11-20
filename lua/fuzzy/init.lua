-- LICENSE: MIT
-- by @anoopkcn
-- https://github.com/anoopkcn/dotfiles/blob/main/nvim/lua/fuzzy/init.lua
-- Description: Neovim fuzzy helpers for grep, files, buffers and help that feed the quickfix list.
-- Provides commands:
--   :FuzzyGrep [pattern] [rg options] - Runs ripgrep with the given pattern and populates the quickfix list with results.
--   :FuzzyFiles[!] [fd arguments]     - Runs fd with the supplied arguments (use --noignore to include gitignored files).
--                                       Add ! to open a single match directly.
--   :FuzzyBuffers[!]                  - Lists all listed buffers in the quickfix list (! enables live updates).
--   :FuzzyHelp [pattern]              - Fuzzy search Vim help tags and documentation.
--   :FuzzyList                        - Pick a quickfix list from history (excluding the selector itself) and open it.

local FUZZY_CONTEXT_KEY = "fuzzy_owner"
local FUZZY_CONTEXT_VALUE = "lua/fuzzy"
local DEFAULT_CONFIG = {
    open_single_result = false,
    file_match_limit = 600,
}

local config = vim.deepcopy(DEFAULT_CONFIG)
local quickfix_ids = {}
local fuzzy_buffers_autocmd_group = vim.api.nvim_create_augroup("FuzzyBuffersLive", { clear = true })
local fuzzy_buffers_updating = false

-- Setup autocmd to handle help tag opening from quickfix
local fuzzy_help_group = vim.api.nvim_create_augroup("FuzzyHelp", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
    group = fuzzy_help_group,
    pattern = "qf",
    callback = function(args)
        local qf_info = vim.fn.getqflist({ title = 1, context = 1 })
        if qf_info.context and qf_info.context.command == "FuzzyHelp" then
            -- Map Enter to open help instead of trying to edit
            vim.keymap.set("n", "<CR>", function()
                local idx = vim.fn.line(".")
                local qf_items = vim.fn.getqflist()
                local item = qf_items[idx]
                if item and item.text and item.text ~= "" then
                    vim.cmd.cclose()
                    vim.cmd({ cmd = "help", args = { item.text } })
                end
            end, { buffer = args.buf, desc = "Open help tag" })
        end
    end,
})

local function get_file_match_limit()
    local limit = tonumber(config.file_match_limit) or DEFAULT_CONFIG.file_match_limit
    return math.max(math.floor(limit), 1)
end

local function is_fuzzy_context(ctx, command)
    return type(ctx) == "table"
        and ctx[FUZZY_CONTEXT_KEY] == FUZZY_CONTEXT_VALUE
        and (command == nil or ctx.command == command)
end

local function get_quickfix_info(opts)
    local ok, info = pcall(vim.fn.getqflist, opts)
    return ok and type(info) == "table" and info or nil
end

local function get_quickfix_info_by_id(id, command)
    if not id then return nil end
    local info = get_quickfix_info({ id = id, context = 1, nr = 0, title = 1 })
    if info and is_fuzzy_context(info.context, command) then
        info.id = id
        return info
    end
end

local function get_quickfix_info_by_nr(nr, command)
    local info = get_quickfix_info({ nr = nr, context = 1, id = 0, title = 1 })
    return info and is_fuzzy_context(info.context, command) and info or nil
end

local function get_quickfix_stack_size()
    local info = get_quickfix_info({ nr = "$" })
    return info and info.nr or 0
end

local function find_existing_fuzzy_quickfix(command)
    local max_nr = get_quickfix_stack_size()
    for nr = max_nr, 1, -1 do
        local info = get_quickfix_info_by_nr(nr, command)
        if info then return info end
    end
end

local function create_fuzzy_quickfix(command, title)
    local ok, err = pcall(vim.fn.setqflist, {}, " ", {
        nr = "$",
        title = title or command or "Fuzzy",
        context = { [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE, command = command },
        items = {},
    })
    if not ok then
        vim.notify(string.format("Fuzzy: failed to prepare quickfix list: %s", err), vim.log.levels.ERROR)
        return nil
    end
    local current = get_quickfix_info({ nr = 0 })
    return current and get_quickfix_info_by_nr(current.nr, command)
end

local function ensure_fuzzy_quickfix(command, title)
    command = command or "Fuzzy"
    local info = get_quickfix_info_by_id(quickfix_ids[command], command)
        or find_existing_fuzzy_quickfix(command)
        or create_fuzzy_quickfix(command, title)
    if info then
        quickfix_ids[command] = info.id
    end
    return info
end

local function activate_quickfix_nr(target_nr)
    if not target_nr then return end
    local current = get_quickfix_info({ nr = 0 })
    if not current then return end

    local delta = target_nr - (current.nr or 0)
    if delta == 0 then return end

    local cmd = delta > 0
        and string.format("silent! cnewer %d", delta)
        or string.format("silent! colder %d", -delta)
    pcall(vim.cmd, cmd)
end

local function collect_quickfix_lists(exclude_command)
    local max_nr = get_quickfix_stack_size()
    local lists = {}
    for nr = max_nr, 1, -1 do
        local info = get_quickfix_info({ nr = nr, context = 1, id = 0, title = 1, size = 1 })
        if info then
            local ctx_command = info.context and info.context.command
            if not (ctx_command and ctx_command == exclude_command) then
                local title = (info.title and info.title ~= "")
                    and info.title
                    or string.format("Quickfix %d", nr)
                lists[#lists + 1] = {
                    nr = info.nr or nr,
                    title = title,
                    size = info.size or 0,
                    command = ctx_command,
                }
            end
        end
    end
    return lists
end

local function select_quickfix_from_history()
    local lists = collect_quickfix_lists("FuzzyList")
    if #lists == 0 then
        vim.notify("FuzzyList: no quickfix history.", vim.log.levels.INFO)
        return
    end

    local output_lines = {}
    for idx, item in ipairs(lists) do
        local show_command = item.command and item.command ~= "" and item.command ~= item.title
        local prefix = show_command and string.format("[%s] ", item.command) or ""
        output_lines[#output_lines + 1] = string.format("%d: %s%s (%d items)", idx, prefix, item.title, item.size or 0)
    end

    local echo_chunks = vim.tbl_map(function(line) return { line .. "\n", "None" } end, output_lines)
    vim.api.nvim_echo(echo_chunks, false, {})

    local choice_idx = tonumber(vim.fn.input("Select Quickfix: "), 10)
    if choice_idx and choice_idx >= 1 and choice_idx <= #lists then
        activate_quickfix_nr(lists[choice_idx].nr)
        vim.cmd("copen")
    end
end

local function update_fuzzy_quickfix(items, opts)
    opts = opts or {}
    local command = opts.command or "Fuzzy"
    local info = ensure_fuzzy_quickfix(command, opts.title)
    if not info then return 0 end

    local context = {
        [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE,
        command = command,
    }

    local ok, err = pcall(vim.fn.setqflist, {}, "r", {
        id = info.id,
        items = items,
        title = opts.title,
        context = context,
    })
    if not ok then
        vim.notify(string.format("Fuzzy: failed to update quickfix list: %s", err), vim.log.levels.ERROR)
        return 0
    end

    local refreshed = get_quickfix_info_by_id(info.id, command) or info
    activate_quickfix_nr(refreshed.nr)
    return #items
end

local function parse_command_args(raw)
    if not raw or raw == "" then return {} end

    local args = {}
    local current = {}
    local quote = nil

    local function push_current()
        if #current > 0 then
            args[#args + 1] = table.concat(current)
            current = {}
        end
    end

    local escapes = { n = "\n", r = "\r", t = "\t" }

    local i = 1
    while i <= #raw do
        local ch = raw:sub(i, i)

        if quote == "'" then
            if ch == "'" then
                quote = nil
            else
                current[#current + 1] = ch
            end
        elseif quote == '"' then
            if ch == '"' then
                quote = nil
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char:match('["$`\\nrt]') then
                    current[#current + 1] = escapes[next_char] or next_char
                    i = i + 1
                else
                    current[#current + 1] = ch
                end
            else
                current[#current + 1] = ch
            end
        else
            if ch:match("%s") then
                push_current()
            elseif ch == "'" or ch == '"' then
                quote = ch
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char ~= "" then
                    current[#current + 1] = next_char
                    i = i + 1
                end
            else
                current[#current + 1] = ch
            end
        end
        i = i + 1
    end

    push_current()
    if quote then
        vim.notify(string.format("Fuzzy: unmatched %s quote, treating literally.", quote), vim.log.levels.WARN)
    end

    return args
end

local function normalize_args(arg_input)
    if type(arg_input) == "table" then
        local mapped = vim.tbl_map(tostring, arg_input)
        return vim.tbl_filter(function(v)
            return v ~= nil and tostring(v) ~= ""
        end, mapped)
    end
    return parse_command_args(arg_input)
end

local function system_lines(command, callback)
    local handle, err = vim.system(command, { text = true }, function(obj)
        local stdout_lines = vim.split(obj.stdout or "", "\n", { trimempty = true })
        local stderr_lines = vim.split(obj.stderr or "", "\n", { trimempty = true })
        vim.schedule(function()
            callback(stdout_lines, obj.code or 0, stderr_lines)
        end)
    end)
    if not handle then
        vim.schedule(function()
            vim.notify(string.format("Fuzzy: failed to start command: %s", err or "unknown"), vim.log.levels.ERROR)
            callback({ err or "failed to execute command" }, 1)
        end)
    end
end

local function open_quickfix_when_results(match_count, empty_message)
    if match_count == 0 then
        vim.notify(empty_message or "No matches found.", vim.log.levels.INFO)
    else
        vim.cmd("copen")
    end
end

local function parse_vimgrep_line(line)
    local filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    return filename and {
        filename = filename,
        lnum = tonumber(lnum, 10),
        col = tonumber(col, 10),
        text = text,
    }
end

local function set_quickfix_from_lines(lines)
    local items = {}
    for _, line in ipairs(lines) do
        local entry = parse_vimgrep_line(line)
        if entry then
            items[#items + 1] = entry
        end
    end
    return update_fuzzy_quickfix(items, {
        title = "FuzzyGrep",
        command = "FuzzyGrep",
    })
end

local HAS_RG = vim.fn.executable("rg") == 1
local function run_rg(raw_args, callback)
    if not HAS_RG then
        vim.schedule(function()
            callback({ "FuzzyGrep: 'rg' executable not found." }, 2)
        end)
        return
    end

    local args = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    vim.list_extend(args, normalize_args(raw_args))
    system_lines(args, callback)
end

local function run_fuzzy_grep(raw_args)
    run_rg(raw_args, function(lines, status, err_lines)
        if status > 1 then
            local message_lines = (#err_lines > 0) and err_lines or lines
            local message = table.concat(message_lines, "\n")
            vim.notify(message ~= "" and message or "FuzzyGrep: ripgrep failed.", vim.log.levels.ERROR)
            return
        end

        local count = set_quickfix_from_lines(lines)
        open_quickfix_when_results(count, "FuzzyGrep: no matches found.")
    end)
end

local function prompt_input(prompt, default)
    vim.fn.inputsave()
    local ok, result = pcall(vim.fn.input, prompt, default or "")
    vim.fn.inputrestore()
    return ok and vim.trim(result) or ""
end

-- FuzzyHelp: Search Vim help tags
local function get_help_tags(pattern)
    -- Get all help tags
    local tags = vim.fn.getcompletion(pattern or "", "help")
    return tags
end

local function set_quickfix_help_tags(tags, pattern)
    local items = {}
    for _, tag in ipairs(tags) do
        items[#items + 1] = {
            text = tag,
            user_data = { help_tag = tag },
        }
    end

    local title = pattern and pattern ~= ""
        and string.format("FuzzyHelp: %s", pattern)
        or "FuzzyHelp"

    return update_fuzzy_quickfix(items, {
        title = title,
        command = "FuzzyHelp",
    })
end

local function run_fuzzy_help(pattern)
    local tags = get_help_tags(pattern)

    if #tags == 0 then
        vim.notify("FuzzyHelp: no help tags found.", vim.log.levels.INFO)
        return
    end

    local count = set_quickfix_help_tags(tags, pattern)
    open_quickfix_when_results(count, "FuzzyHelp: no help tags matched.")
end

local HAS_FD = vim.fn.executable("fd") == 1

local function has_fd_custom_limit(args)
    for _, arg in ipairs(args) do
        if arg == "--max-results" or arg == "-n" or arg:match("^%-n%d+$") then
            return true
        end
    end
    return false
end

local function run_fd(raw_args, callback)
    if not HAS_FD then
        vim.schedule(function()
            local msg = "FuzzyFiles: 'fd' executable not found."
            callback({ msg }, 2, false, nil, { msg })
        end)
        return
    end

    local extra_args = normalize_args(raw_args)

    local include_vcs = vim.tbl_contains(extra_args, "--noignore")
    extra_args = vim.tbl_filter(function(arg) return arg ~= "--noignore" end, extra_args)

    local custom_limit = has_fd_custom_limit(extra_args)
    local match_limit = get_file_match_limit()
    local sentinel_limit = match_limit + 1

    local args = {
        "fd", "--hidden", "--follow", "--color", "never",
        "--exclude", ".git",
    }

    if include_vcs then
        args[#args + 1] = "--no-ignore-vcs"
    end

    if not custom_limit then
        vim.list_extend(args, { "--max-results", tostring(sentinel_limit) })
    end

    vim.list_extend(args, extra_args)

    system_lines(args, function(lines, status, err_lines)
        local truncated = status == 0 and not custom_limit and #lines == sentinel_limit
        if truncated then
            table.remove(lines)
        end
        callback(lines, status, truncated, match_limit, err_lines)
    end)
end

local function build_file_quickfix_items(files, match_limit)
    match_limit = match_limit or get_file_match_limit()
    local items = {}
    local first_file = nil

    for idx = 1, math.min(match_limit, #files) do
        local file = files[idx]
        if file ~= "" then
            first_file = first_file or file
            items[#items + 1] = {
                filename = file,
                lnum = 1,
                col = 1,
                text = file,
            }
        end
    end
    return items, first_file
end

local function set_quickfix_files(items)
    return update_fuzzy_quickfix(items, {
        title = "FuzzyFiles",
        command = "FuzzyFiles",
    })
end

local function is_real_listed_buffer(bufnr)
    if not bufnr or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local ok_type, buftype = pcall(vim.api.nvim_get_option_value, "buftype", { buf = bufnr })
    if not ok_type or buftype ~= "" then
        return false
    end

    local ok_listed, listed = pcall(vim.api.nvim_get_option_value, "buflisted", { buf = bufnr })
    return ok_listed and listed
end

local function set_quickfix_buffers()
    local buffers = {}
    for _, buf in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        if is_real_listed_buffer(buf.bufnr) then
            local name = buf.name ~= "" and buf.name or "[No Name]"
            local label = string.format("[%d] %s", buf.bufnr, name)
            buffers[#buffers + 1] = {
                filename = buf.name ~= "" and name or nil,
                bufnr = buf.name == "" and buf.bufnr or nil,
                lnum = math.max(buf.lnum or 1, 1),
                col = 1,
                text = label,
            }
        end
    end
    return update_fuzzy_quickfix(buffers, {
        title = "FuzzyBuffers",
        command = "FuzzyBuffers",
    })
end

local function refresh_fuzzy_buffers()
    if fuzzy_buffers_updating then return 0 end

    fuzzy_buffers_updating = true
    local ok, count = pcall(set_quickfix_buffers)
    fuzzy_buffers_updating = false

    if not ok then
        vim.notify(string.format("Fuzzy: failed to refresh buffers: %s", count or "unknown"), vim.log.levels.ERROR)
        return 0
    end
    return count or 0
end

local function disable_fuzzy_buffers_live_update()
    vim.api.nvim_clear_autocmds({ group = fuzzy_buffers_autocmd_group })
end

local function enable_fuzzy_buffers_live_update()
    disable_fuzzy_buffers_live_update()
    vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout" }, {
        group = fuzzy_buffers_autocmd_group,
        callback = function()
            vim.schedule(function()
                local current = get_quickfix_info({ nr = 0, context = 1, title = 1 })
                if current and is_fuzzy_context(current.context, "FuzzyBuffers") then
                    refresh_fuzzy_buffers()
                end
            end)
        end,
        desc = "Refresh FuzzyBuffers quickfix list on buffer changes",
    })
end

local M = {}

function M.setup(user_opts)
    if user_opts and type(user_opts) == "table" then
        config = vim.tbl_deep_extend("force", {}, config, user_opts)
    end

    vim.api.nvim_create_user_command("FuzzyGrep", function(opts)
        local args = opts.args
        if args == "" then
            args = prompt_input("FuzzyGrep: ", "")
            if args == "" then
                -- vim.notify("FuzzyGrep cancelled.", vim.log.levels.INFO)
                return
            end
        end
        run_fuzzy_grep(args)
    end, {
        nargs = "*",
        complete = "file",
        desc = "Run ripgrep and open quickfix list with matches",
    })

    vim.api.nvim_create_user_command("FuzzyFiles", function(opts)
        local raw_args = vim.trim(opts.args or "")
        if raw_args == "" then
            raw_args = prompt_input("FuzzyFiles: ", "")
            if raw_args == "" then
                -- vim.notify("FuzzyFiles cancelled.", vim.log.levels.INFO)
                return
            end
        end

        run_fd(raw_args, function(files, status, truncated, match_limit, err_lines)
            if status ~= 0 then
                local message_lines = (#err_lines > 0) and err_lines or files
                local message = table.concat(message_lines, "\n")
                vim.notify(message ~= "" and message or "FuzzyFiles: failed to list files.", vim.log.levels.ERROR)
                return
            end

            local items, first_file = build_file_quickfix_items(files, match_limit)
            local count = #items
            local prefer_direct = (config.open_single_result or opts.bang) and count == 1

            if prefer_direct and first_file then
                local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(first_file))
                if not ok then
                    vim.notify(string.format("FuzzyFiles: failed to open '%s': %s", first_file, err),
                        vim.log.levels.ERROR)
                else
                    return
                end
            end

            local qf_count = set_quickfix_files(items)
            if truncated and match_limit then
                vim.notify(string.format("FuzzyFiles: showing first %d matches.", match_limit), vim.log.levels.INFO)
            end
            open_quickfix_when_results(qf_count, "FuzzyFiles: no files matched.")
        end)
    end, {
        nargs = "*",
        desc = "Fuzzy find files using fd (--noignore to include gitignored files, add ! to open a single match)",
        bang = true,
    })

    vim.api.nvim_create_user_command("FuzzyBuffers", function(opts)
        if opts.bang then
            enable_fuzzy_buffers_live_update()
        else
            disable_fuzzy_buffers_live_update()
        end

        local count = refresh_fuzzy_buffers()
        if count == 0 then
            vim.notify("FuzzyBuffers: no listed buffers.", vim.log.levels.INFO)
            return
        end

        open_quickfix_when_results(count, "FuzzyBuffers: no listed buffers.")
    end, {
        desc = "Show listed buffers in quickfix list (! enables live updates)",
        bang = true,
    })

    vim.api.nvim_create_user_command("FuzzyList", function()
        select_quickfix_from_history()
    end, {
        desc = "Pick a quickfix list from history and open it",
    })

    vim.api.nvim_create_user_command("FuzzyHelp", function(opts)
        local pattern = vim.trim(opts.args or "")
        if pattern == "" then
            pattern = prompt_input("FuzzyHelp: ", "")
            if pattern == "" then
                -- Show all help tags if no pattern
                pattern = ""
            end
        end
        run_fuzzy_help(pattern)
    end, {
        nargs = "*",
        complete = "help",
        desc = "Fuzzy search Vim help tags and documentation",
    })
end

function M.grep(args)
    run_fuzzy_grep(args)
end

return M

-- LICENSE: MIT
-- by @anoopkcn
-- https://github.com/anoopkcn/dotfiles/blob/main/nvim/lua/fuzzy/init.lua
-- Description: Neovim fuzzy helpers for grep, files and buffers that feed the quickfix list.
-- Provides commands:
--   :FuzzyGrep [pattern] [rg options] - Runs ripgrep with the given pattern and populates the quickfix list with results.
--   :FuzzyFiles [fd arguments]        - Runs fd with the supplied arguments and populates the quickfix list with files.
--   :FuzzyBuffers                     - Lists all listed buffers in the quickfix list.
-- The quickfix list is reused across invocations of these commands.
-- The commands use ripgrep (rg), fd, and Neovim's built-in fuzzy matching.
-- Ensure ripgrep and fd are installed and available in your PATH for these commands to work.

local FILE_MATCH_LIMIT = 600
local FUZZY_CONTEXT_KEY = "fuzzy_owner"
local FUZZY_CONTEXT_VALUE = "lua/fuzzy"

local fuzzy_quickfix_id

local function get_quickfix_info_by_id(id)
    if not id then
        return nil
    end
    local ok, info = pcall(vim.fn.getqflist, {
        id = id,
        context = 1,
        nr = 0,
        title = 1,
    })
    if not ok or type(info) ~= "table" then
        return nil
    end
    local ctx = info.context
    if type(ctx) ~= "table" or ctx[FUZZY_CONTEXT_KEY] ~= FUZZY_CONTEXT_VALUE then
        return nil
    end
    info.id = id
    return info
end

local function get_quickfix_info_by_nr(nr)
    local ok, info = pcall(vim.fn.getqflist, {
        nr = nr,
        context = 1,
        id = 0,
        title = 1,
    })
    if not ok or type(info) ~= "table" then
        return nil
    end
    return info
end

local function get_quickfix_stack_size()
    local ok, info = pcall(vim.fn.getqflist, { nr = "$" })
    if not ok or type(info) ~= "table" then
        return 0
    end
    return info.nr or 0
end

local function find_existing_fuzzy_quickfix()
    local size = get_quickfix_stack_size()
    for nr = size, 1, -1 do
        local info = get_quickfix_info_by_nr(nr)
        local ctx = info and info.context
        if type(ctx) == "table" and ctx[FUZZY_CONTEXT_KEY] == FUZZY_CONTEXT_VALUE then
            return info
        end
    end
end

local function create_fuzzy_quickfix(title)
    local ok, err = pcall(vim.fn.setqflist, {}, " ", {
        nr = "$",
        title = title or "Fuzzy",
        context = { [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE },
        items = {},
    })
    if not ok then
        vim.notify(string.format("Fuzzy: failed to prepare quickfix list: %s", err), vim.log.levels.ERROR)
        return nil
    end
    local ok_info, current = pcall(vim.fn.getqflist, { nr = 0 })
    if not ok_info or type(current) ~= "table" then
        return nil
    end
    return get_quickfix_info_by_nr(current.nr)
end

local function ensure_fuzzy_quickfix(title)
    local info = get_quickfix_info_by_id(fuzzy_quickfix_id)
    if info then
        return info
    end
    info = find_existing_fuzzy_quickfix()
    if info then
        fuzzy_quickfix_id = info.id
        return info
    end
    info = create_fuzzy_quickfix(title)
    if info then
        fuzzy_quickfix_id = info.id
    end
    return info
end

local function activate_quickfix_nr(target_nr)
    if not target_nr then
        return
    end
    local ok, current = pcall(vim.fn.getqflist, { nr = 0 })
    if not ok or type(current) ~= "table" then
        return
    end
    local current_nr = current.nr or 0
    local delta = target_nr - current_nr
    if delta == 0 or delta ~= delta then
        return
    end
    local command
    if delta > 0 then
        command = string.format("silent! cnewer %d", delta)
    else
        command = string.format("silent! colder %d", -delta)
    end
    pcall(vim.cmd, command)
end

local function update_fuzzy_quickfix(items, opts)
    opts = opts or {}
    local info = ensure_fuzzy_quickfix(opts.title)
    if not info then
        return 0
    end

    local context = {
        [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE,
        command = opts.command or "Fuzzy",
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

    local refreshed = get_quickfix_info_by_id(info.id) or info
    activate_quickfix_nr(refreshed.nr)
    return #items
end

local function parse_command_args(raw)
    if not raw or raw == "" then
        return {}
    end

    local args = {}
    local current = {}
    local quote = nil

    local function push_current()
        if #current > 0 then
            table.insert(args, table.concat(current))
            current = {}
        end
    end

    local i = 1
    local len = #raw
    while i <= len do
        local ch = raw:sub(i, i)
        if quote == "'" then
            if ch == "'" then
                quote = nil
            else
                table.insert(current, ch)
            end
        elseif quote == '"' then
            if ch == '"' then
                quote = nil
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char ~= "" and next_char:match('["\\$`nrt]') then
                    local replacements = { n = "\n", r = "\r", t = "\t" }
                    table.insert(current, replacements[next_char] or next_char)
                    i = i + 1
                else
                    table.insert(current, ch)
                end
            else
                table.insert(current, ch)
            end
        else
            if ch:match("%s") then
                push_current()
            elseif ch == "'" or ch == '"' then
                quote = ch
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char ~= "" then
                    table.insert(current, next_char)
                    i = i + 1
                end
            else
                table.insert(current, ch)
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
        local args = {}
        for _, value in ipairs(arg_input) do
            if value ~= nil then
                local str = tostring(value)
                if str ~= "" then
                    table.insert(args, str)
                end
            end
        end
        return args
    end
    return parse_command_args(arg_input)
end

local function split_lines(output)
    if not output or output == "" then
        return {}
    end
    return vim.split(output, "\n", { trimempty = true })
end

local function system_lines(command, callback)
    local handle, err = vim.system(command, { text = true }, function(obj)
        local code = obj.code or 0
        local lines = split_lines(obj.stdout)
        vim.schedule(function()
            callback(lines, code)
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
        return
    end

    vim.cmd("copen")
end

local function parse_vimgrep_line(line)
    local filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if not filename then
        return nil
    end

    return {
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
            table.insert(items, entry)
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
        local message = "FuzzyGrep: 'rg' executable not found."
        vim.schedule(function()
            callback({ message }, 2)
        end)
        return
    end

    local args = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    vim.list_extend(args, normalize_args(raw_args))
    system_lines(args, callback)
end

local function run_fuzzy_grep(raw_args)
    run_rg(raw_args, function(lines, status)
        if status > 1 then
            local message = table.concat(lines, "\n")
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
    if not ok then
        return ""
    end
    return vim.trim(result)
end

local HAS_FD = vim.fn.executable("fd") == 1

local function has_fd_custom_limit(args)
    for _, arg in ipairs(args) do
        if arg == "--max-results" or arg == "-n" then
            return true
        end
        if arg:match("^%-n%d+$") then
            return true
        end
    end
    return false
end

local function run_fd(raw_args, callback)
    if not HAS_FD then
        local message = "FuzzyFiles: 'fd' executable not found."
        vim.schedule(function()
            callback({ message }, 2, false)
        end)
        return
    end

    local extra_args = normalize_args(raw_args)
    local custom_limit = has_fd_custom_limit(extra_args)
    local args = {
        "fd",
        "--type",
        "f",
        "--hidden",
        "--follow",
        "--color",
        "never",
        "--glob",
        "--exclude",
        ".git",
    }

    if not custom_limit then
        table.insert(args, "--max-results")
        table.insert(args, tostring(FILE_MATCH_LIMIT + 1))
    end

    vim.list_extend(args, extra_args)
    system_lines(args, function(lines, status)
        callback(lines, status, custom_limit)
    end)
end

local function set_quickfix_files(files, limit)
    local max_items = math.min(limit or #files, #files)
    local items = {}
    for idx = 1, max_items do
        local file = files[idx]
        if file ~= "" then
            table.insert(items, {
                filename = file,
                lnum = 1,
                col = 1,
                text = file,
            })
        end
    end
    return update_fuzzy_quickfix(items, {
        title = "FuzzyFiles",
        command = "FuzzyFiles",
    })
end

local function set_quickfix_buffers()
    local buffers = {}
    for _, buf in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        local name = buf.name ~= "" and buf.name or "[No Name]"
        local label = string.format("[%d] %s", buf.bufnr, name)
        table.insert(buffers, {
            filename = buf.name ~= "" and name or nil,
            bufnr = buf.name == "" and buf.bufnr or nil,
            lnum = math.max(buf.lnum or 1, 1),
            col = 1,
            text = label,
        })
    end
    return update_fuzzy_quickfix(buffers, {
        title = "FuzzyBuffers",
        command = "FuzzyBuffers",
    })
end

local M = {}

function M.setup()
    vim.api.nvim_create_user_command("FuzzyGrep", function(opts)
        if opts.args == "" then
            opts.args = prompt_input("FuzzyGrep: ", "")
            if opts.args == "" then
                vim.notify("FuzzyGrep cancelled.", vim.log.levels.INFO)
                return
            end
        end

        run_fuzzy_grep(opts.args)
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
                vim.notify("FuzzyFiles cancelled.", vim.log.levels.INFO)
                return
            end
        end

        run_fd(raw_args, function(files, status, custom_limit)
            if status > 1 then
                local message = table.concat(files, "\n")
                vim.notify(message ~= "" and message or "FuzzyFiles: failed to list files.", vim.log.levels.ERROR)
                return
            end

            local truncated = false
            local limit_sentinel = FILE_MATCH_LIMIT + 1
            if not custom_limit and #files == limit_sentinel then
                truncated = true
                table.remove(files)
            end

            local count = set_quickfix_files(files, FILE_MATCH_LIMIT)
            if truncated then
                vim.notify(string.format("FuzzyFiles: showing first %d matches.", FILE_MATCH_LIMIT), vim.log.levels.INFO)
            end
            open_quickfix_when_results(count, "FuzzyFiles: no files matched.")
        end)
    end, {
        nargs = "*",
        desc = "Fuzzy find tracked files using fd",
    })

    vim.api.nvim_create_user_command("FuzzyBuffers", function()
        local count = set_quickfix_buffers()
        if count == 0 then
            vim.notify("FuzzyBuffers: no listed buffers.", vim.log.levels.INFO)
            return
        end

        open_quickfix_when_results(count, "FuzzyBuffers: no listed buffers.")
    end, {
        desc = "Show listed buffers in quickfix list",
    })
end

function M.grep(args)
    run_fuzzy_grep(args)
end

return M

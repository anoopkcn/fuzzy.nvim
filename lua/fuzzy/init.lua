---@brief
--- LICENSE: MIT
--- by @anoopkcn
--- https://github.com/anoopkcn/dotfiles/blob/main/nvim/lua/fuzzy/init.lua
--- Description: Neovim fuzzy helpers for grep and files that feed the quickfix list.

local FILE_MATCH_LIMIT = 600

local qf_state = {
    id = nil,
    nr = nil,
}

local function locate_qf_nr(id)
    if not id then
        return nil
    end
    local total = vim.fn.getqflist({ nr = "$" }).nr or 0
    for nr = 1, total do
        local info = vim.fn.getqflist({ nr = nr, id = 0 })
        if info.id == id then
            return nr
        end
    end
    return nil
end

local function focus_fuzzy_qf()
    if not qf_state.nr then
        return
    end
    local current = vim.fn.getqflist({ nr = 0 }).nr or 0
    local target = qf_state.nr
    if not target or target == current then
        return
    end
    local diff = current - target
    local command
    if diff > 0 then
        command = string.format("colder %d", diff)
    else
        command = string.format("cnewer %d", math.abs(diff))
    end
    vim.cmd(command)
end

local function set_quickfix(title, items)
    local count = #items
    if qf_state.id then
        local nr = locate_qf_nr(qf_state.id)
        if nr then
            qf_state.nr = nr
            local ok, err = pcall(vim.fn.setqflist, {}, "r", {
                id = qf_state.id,
                title = title,
                items = items,
            })
            if ok then
                focus_fuzzy_qf()
                return count
            else
                vim.notify(
                    string.format("Fuzzy: failed to update quickfix list: %s", err),
                    vim.log.levels.ERROR
                )
                qf_state.id = nil
                qf_state.nr = nil
            end
        else
            qf_state.id = nil
            qf_state.nr = nil
        end
    end

    local ok, err = pcall(vim.fn.setqflist, {}, " ", {
        nr = "$",
        title = title,
        items = items,
    })
    if not ok then
        vim.notify(
            string.format("Fuzzy: failed to set quickfix list: %s", err),
            vim.log.levels.ERROR
        )
        return count
    end

    local info = vim.fn.getqflist({ nr = 0, id = 0 })
    qf_state.id = info.id
    qf_state.nr = info.nr
    return count
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
    return set_quickfix("FuzzyGrep", items)
end

local function run_rg(raw_args, callback)
    local args = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    vim.list_extend(args, vim.fn.split(raw_args, [[\s\+]], true))
    system_lines(args, callback)
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

local function list_project_files(callback)
    local args = {
        "rg",
        "--files",
        "--hidden",
        "--follow",
        "--max-count",
        tostring(FILE_MATCH_LIMIT + 1),
        "--color=never",
        "--glob",
        "!.git/*",
    }
    system_lines(args, callback)
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
    return set_quickfix("FuzzyFiles", items)
end

local function set_quickfix_buffers(buffers)
    return set_quickfix("FuzzyBuffers", buffers)
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

        run_rg(opts.args, function(lines, status)
            if status > 1 then
                local message = table.concat(lines, "\n")
                vim.notify(message ~= "" and message or "FuzzyGrep: ripgrep failed.", vim.log.levels.ERROR)
                return
            end

            local count = set_quickfix_from_lines(lines)
            open_quickfix_when_results(count, "FuzzyGrep: no matches found.")
        end)
    end, {
        nargs = "*",
        complete = "file",
        desc = "Run ripgrep and open quickfix list with matches",
    })

    vim.api.nvim_create_user_command("FuzzyFiles", function(opts)
        local query = vim.trim(opts.args or "")
        if query == "" then
            query = prompt_input("FuzzyFiles: ", "")
            if query == "" then
                vim.notify("FuzzyFiles cancelled.", vim.log.levels.INFO)
                return
            end
        end

        list_project_files(function(files, status)
            if status > 1 then
                local message = table.concat(files, "\n")
                vim.notify(message ~= "" and message or "FuzzyFiles: failed to list files.", vim.log.levels.ERROR)
                return
            end

            local limit = FILE_MATCH_LIMIT + 1
            local candidates = vim.fn.matchfuzzy(files, query, { limit = limit })
            local truncated = #candidates == limit
            if truncated then
                table.remove(candidates)
            end
            local count = set_quickfix_files(candidates, FILE_MATCH_LIMIT)
            if truncated then
                vim.notify(string.format("FuzzyFiles: showing first %d matches.", FILE_MATCH_LIMIT), vim.log.levels.INFO)
            end
            open_quickfix_when_results(count, "FuzzyFiles: nothing matched the pattern.")
        end)
    end, {
        nargs = "*",
        desc = "Fuzzy find tracked files using ripgrep --files",
    })

    vim.api.nvim_create_user_command("FuzzyBuffers", function()
        local buffers = {}
        for _, buf in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
            local name = buf.name ~= "" and buf.name or "[No Name]"
            table.insert(buffers, {
                filename = buf.name ~= "" and name or nil,
                bufnr = buf.name == "" and buf.bufnr or nil,
                lnum = math.max(buf.lnum or 1, 1),
                col = 1,
                text = name,
            })
        end

        local count = set_quickfix_buffers(buffers)
        open_quickfix_when_results(count, "FuzzyBuffers: no listed buffers.")
    end, {
        desc = "Show listed buffers in quickfix list",
    })
end

return M

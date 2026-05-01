local system = require("fuzzy.system")

local M = {}

M.prefix = "FuzzyGit"

local function join_lines(lines)
    if type(lines) == "string" then return lines end
    if type(lines) ~= "table" then return "" end
    return table.concat(lines, "\n")
end

function M.executable()
    return vim.fn.executable("git") == 1
end

function M.run(args, opts, callback)
    if type(opts) == "function" then
        callback = opts
        opts = {}
    end
    opts = opts or {}

    if not M.executable() then
        local result = { code = 1, stdout = "", stderr = "git executable not found." }
        vim.schedule(function()
            if callback then callback(result) end
        end)
        return nil
    end

    local cmd = { "git" }
    vim.list_extend(cmd, args or {})

    return system.run(cmd, function(stdout, code, stderr)
        if callback then
            callback({
                code = code or 0,
                stdout = join_lines(stdout),
                stderr = join_lines(stderr),
            })
        end
    end, opts)
end

function M.inside_work_tree(callback)
    M.run({ "rev-parse", "--is-inside-work-tree" }, {}, function(result)
        callback(result.code == 0 and vim.trim(result.stdout) == "true", result)
    end)
end

function M.toplevel(callback)
    M.run({ "rev-parse", "--show-toplevel" }, {}, function(result)
        if result.code ~= 0 then
            callback(nil, result)
            return
        end
        callback(vim.trim(result.stdout), result)
    end)
end

function M.git_dir(callback)
    M.run({ "rev-parse", "--git-dir" }, {}, function(result)
        if result.code ~= 0 then
            callback(nil, result)
            return
        end
        callback(vim.trim(result.stdout), result)
    end)
end

function M.ensure_repo(callback)
    if not M.executable() then
        vim.notify(M.prefix .. ": git executable not found.", vim.log.levels.ERROR)
        if callback then callback(false) end
        return
    end

    M.inside_work_tree(function(ok)
        if not ok then
            vim.notify(M.prefix .. ": not inside a Git repository.", vim.log.levels.ERROR)
            if callback then callback(false) end
            return
        end
        if callback then callback(true) end
    end)
end

function M.notify_error(prefix, message_or_result)
    prefix = prefix or M.prefix
    local message
    if type(message_or_result) == "table" then
        message = message_or_result.stderr
        if not message or message == "" then message = message_or_result.stdout end
        if not message or message == "" then
            message = "git command failed with exit code " .. tostring(message_or_result.code or 1)
        end
    else
        message = tostring(message_or_result or "git command failed")
    end
    vim.notify(prefix .. ": " .. vim.trim(message), vim.log.levels.ERROR)
end

return M

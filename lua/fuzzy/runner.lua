local parse = require("fuzzy.parse")
local system = require("fuzzy.system")
local config = require("fuzzy.config")

local M = {}

local HAS_RG = vim.fn.executable("rg") == 1
local HAS_FD = vim.fn.executable("fd") == 1

--- Run ripgrep or grep fallback
---@param raw_args string|string[] Search arguments
---@param callback fun(lines: string[], code: integer, stderr: string[])
---@param cwd? string Working directory
function M.rg(raw_args, callback, cwd)
    local args = parse.normalize(raw_args)
    local cmd = HAS_RG
        and vim.list_extend({ "rg", "--vimgrep", "--smart-case", "--color=never" }, args)
        or vim.list_extend({ "grep", "-RnH", "--color=never", "--exclude-dir=.git" }, args)
    system.run(cmd, callback, { cwd = cwd })
end

--- Run fd or vim.fs.find fallback
---@param raw_args string|string[] Search arguments
---@param callback fun(files: string[], code: integer, truncated: boolean, limit: integer, stderr: string[])
---@param cwd? string Working directory
function M.fd(raw_args, callback, cwd)
    local args = parse.normalize(raw_args)
    local limit = config.get().file_match_limit or 600

    -- Check for --noignore flag
    local include_vcs = vim.tbl_contains(args, "--noignore")
    args = vim.iter(args):filter(function(a) return a ~= "--noignore" end):totable()

    -- Check for custom limit
    local has_limit = vim.iter(args):any(function(a)
        return a == "--max-results" or a == "-n" or a:match("^%-n%d+$")
    end)

    if HAS_FD then
        local cmd = { "fd", "--hidden", "--color=never", "--exclude", ".git" }
        if include_vcs then cmd[#cmd + 1] = "--no-ignore-vcs" end
        if not has_limit then vim.list_extend(cmd, { "--max-results", tostring(limit + 1) }) end
        -- Add --full-path if any arg contains /
        if vim.iter(args):any(function(a) return a:find("/", 1, true) end) then
            cmd[#cmd + 1] = "--full-path"
        end
        vim.list_extend(cmd, args)

        system.run(cmd, function(lines, code, err)
            local truncated = code == 0 and not has_limit and #lines > limit
            if truncated then table.remove(lines) end
            callback(lines, code, truncated, limit, err)
        end, { cwd = cwd })
    else
        -- Fallback to vim.fs.find
        local pattern = vim.iter(args):find(function(a) return a:sub(1, 1) ~= "-" end)
        local predicate = pattern and function(name) return name:find(pattern, 1, true) end or function() return true end

        local ok, results = pcall(vim.fs.find, predicate, {
            path = cwd or ".",
            type = "file",
            limit = limit + 1,
            skip = function(name) return not include_vcs and name == ".git" end,
        })

        if not ok then
            callback({}, 1, false, limit, { results or "find failed" })
            return
        end

        local truncated = #results > limit
        if truncated then results[limit + 1] = nil end
        callback(results, 0, truncated, limit, {})
    end
end

return M

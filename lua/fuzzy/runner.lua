local parse = require("fuzzy.parse")
local system = require("fuzzy.system")
local config = require("fuzzy.config")

local M = {}

local HAS_RG = vim.fn.executable("rg") == 1
local HAS_FD = vim.fn.executable("fd") == 1

--- Active handles per command for cancellation
---@type table<string, vim.SystemObj>
local active_handles = {}

--- Cancel any running process for a given command name
---@param cmd_name string
local function cancel_active(cmd_name)
    local handle = active_handles[cmd_name]
    if handle then
        pcall(function() handle:kill() end)
        active_handles[cmd_name] = nil
    end
end

--- Track a handle and auto-clear on completion
---@param cmd_name string
---@param handle vim.SystemObj|nil
local function track(cmd_name, handle)
    active_handles[cmd_name] = handle
end

--- Clear tracking for a command
---@param cmd_name string
local function untrack(cmd_name)
    active_handles[cmd_name] = nil
end

--- Run ripgrep or grep fallback (batch mode)
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

--- Run ripgrep with per-line streaming
---@param raw_args string|string[] Search arguments
---@param opts { cwd?: string, on_line: fun(line: string), on_exit: fun(code: integer, stderr: string[]) }
---@return vim.SystemObj|nil handle
function M.rg_stream(raw_args, opts)
    cancel_active("rg")
    local args = parse.normalize(raw_args)
    local cmd = HAS_RG
        and vim.list_extend({ "rg", "--vimgrep", "--smart-case", "--color=never" }, args)
        or vim.list_extend({ "grep", "-RnH", "--color=never", "--exclude-dir=.git" }, args)
    local handle = system.run_stream(cmd, {
        cwd = opts.cwd,
        on_line = opts.on_line,
        on_exit = function(code, stderr)
            untrack("rg")
            opts.on_exit(code, stderr)
        end,
    })
    track("rg", handle)
    return handle
end

--- Run fd or vim.fs.find fallback (batch mode)
---@param raw_args string|string[] Search arguments
---@param callback fun(files: string[], code: integer, truncated: boolean, limit: integer, stderr: string[])
---@param cwd? string Working directory
function M.fd(raw_args, callback, cwd)
    local args = parse.normalize(raw_args)
    local limit = config.get().file_match_limit or 10000

    -- Check for custom limit
    local has_limit = vim.iter(args):any(function(a)
        return a == "--max-results" or a == "-n" or a:match("^%-n%d+$")
    end)

    if HAS_FD then
        local cmd = { "fd", "--hidden", "--color=never", "--exclude", ".git" }
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
            skip = function(name) return name == ".git" end,
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

--- Run fd with per-line streaming
---@param raw_args string|string[] Search arguments
---@param opts { cwd?: string, on_line: fun(line: string), on_exit: fun(code: integer, stderr: string[]) }
---@return vim.SystemObj|nil handle Returns nil if using vim.fs.find fallback
function M.fd_stream(raw_args, opts)
    cancel_active("fd")
    local args = parse.normalize(raw_args)
    local limit = config.get().file_match_limit or 10000

    local has_limit = vim.iter(args):any(function(a)
        return a == "--max-results" or a == "-n" or a:match("^%-n%d+$")
    end)

    if HAS_FD then
        local cmd = { "fd", "--hidden", "--color=never", "--exclude", ".git" }
        if not has_limit then vim.list_extend(cmd, { "--max-results", tostring(limit) }) end
        if vim.iter(args):any(function(a) return a:find("/", 1, true) end) then
            cmd[#cmd + 1] = "--full-path"
        end
        vim.list_extend(cmd, args)

        local handle = system.run_stream(cmd, {
            cwd = opts.cwd,
            on_line = opts.on_line,
            on_exit = function(code, stderr)
                untrack("fd")
                opts.on_exit(code, stderr)
            end,
        })
        track("fd", handle)
        return handle
    else
        -- Fallback: vim.fs.find is synchronous, call on_line per result then on_exit
        local pattern = vim.iter(args):find(function(a) return a:sub(1, 1) ~= "-" end)
        local predicate = pattern and function(name) return name:find(pattern, 1, true) end or function() return true end

        local ok, results = pcall(vim.fs.find, predicate, {
            path = opts.cwd or ".",
            type = "file",
            limit = limit,
            skip = function(name) return name == ".git" end,
        })

        if not ok then
            vim.schedule(function() opts.on_exit(1, { results or "find failed" }) end)
            return nil
        end

        for _, file in ipairs(results) do
            opts.on_line(file)
        end
        vim.schedule(function() opts.on_exit(0, {}) end)
        return nil
    end
end

return M

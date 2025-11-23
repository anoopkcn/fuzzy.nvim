local parse = require("fuzzy.parse")
local system = require("fuzzy.system")
local config = require("fuzzy.config")

local HAS_RG = vim.fn.executable("rg") == 1
local HAS_FD = vim.fn.executable("fd") == 1

local M = {}

local function has_fd_custom_limit(args)
    for _, arg in ipairs(args) do
        if arg == "--max-results" or arg == "-n" or arg:match("^%-n%d+$") then
            return true
        end
    end
    return false
end

function M.run_rg(raw_args, callback)
    if not HAS_RG then
        vim.schedule(function()
            callback({ "FuzzyGrep: 'rg' executable not found." }, 2)
        end)
        return
    end

    local args = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    vim.list_extend(args, parse.normalize_args(raw_args))
    system.system_lines(args, callback)
end

function M.run_fd(raw_args, callback)
    if not HAS_FD then
        vim.schedule(function()
            local msg = "FuzzyFiles: 'fd' executable not found."
            callback({ msg }, 2, false, nil, { msg })
        end)
        return
    end

    local extra_args = parse.normalize_args(raw_args)

    local include_vcs = vim.tbl_contains(extra_args, "--noignore")
    extra_args = vim.tbl_filter(function(arg) return arg ~= "--noignore" end, extra_args)

    local custom_limit = has_fd_custom_limit(extra_args)
    local match_limit = config.get_file_match_limit()
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

    system.system_lines(args, function(lines, status, err_lines)
        local truncated = status == 0 and not custom_limit and #lines == sentinel_limit
        if truncated then
            table.remove(lines)
        end
        callback(lines, status, truncated, match_limit, err_lines)
    end)
end

M.has_fd_custom_limit = has_fd_custom_limit

return M

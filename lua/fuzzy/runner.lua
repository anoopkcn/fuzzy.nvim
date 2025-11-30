local parse = require("fuzzy.parse")
local system = require("fuzzy.system")
local config = require("fuzzy.config")

local HAS_RG = vim.fn.executable("rg") == 1
local HAS_FD = vim.fn.executable("fd") == 1

local function is_directory(path)
    if not path or path == "" then
        return false
    end
    local stat = vim.uv.fs_stat(path)
    return stat and stat.type == "directory"
end

local M = {}

local function has_fd_custom_limit(args)
    return vim.iter(args):any(function(arg)
        return arg == "--max-results" or arg == "-n" or arg:match("^%-n%d+$")
    end)
end

-- ripgrep runner ----------------------------
local function run_ripgrep(raw_args, callback)
    local args = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    vim.list_extend(args, parse.normalize_args(raw_args))
    system.system_lines(args, callback)
end

local function run_grep_fallback(raw_args, callback)
    local args = parse.normalize_args(raw_args)
    local cmd = {
        "grep", "-R", "-nH", "--color=never",
        "--binary-files=without-match",
        "--exclude-dir=.git",
        "--exclude-dir=node_modules",
    }
    vim.list_extend(cmd, args)
    system.system_lines(cmd, callback)
end

function M.run_rg(raw_args, callback)
    if HAS_RG then
        return run_ripgrep(raw_args, callback)
    end
    return run_grep_fallback(raw_args, callback)
end

-- fd / find runner ---------------------------------------------------------
local function run_fd_binary(extra_args, include_vcs, custom_limit, match_limit, callback)
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

    -- If pattern contains a path separator, search full paths instead of just filenames
    local first_arg = extra_args[1]
    if first_arg and first_arg:find("/", 1, true) and first_arg:sub(1, 1) ~= "-" then
        args[#args + 1] = "--full-path"
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

local function run_find_fallback(extra_args, include_vcs, custom_limit, match_limit, callback)
    local search_root = "."
    if extra_args[1] and extra_args[1]:sub(1, 1) ~= "-" and is_directory(extra_args[1]) then
        search_root = table.remove(extra_args, 1)
    end

    local name_pattern = extra_args[1]
    local predicate
    if name_pattern and name_pattern ~= "" then
        -- If pattern contains a path separator, match against full path
        local match_full_path = name_pattern:find("/", 1, true) ~= nil
        predicate = function(name, path)
            local target = match_full_path and path or name
            return target:find(name_pattern, 1, true) ~= nil
        end
    else
        predicate = function()
            return true
        end
    end

    local limit = (not custom_limit and match_limit) and (match_limit + 1) or nil

    local ok, results = pcall(vim.fs.find, predicate, {
        path = search_root,
        type = "file",
        limit = limit,
        skip = function(name)
            return not include_vcs and name == ".git"
        end,
    })

    if not ok then
        callback({ results or "find failed" }, 1, false, match_limit, {})
        return
    end

    local truncated = false
    if limit and #results > match_limit then
        truncated = true
        results[match_limit + 1] = nil
    end

    callback(results, 0, truncated, match_limit, {})
end

function M.run_fd(raw_args, callback)
    local extra_args = parse.normalize_args(raw_args)

    local include_vcs = vim.tbl_contains(extra_args, "--noignore")
    extra_args = vim.iter(extra_args):filter(function(arg)
        return arg ~= "--noignore"
    end):totable()

    local custom_limit = has_fd_custom_limit(extra_args)
    local match_limit = config.get_file_match_limit()

    if HAS_FD then
        return run_fd_binary(extra_args, include_vcs, custom_limit, match_limit, callback)
    end
    return run_find_fallback(extra_args, include_vcs, custom_limit, match_limit, callback)
end

return M

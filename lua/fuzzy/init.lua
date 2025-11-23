-- LICENSE: MIT
-- by @anoopkcn
-- Description: Neovim fuzzy helpers for grep, files, and buffers that feed the quickfix list.
-- Provides commands:
--   :FuzzyGrep [pattern] [rg options] - Runs ripgrep with the given pattern and populates the quickfix list with results.
--   :FuzzyFiles[!] [fd arguments]     - Runs fd with the supplied arguments (use --noignore to include gitignored files).
--                                       Add ! to open a single match directly.
--   :FuzzyBuffers[!]                  - Lists all listed buffers in the quickfix list (! enables live updates).
--   :FuzzyList                        - Pick a quickfix list from history (excluding the selector itself) and open it.

local config = require("fuzzy.config")
local input = require("fuzzy.input")
local grep = require("fuzzy.commands.grep")
local files = require("fuzzy.commands.files")
local buffers = require("fuzzy.commands.buffers")
local list = require("fuzzy.commands.list")

local M = {}

local function create_alias(name, fn, opts)
    local alias_opts = vim.tbl_extend("force", {}, opts or {})
    if alias_opts.desc then
        alias_opts.desc = alias_opts.desc .. " (alias)"
    end
    vim.api.nvim_create_user_command(name, fn, alias_opts)
end

function M.setup(user_opts)
    config.setup(user_opts)

    local function run_fuzzy_grep(opts)
        local args = opts.args
        if args == "" then
            args = input.prompt_input("FG: ", "")
            if args == "" then
                return
            end
        end
        grep.run(args, opts.bang)
    end

    local function run_fuzzy_files(opts)
        local raw_args = vim.trim(opts.args or "")
        if raw_args == "" then
            raw_args = input.prompt_input("FF: ", "")
            if raw_args == "" then
                return
            end
        end

        files.run(raw_args, opts.bang)
    end

    local function run_fuzzy_buffers(opts)
        buffers.run(opts.bang)
    end

    local function run_fuzzy_list()
        list.run()
    end

    local grep_opts = {
        nargs = "*",
        complete = "file",
        desc = "Run ripgrep and open quickfix list with matches",
        bang = true,
    }
    vim.api.nvim_create_user_command("FuzzyGrep", run_fuzzy_grep, grep_opts)
    create_alias("FG", run_fuzzy_grep, grep_opts)

    local files_opts = {
        nargs = "*",
        desc = "Fuzzy find files using fd (--noignore to include gitignored files, add ! to open a single match)",
        bang = true,
        complete = "file",
    }
    vim.api.nvim_create_user_command("FuzzyFiles", run_fuzzy_files, files_opts)
    create_alias("FF", run_fuzzy_files, files_opts)

    local buffers_opts = {
        desc = "Show listed buffers in quickfix list (! enables live updates)",
        bang = true,
    }
    vim.api.nvim_create_user_command("FuzzyBuffers", run_fuzzy_buffers, buffers_opts)
    create_alias("FB", run_fuzzy_buffers, buffers_opts)

    local list_opts = {
        desc = "Pick a quickfix list from history and open it",
    }
    vim.api.nvim_create_user_command("FuzzyList", run_fuzzy_list, list_opts)
    create_alias("FL", run_fuzzy_list, list_opts)
end

function M.grep(args, dedupe_lines)
    grep.run(args, dedupe_lines)
end

return M

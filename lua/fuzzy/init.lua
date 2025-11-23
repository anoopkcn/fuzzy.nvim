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

function M.setup(user_opts)
    config.setup(user_opts)

    vim.api.nvim_create_user_command("FuzzyGrep", function(opts)
        local args = opts.args
        if args == "" then
            args = input.prompt_input("FuzzyGrep: ", "")
            if args == "" then
                return
            end
        end
        grep.run(args, opts.bang)
    end, {
        nargs = "*",
        complete = "file",
        desc = "Run ripgrep and open quickfix list with matches",
        bang = true,
    })

    vim.api.nvim_create_user_command("FuzzyFiles", function(opts)
        local raw_args = vim.trim(opts.args or "")
        if raw_args == "" then
            raw_args = input.prompt_input("FuzzyFiles: ", "")
            if raw_args == "" then
                return
            end
        end

        files.run(raw_args, opts.bang)
    end, {
        nargs = "*",
        desc = "Fuzzy find files using fd (--noignore to include gitignored files, add ! to open a single match)",
        bang = true,
    })

    vim.api.nvim_create_user_command("FuzzyBuffers", function(opts)
        buffers.run(opts.bang)
    end, {
        desc = "Show listed buffers in quickfix list (! enables live updates)",
        bang = true,
    })

    vim.api.nvim_create_user_command("FuzzyList", function()
        list.run()
    end, {
        desc = "Pick a quickfix list from history and open it",
    })
end

function M.grep(args, dedupe_lines)
    grep.run(args, dedupe_lines)
end

return M

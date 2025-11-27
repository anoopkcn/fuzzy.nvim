# fuzzy.nvim

A fast and lightweight Neovim plugin for fuzzy finding files, grepping code, and managing buffers etc,. All using the quickfix workflow.

## Features

- **Fast grep search** using ripgrep with smart case matching
- **File finding** using fd with gitignore support
- **Buffer list management** with optional live updates
- **Quickfix history navigation** for easy access to previous searches
- **Single-file direct opening** for instant file access
- **Full control** over search arguments via ripgrep/fd options with built-in fallbacks

Unlike heavier fuzzy finder plugins, fuzzy.nvim leverages external tools (ripgrep and fd) and native Vim functionality for maximum performance.

## Requirements

- Neovim 0.12+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (rg) - for `:FuzzyGrep` (fallback: `grep -R`)
- [fd](https://github.com/sharkdp/fd) - for `:FuzzyFiles` (fallback: `find`)

## Installation

### Using neovim native [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack)
```lua
vim.pack.add({ src = "https://github.com/anoopkcn/fuzzy.nvim" })
require('fuzzy').setup()
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'anoopkcn/fuzzy.nvim',
  config = function()
    require('fuzzy').setup()
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'anoopkcn/fuzzy.nvim',
  config = function()
    require('fuzzy').setup()
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'anoopkcn/fuzzy.nvim'
```

Then in your `init.lua`:
```lua
require('fuzzy').setup()
```

## Configuration

```lua
require('fuzzy').setup({
  open_single_result = false,  -- Open single result directly (default: false)
  file_match_limit = 600,      -- Max files to show in FuzzyFiles (default: 600)
})
```

### Configuration Options

- **`open_single_result`** (boolean, default: `false`)
  When enabled, `:FuzzyFiles` will automatically open a single match instead of showing the quickfix list. Use `:FuzzyFiles!` to override on a per-command basis.

- **`file_match_limit`** (number, default: `600`)
  Maximum number of file results to display in the quickfix list. This prevents performance issues when thousands or millions of files match.

## Commands

### `:FuzzyGrep[!] [pattern] [rg options]`

Search for patterns in files using ripgrep (falls back to `grep -R` when rg is unavailable).

Aliases: `:Grep`

Default: Collapses multiple matches on the same line into a single quickfix entry (text stays unchanged; a notification tells you how many lines were deduped). Add `!` to keep every match (no deduping).

**Examples:**
```vim
:FuzzyGrep TODO
:FuzzyGrep! TODO    " keep every match on duplicate lines
:FuzzyGrep function.*init
:FuzzyGrep -t lua require
:FuzzyGrep -i error --type-add 'config:*.{yml,yaml}' -t config
:FuzzyGrep "TODO|FIXME" -g '*.js'
```

### `:FuzzyFiles[!] [fd arguments]`

Find files using fd (falls back to `find` when fd is unavailable).

Aliases: `:Files`

**Examples:**
```vim
:FuzzyFiles
:FuzzyFiles! init.lua
:FuzzyFiles .lua$ -e .test.lua
:FuzzyFiles --noignore config
:FuzzyFiles -t f -e go
:FuzzyFiles . --max-depth 2
```

The `!` modifier makes FuzzyFiles open a single result directly if there is only one match, instead of showing the quickfix list.

**Special argument:**
- `--noignore` - Include files ignored by .gitignore

### `:FuzzyBuffers[!]`

List all open buffers in the quickfix list. When executing the command pressing tab will autocomplete the buffer names.

Aliases: `:Buffers`

**Examples:**
```vim
:FuzzyBuffers    " Show the buffer list in quickfix
:FuzzyBuffers!   " Focus on buffer if there is only one target otherise opnen quickfix
```

### `:FuzzyList`

Browse and select from quickfix list history.

Aliases: `:List`

**Example:**
```vim
:FuzzyList
Select Quickfix: 2
```

Shows all quickfix lists in the history stack and allows you to restore a previous list.

Uses `vim.ui.select` if configured (e.g. with dressing.nvim); falls back to a simple prompt otherwise.

## Quickfix Navigation

All fuzzy commands populate the quickfix list. Use standard quickfix navigation:

```vim
:cnext      " Next item
:cprev      " Previous item
:copen      " Open quickfix window
:cclose     " Close quickfix window
<CR>        " Jump to item under cursor (in quickfix window)
```

## Usage Examples

### Basic Keybindings

```lua
local fuzzy = require('fuzzy')
fuzzy.setup()

vim.keymap.set('n', '<leader>/',  ':FuzzyGrep ', { desc = 'Fuzzy grep' })
vim.keymap.set('n', '<leader>ff', ':FuzzyFiles! ', { desc = 'Fuzzy find files' })
vim.keymap.set('n', '<leader>fb', ':FuzzyBuffers! ', { desc = 'List buffers' })
vim.keymap.set('n', '<leader>fl', '<CMD>FuzzyList<CR>', { desc = 'Quickfix history' })
```

### Advanced: Grep Word Under Cursor

```lua
local fuzzy = require('fuzzy')

local function grep_word(literal)
  local word = vim.fn.expand(literal and '<cWORD>' or '<cword>')
  if word ~= '' then
    local args = literal and { '-F', word } or { word }
    fuzzy.grep(args)
  end
end

vim.keymap.set('n', '<leader>fw', grep_word, { desc = 'Grep word under cursor' })
vim.keymap.set('n', '<leader>fW', function() grep_word(true) end, { desc = 'Grep WORD under cursor (literal)' })
```

### Search Help Documentation

```lua
local function grep_help()
  local pattern = vim.fn.input('Search help docs: ')
  if vim.trim(pattern) ~= '' then
    local help_dirs = vim.api.nvim_get_runtime_file('doc/', true)
    local args = { pattern, '--type-add', 'help:*.{txt,md}', '--type', 'help' }
    vim.list_extend(args, help_dirs)
    require('fuzzy').grep(args)
  end
end

vim.keymap.set('n', '<leader>fh', grep_help, { desc = 'Search help docs' })
```

### An example config/usage of the plugin:
```lua 
local ok, fuzzy = pcall(require, "fuzzy")
if ok then
    fuzzy.setup()
    local function _fuzzy_grep(term, literal)
        term = vim.trim(term or "")
        if term == "" then
            return
        end
        local args = { term }
        if literal then
            table.insert(args, 1, "-F")
        end
        fuzzy.grep(args)
    end

    vim.keymap.set("n", "<leader>/", ":Grep ",
        { silent = false, desc = "Fuzzy grep" })

    vim.keymap.set("n", "<leader>?", ":Files! --type f ",
        { silent = false, desc = "Fuzzy grep files" })

    vim.keymap.set("n", "<leader>ff", ":Files ",
        { silent = false, desc = "Fuzzy grep files" })

    vim.keymap.set("n", "<leader>fb", ":Buffers! ",
        { silent = false, desc = "Fuzzy buffer list" })

    vim.keymap.set("n", "<leader>fw", function()
            _fuzzy_grep(vim.fn.expand("<cword>"), false)
        end,
        { silent = false, desc = "Fuzzy grep current word" })

    vim.keymap.set("n", "<leader>fW", function()
            _fuzzy_grep(vim.fn.expand("<cWORD>"), true)
        end,
        { silent = false, desc = "Fuzzy grep current WORD" })

    vim.keymap.set("n", "<leader>fl", "<CMD>FuzzyList<CR>",
        { silent = false, desc = "Fuzzy list" })
end
```
## API

### `fuzzy.setup(opts)`

Initialize the fuzzy plugin with optional configuration.

**Parameters:**
- `opts` (table|nil) - Configuration options

### `fuzzy.grep(args)`

Programmatically run a grep search.

**Parameters:**
- `args` (table|string) - Ripgrep arguments (pattern and options)
- `dedupe_lines` (boolean|nil) - When true, collapse multiple matches on the same line into one entry (same as `:FuzzyGrep`); when false/nil, keep every match (same as `:FuzzyGrep!`)

**Example:**
```lua
local fuzzy = require('fuzzy')

-- Grep for word under cursor
local word = vim.fn.expand('<cword>')
fuzzy.grep({ word })

-- Grep and collapse duplicate line matches
fuzzy.grep({ 'TODO' }, true)

-- Grep with options
fuzzy.grep({ 'TODO', '-t', 'lua' })

-- Literal search
fuzzy.grep({ '-F', 'function(args)' })
```

## License

MIT

## Author

[@anoopkcn](https://github.com/anoopkcn)

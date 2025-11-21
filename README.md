# fuzzy.nvim

A fast and lightweight Neovim plugin for fuzzy finding files, grepping code, and managing buffers using the quickfix list.

## Features

- **Fast grep search** using ripgrep with smart case matching
- **File finding** using fd with gitignore support
- **Buffer list management** with optional live updates
- **Quickfix history navigation** for easy access to previous searches
- **Single-file direct opening** for instant file access
- **Full control** over search arguments via ripgrep and fd options
- **Zero dependencies** - uses only Neovim built-ins and external CLI tools

Unlike heavier fuzzy finder plugins, fuzzy.nvim leverages external tools (ripgrep and fd) and native Vim functionality for maximum performance.

## Requirements

- Neovim 0.12+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (rg) - for `:FuzzyGrep`
- [fd](https://github.com/sharkdp/fd) - for `:FuzzyFiles`

### Installation of External Tools

**macOS:**
```bash
brew install ripgrep fd
```

**Ubuntu/Debian:**
```bash
apt install ripgrep fd-find
```

**Arch Linux:**
```bash
pacman -S ripgrep fd
```

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
  Maximum number of file results to display in the quickfix list. This prevents performance issues when thousands of files match.

## Commands

### `:FuzzyGrep [pattern] [rg options]`

Search for patterns in files using ripgrep.

**Examples:**
```vim
:FuzzyGrep TODO
:FuzzyGrep function.*init
:FuzzyGrep -t lua require
:FuzzyGrep -i error --type-add 'config:*.{yml,yaml}' -t config
:FuzzyGrep "TODO|FIXME" -g '*.js'
```

**Common ripgrep options:**
- `-t TYPE` - Search only files of TYPE (lua, py, js, etc.)
- `-T TYPE` - Exclude files of TYPE
- `-g GLOB` - Include/exclude files matching glob pattern
- `-i` - Case insensitive search
- `-w` - Match whole words only
- `-F` - Treat pattern as literal string (not regex)
- `--hidden` - Search hidden files
- `--no-ignore` - Don't respect .gitignore

### `:FuzzyFiles[!] [fd arguments]`

Find files using fd.

**Examples:**
```vim
:FuzzyFiles
:FuzzyFiles! init.lua
:FuzzyFiles .lua$ -e .test.lua
:FuzzyFiles --noignore config
:FuzzyFiles -t f -e go
:FuzzyFiles . --max-depth 2
```

The `!` modifier makes FuzzyFiles open a single result directly.

**Special argument:**
- `--noignore` - Include files ignored by .gitignore

**Common fd options:**
- `-e EXT` - Filter by extension (e.g., `-e lua -e vim`)
- `-t TYPE` - Filter by type: f=file, d=directory, l=symlink
- `-E PATTERN` - Exclude pattern
- `--max-depth N` - Limit search depth

### `:FuzzyBuffers[!]`

List all open buffers in the quickfix list.

**Examples:**
```vim
:FuzzyBuffers    " One-time buffer list
:FuzzyBuffers!   " Live-updating buffer list
```

Without `!`: Shows current listed buffers as a snapshot
With `!`: Enables live updates - quickfix list refreshes when buffers are added/deleted

### `:FuzzyList`

Browse and select from quickfix list history.

**Example:**
```vim
:FuzzyList
Select Quickfix: 2
```

Shows all quickfix lists in the history stack and allows you to restore a previous list.

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

vim.keymap.set('n', '<leader>/', '<CMD>FuzzyGrep<CR>', { desc = 'Fuzzy grep' })
vim.keymap.set('n', '<leader>ff', '<CMD>FuzzyFiles!<CR>', { desc = 'Fuzzy find files' })
vim.keymap.set('n', '<leader>fb', '<CMD>FuzzyBuffers<CR>', { desc = 'List buffers' })
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

## API

### `fuzzy.setup(opts)`

Initialize the fuzzy plugin with optional configuration.

**Parameters:**
- `opts` (table|nil) - Configuration options

### `fuzzy.grep(args)`

Programmatically run a grep search.

**Parameters:**
- `args` (table|string) - Ripgrep arguments (pattern and options)

**Example:**
```lua
local fuzzy = require('fuzzy')

-- Grep for word under cursor
local word = vim.fn.expand('<cword>')
fuzzy.grep({ word })

-- Grep with options
fuzzy.grep({ 'TODO', '-t', 'lua' })

-- Literal search
fuzzy.grep({ '-F', 'function(args)' })
```

## License

MIT

## Author

[@anoopkcn](https://github.com/anoopkcn)

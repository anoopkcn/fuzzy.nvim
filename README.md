# fuzzy.nvim
For workflows using neovim's **quickfix lists**. `fuzzy.nvim` populates the quickfixlist with fuzzy search results for files, grep searches, and buffers.

![display-img](https://github.com/user-attachments/assets/3dbe6725-2613-432f-a825-bc2530e8d675)

## Features

- **Fast grep search** using `ripgrep` (fallback to `grep -R`)
    - Equivalent to the default vim command `:copen | silent grep <pattern>` but smarter
- **File finding** using `fd` (fallback to `vim.fs.find`)
- **Buffer switching** with fuzzy filtering
- **Full control** over search arguments via `ripgrep`/`fd` arguments
- **Explorer-friendly** execute commands with respect to current Explorer directory
- **Quickfix history navigation** for easy access to previous searches

## Requirements

- Neovim 0.11+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (rg) - for `:FuzzyGrep` (fallback: `grep -R`)
- [fd](https://github.com/sharkdp/fd) - for `:FuzzyFiles` (fallback: `vim.fs.find`)

## Installation

### Using neovim native [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack)
```lua
vim.pack.add({ src = "https://github.com/anoopkcn/fuzzy.nvim" })
require("fuzzy").setup()
```

**OR** manually:

```sh
git clone https://github.com/anoopkcn/fuzzy.nvim ~/.local/share/nvim/site/pack/plugins/start/fuzzy.nvim
```
Then in your `init.lua`:
```lua
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

## Configuration

```lua
require('fuzzy').setup({
  open_single_result = false,  -- Open single result directly (default: false)
  file_match_limit = 600,      -- Max files to show in FuzzyFiles (default: 600)
})
```

### Configuration Options

- **`open_single_result`** (boolean, default: `false`)
  When enabled, `:FuzzyFiles` and `:FuzzyBuffers` will automatically open a single match instead of showing the quickfix list. Use the `!` modifier to override per-command.

- **`file_match_limit`** (number, default: `600`)
  Maximum number of file results to display in the quickfix list.

## Commands

### `:FuzzyGrep[!] [pattern] [rg options]`

Search for patterns in files using ripgrep.

Alias: `:Grep`

Default behavior collapses multiple matches on the same line into a single quickfix entry. Add `!` to keep every match.

**Examples:**
```vim
:FuzzyGrep TODO
:FuzzyGrep! TODO              " keep every match on duplicate lines
:FuzzyGrep function.*init
:FuzzyGrep -t lua require
:FuzzyGrep -i error -g '*.yml'
:FuzzyGrep "TODO|FIXME" -g '*.js'
```

### `:FuzzyFiles[!] [fd arguments]`

Find files using fd.

Alias: `:Files`

**Examples:**
```vim
:FuzzyFiles .lua$
:FuzzyFiles! init.lua         " open directly if single match
:FuzzyFiles -e go --max-depth 2
:FuzzyFiles --no-ignore config " include gitignored files
```

### `:FuzzyBuffers[!] [pattern]`

List and filter open buffers.

Alias: `:Buffers`

**Examples:**
```vim
:FuzzyBuffers          " show all buffers in quickfix
:FuzzyBuffers! init    " switch directly if single match
:FuzzyBuffers lua      " filter buffers matching 'lua'
```

### `:FuzzyList`

Browse and select from quickfix list history.

Alias: `:List`

### `:FuzzyNext` / `:FuzzyPrev`

Navigate quickfix entries with cycling (wraps around at ends).

## Quickfix Navigation

All fuzzy commands populate the quickfix list:

```vim
:cnext      " Next item
:cprev      " Previous item
:copen      " Open quickfix window
:cclose     " Close quickfix window
<CR>        " Jump to item (in quickfix window)
```

## Example Configuration

```lua
local fuzzy = require('fuzzy')
fuzzy.setup()

-- Grep
vim.keymap.set('n', '<leader>/', ':Grep ', { desc = 'Grep' })

-- Files
vim.keymap.set('n', '<leader>ff', ':Files ', { desc = 'Find files' })

-- Buffers
vim.keymap.set('n', '<leader>fb', ':Buffers! ', { desc = 'Switch buffer' })

-- Quickfix history
vim.keymap.set('n', '<leader>fl', '<CMD>FuzzyList<CR>', { desc = 'Quickfix history' })

-- Grep word under cursor
vim.keymap.set('n', '<leader>fw', function()
    local word = vim.fn.expand('<cword>')
    if word ~= '' then fuzzy.grep({ word }) end
end, { desc = 'Grep word' })

-- Grep WORD (literal)
vim.keymap.set('n', '<leader>fW', function()
    local word = vim.fn.expand('<cWORD>')
    if word ~= '' then fuzzy.grep({ '-F', word }) end
end, { desc = 'Grep WORD (literal)' })
```

## API

### `fuzzy.setup(opts)`

Initialize the plugin with optional configuration.

### `fuzzy.grep(args, dedupe)`

Programmatically run a grep search.

- `args` (table|string) - Ripgrep arguments
- `dedupe` (boolean) - Collapse duplicate line matches (default: true)

```lua
fuzzy.grep({ 'TODO', '-t', 'lua' })
fuzzy.grep({ '-F', 'function(args)' })  -- literal search
```

## License

MIT

## Related Plugins

- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)

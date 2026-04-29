# fuzzy.nvim
For workflows using neovim's **quickfix lists**. `fuzzy.nvim` populates the quickfixlist with fuzzy search results for files, grep, buffers, etc.

![display-img](https://github.com/user-attachments/assets/9cbc60eb-0631-4eff-9cb4-81e3df280f1e)

## Features

- **`:FuzzyGrep` - Fast grep search** using `ripgrep` (fallback to `grep -R`)
    - Equivalent to the default vim command `:copen | silent grep <pattern>` but smarter
    - Live grep picker highlights matched text within results
    - Per-session result cache: refining a query (e.g. `foo` → `foobar`) filters instantly from cache; same query typed again skips grep entirely
- **`:FuzzyGrepIn` - Grep inside a specific directory** (e.g. vim help docs, a subdirectory, `$VIMRUNTIME/doc`)
- **`:FuzzyFiles` - File finding** using `fd` (fallback to `vim.fs.find`)
- **`:FuzzyBuffers` - Buffer switching** with fuzzy filtering
- **Full control** over search arguments via `ripgrep`/`fd` arguments
- **Explorer-friendly** execute commands with respect to current Explorer directory
- **!** Add `!` to any command to open an interactive picker instead of populating the quickfix list
- **`<M-q>` in any picker** sends the currently visible or marked(using `<Tab>`) results to the quickfix list 

## Requirements

- Neovim 0.11+
- (Optional) For best performance:
    - [ripgrep](https://github.com/BurntSushi/ripgrep) (rg) - for `:FuzzyGrep` (fallback: `grep -R`)
    - [fd](https://github.com/sharkdp/fd) - for `:FuzzyFiles` (fallback: `vim.fs.find`)

## Installation

### Using neovim native [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack)
```lua
vim.pack.add({ src = "https://github.com/anoopkcn/fuzzy.nvim" })
require("fuzzy").setup()
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

## Convention

All commands follow the same rule:

| Form | Behaviour |
|---|---|
| `:Command [args]` | Populate the **quickfix list** |
| `:Command! [args]` | Open the interactive **picker** |

Passing arguments to the `!` form pre-fills the picker's search query.

## Picker Keymaps

Inside any interactive picker (`!` form):

| Key | Action |
|---|---|
| `<CR>` | Accept selection / jump to result |
| `<C-n>` / `<Down>` | Next result |
| `<C-p>` / `<Up>` | Previous result |
| `<Esc>` / `<C-c>` | Close picker |
| `<M-q>` | Send visible results to quickfix and close |

`<M-q>` respects the current filter: only items visible in the picker are sent. The key is configurable via `send_to_qf_key` (see [Configuration](#configuration-optional)).

## Configuration (optional)

```lua
require('fuzzy').setup({
  open_single_result = false,  -- Auto-open when only one result matches (default: false)
  file_match_limit = 10000,    -- Max files in FuzzyFiles picker/QF (default: 10000)
  grep_dedupe = true,          -- Deduplicate grep results by file:line (default: true)
  send_to_qf_key = "<M-q>",   -- Key to send picker results to QF (false to disable)
})
```

- **`open_single_result`** (boolean, default: `false`)
  When enabled, `:FuzzyFiles` and `:FuzzyBuffers` (QF path) automatically open/switch when only one result matches.

- **`file_match_limit`** (number, default: `10000`)
  Maximum number of file results to display. Results stream incrementally so large directories don't cause UI hangs.

- **`grep_dedupe`** (boolean, default: `true`)
  Collapse multiple matches on the same file:line into a single entry. Applies to both the quickfix and live-grep picker paths. Set to `false` to show every match.

- **`send_to_qf_key`** (string|false, default: `"<M-q>"`)
  Insert-mode key used inside any picker to send the currently visible (filtered) results to the quickfix list and close the picker. Set to `false` to disable.

## Commands

### `:FuzzyGrep[!] [pattern] [rg options]`

Search for patterns in files using ripgrep.

Alias: `:Grep`

- `:Grep pattern` — streams results directly to the quickfix list.
- `:Grep!` — opens a live grep picker that streams matches as you type.
- `:Grep! pattern` — opens the picker pre-filled with the pattern.
- `:Grep` (no args, no `!`) — shows a notification asking for a pattern.

The live grep picker caches results per session:
- Refining a query (e.g. `foo` → `foobar`) instantly filters cached results while grep runs in the background for completeness.
- Typing the exact same query again serves results from cache, skipping grep entirely.
- Matched text is highlighted within each result line.

### `:FuzzyGrepIn[!] <dir> [pattern] [rg options]`

Grep inside a specific directory instead of the current working directory.

Alias: `:GrepIn`

- `:GrepIn dir pattern` — streams results for `pattern` inside `dir` to the quickfix list.
- `:GrepIn! dir` — opens a live grep picker scoped to `dir`.
- `:GrepIn! dir pattern` — opens the picker pre-filled with `pattern`, scoped to `dir`.

`dir` is expanded (supports `~` and `$ENV` variables) and must be a valid directory.

Examples:
```
:GrepIn! $VIMRUNTIME/doc          " live grep vim help docs
:GrepIn! ~/.config/nvim TODO      " search for TODO in nvim config
:GrepIn /path/to/project error    " stream results to quickfix
```

### `:FuzzyFiles[!] [fd arguments]`

Alias: `:Files`

- `:Files` — runs fd and streams all results to the quickfix list.
- `:Files path` — streams fd results filtered by path/pattern to quickfix.
- `:Files!` — opens the file picker (from cache).
- `:Files! query` — opens the picker pre-filled with the query.

### `:FuzzyBuffers[!] [pattern]`

List and filter open buffers.

Alias: `:Buffers`

- `:Buffers` — all open buffers in the quickfix list.
- `:Buffers pattern` — quickfix list filtered by pattern.
- `:Buffers!` — opens the interactive buffer picker.
- `:Buffers! query` — opens the picker pre-filled with the query.

### `:FuzzyList[!]`

Browse and select from quickfix list history.

Alias: `:List`

Default behavior shows all quickfix lists. Add `!` to show only lists created by fuzzy commands.

### `:FuzzyNext` / `:FuzzyPrev`

Navigate quickfix entries with cycling (wraps around at ends).

## Example Configuration

```lua
local fuzzy = require('fuzzy')
fuzzy.setup({
  grep_dedupe = true,  -- deduplicate grep results (default)
})

-- Picker workflow (interactive)
vim.keymap.set('n', '<leader>/', '<CMD>Grep!<CR>', { desc = 'Live grep picker' })
vim.keymap.set('n', '<leader>ff', '<CMD>Files!<CR>', { desc = 'File picker' })
vim.keymap.set('n', '<leader>fb', '<CMD>Buffers!<CR>', { desc = 'Buffer picker' })

-- Quickfix workflow (type a pattern, results stream to QF)
vim.keymap.set('n', '<leader>fg', ':Grep ', { desc = 'Grep → QF' })

-- Quickfix history
vim.keymap.set('n', '<leader>fl', '<CMD>FuzzyList<CR>', { desc = 'Quickfix history' })

-- Grep word under cursor → QF
vim.keymap.set('n', '<leader>fw', function()
    local word = vim.fn.expand('<cword>')
    if word ~= '' then fuzzy.grep({ word }) end
end, { desc = 'Grep word' })

-- Grep WORD (literal) → QF
vim.keymap.set('n', '<leader>fW', function()
    local word = vim.fn.expand('<cWORD>')
    if word ~= '' then fuzzy.grep({ '-F', word }) end
end, { desc = 'Grep WORD (literal)' })

-- Live grep inside vim help docs
vim.keymap.set('n', '<leader>fh', '<CMD>GrepIn! $VIMRUNTIME/doc<CR>', { desc = 'Search help docs' })
```

## API

### `fuzzy.setup(opts)`

Initialize the plugin with optional configuration.

### `fuzzy.grep(args)`

Programmatically run a grep search and populate the quickfix list.

- `args` (table|string) - Ripgrep arguments

```lua
fuzzy.grep({ 'TODO', '-t', 'lua' })
fuzzy.grep({ '-F', 'function(args)' })  -- literal search
```

### `fuzzy.grep_in(dir, args)`

Programmatically grep inside a specific directory.

- `dir` (string) - Directory to search in (supports `~` and `$ENV`)
- `args` (table|string) - Ripgrep arguments (pattern and options)

```lua
fuzzy.grep_in('$VIMRUNTIME/doc', { 'autocmd' })
fuzzy.grep_in('~/.config/nvim', { 'TODO', '-t', 'lua' })
```

## License

MIT

## Related Plugins

- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)

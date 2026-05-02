# fuzzy.nvim
For workflows using neovim's **quickfix lists**. `fuzzy.nvim` populates the quickfixlist with fuzzy search results for files, grep, buffers, etc.

![display-img](https://github.com/user-attachments/assets/204d79e3-4094-4e0f-8dac-2b9590aafbf3)

## Features

- **`:FuzzyGrep` - Fast grep search** using `ripgrep` (fallback to `grep -R`)
    - Equivalent to the default vim command `:copen | silent grep <pattern>` but smarter
    - Live grep picker highlights matched text within results
    - Per-session result cache: refining a query (e.g. `foo` → `foobar`) filters instantly from cache; same query typed again skips grep entirely
- **`:FuzzyGrepIn` - Grep inside a specific directory** (e.g. vim help docs, a subdirectory, `$VIMRUNTIME/doc`)
- **`:FuzzyFiles` - File finding** using `fd` (fallback to `vim.fs.find`)
- **`:FuzzyBuffers` - Buffer switching** with fuzzy filtering
- **`:FuzzyHelp` - Help tag browser** with `'helplang'`-aware tag discovery across the full `runtimepath`
- **`:FuzzyCommands` - Command palette** for built-in, user, plugin commands, and Neovim options
- **`:FuzzyGitBranches` - Git branch browser/switcher**
- **`:FuzzyGitWorktrees` - Git worktree browser/switcher**
- **Full control** over search arguments via `ripgrep`/`fd` arguments
- **Explorer-friendly** execute commands with respect to current Explorer directory
- **!** Add `!` to quickfix-backed commands to open an interactive picker instead of populating the quickfix list
- **`<M-q>` in supported pickers** sends the currently visible or marked (using `<Tab>`) results to the quickfix list
- **`<M-r>` in live grep pickers** edits ripgrep backend flags without leaving the picker

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

Passing arguments to the `!` form pre-fills the picker's search query. For live grep pickers, ripgrep options are also preserved and can be edited in-picker.

`:FuzzyHelp`, `:FuzzyCommands`, `:FuzzyGitBranches`, and `:FuzzyGitWorktrees` always open an interactive picker; they do not have a quickfix-only mode.

## Picker Keymaps

Inside any interactive picker:

| Key | Action |
|---|---|
| `<CR>` | Accept selection / jump to result; when items are marked with `<Tab>`, file-backed pickers load the marked files as buffers and show one of them |
| `<C-n>` / `<Down>` | Next result |
| `<C-p>` / `<Up>` | Previous result |
| `<Tab>` / `<S-Tab>` | Mark / unmark result |
| `<Esc>` / `<C-c>` | Close picker |
| `<M-q>` | Send visible results, or marked results, to quickfix and close where supported |
| `<M-r>` | Edit ripgrep backend flags in `:FuzzyGrep!` / `:FuzzyGrepIn!` |

In `:FuzzyBuffers!`, marked entries are already open buffers, so `<CR>` does not perform any extra load for them. `<M-q>` respects the current filter when nothing is marked. The key is configurable via `send_to_qf_key` (see [Configuration](#configuration-optional)). `:FuzzyCommands` does not expose `<M-q>` because command entries are actions, not file locations.

In `:FuzzyGrep!` and `:FuzzyGrepIn!`, press `<M-r>` to edit the active ripgrep flags (for example `-t lua -g '*.md'`) while keeping the current query in place. The key is configurable via `edit_grep_flags_key`.

## Configuration (optional)

```lua
require('fuzzy').setup({
  open_single_result = false,  -- Auto-open when only one result matches (default: false)
  file_match_limit = 10000,    -- Max files in FuzzyFiles picker/QF (default: 10000)
  grep_dedupe = true,          -- Deduplicate grep results by file:line (default: true)
  send_to_qf_key = "<M-q>",   -- Key to send picker results to QF (false to disable)
  edit_grep_flags_key = "<M-r>", -- Key to edit rg flags in live grep pickers
  window = {                   -- Picker window geometry (height/width/row/col are 0..1)
    height = 0.4,              -- max fraction of vim.o.lines used by the picker
    width  = 0.6,              -- fraction of vim.o.columns
    row    = 0.0,              -- 0=top, 1=bottom of free space
    col    = 0.5,              -- 0=left, 1=right of free space (0.5 = centered)
    border = "rounded",        -- passthrough to nvim_open_win()
    title_pos = "center",      -- "left" | "center" | "right"
  },
})
```

- **`open_single_result`** (boolean, default: `false`)
  When enabled, `:FuzzyFiles` and `:FuzzyBuffers` (QF path) automatically open/switch when only one result matches.

- **`file_match_limit`** (number, default: `10000`)
  Maximum number of file results to display. Results stream incrementally so large directories don't cause UI hangs.

- **`grep_dedupe`** (boolean, default: `true`)
  Collapse multiple matches on the same file:line into a single entry. Applies to both the quickfix and live-grep picker paths. Set to `false` to show every match.

- **`send_to_qf_key`** (string|false, default: `"<M-q>"`)
  Insert-mode key used inside picker types that support quickfix export to send the currently visible (filtered) results to the quickfix list and close the picker. Set to `false` to disable.

- **`edit_grep_flags_key`** (string|false, default: `"<M-r>"`)
  Insert-mode key used inside `:FuzzyGrep!` and `:FuzzyGrepIn!` to edit ripgrep backend flags without closing the picker. Set to `false` to disable.

- **`window`** (table)
  Picker window geometry. `height`/`width` are fractions of the editor; `row`/`col` are positions within the free space (0=top/left, 1=bottom/right, 0.5=centered). `border` accepts any value `nvim_open_win()` does. `title_pos` is `"left"`, `"center"`, or `"right"`. The picker still shrinks to fit fewer results — `height` is a cap.

## Commands

### `:FuzzyGrep[!] [pattern] [rg options]`

Search for patterns in files using ripgrep.

- `:FuzzyGrep pattern` — streams results directly to the quickfix list.
- `:FuzzyGrep!` — opens a live grep picker that streams matches as you type.
- `:FuzzyGrep! pattern` — opens the picker pre-filled with the pattern.
- `:FuzzyGrep! pattern [rg options]` — opens the picker with the pattern and initial ripgrep flags.
- `:FuzzyGrep` (no args, no `!`) — shows a notification asking for a pattern.

The live grep picker caches results per session:
- Refining a query (e.g. `foo` → `foobar`) instantly filters cached results while grep runs in the background for completeness.
- Typing the exact same query again serves results from cache, skipping grep entirely.
- Matched text is highlighted within each result line.

Inside the picker, press `<M-r>` to edit ripgrep backend flags without losing the current query. Cache entries are scoped by both the query and the active flags.

### `:FuzzyGrepIn[!] <dir> [pattern] [rg options]`

Grep inside a specific directory instead of the current working directory.

- `:FuzzyGrepIn dir pattern` — streams results for `pattern` inside `dir` to the quickfix list.
- `:FuzzyGrepIn! dir` — opens a live grep picker scoped to `dir`.
- `:FuzzyGrepIn! dir pattern` — opens the picker pre-filled with `pattern`, scoped to `dir`.
- `:FuzzyGrepIn! dir pattern [rg options]` — opens the picker with the pattern and initial ripgrep flags, scoped to `dir`.

`dir` is expanded (supports `~` and `$ENV` variables) and must be a valid directory.

Examples:
```
:FuzzyGrepIn! $VIMRUNTIME/doc          " live grep vim help docs
:FuzzyGrepIn! ~/.config/nvim TODO      " search for TODO in nvim config
:FuzzyGrepIn /path/to/project error    " stream results to quickfix
```

### `:FuzzyFiles[!] [fd arguments]`

- `:FuzzyFiles` — runs fd and streams all results to the quickfix list.
- `:FuzzyFiles path` — streams fd results filtered by path/pattern to quickfix.
- `:FuzzyFiles!` — opens the file picker (from cache).
- `:FuzzyFiles! query` — opens the picker pre-filled with the query.

Unlike the live grep pickers, `:FuzzyFiles!` does not edit backend `fd` flags from inside the picker; it still filters the warmed file cache by query only.

### `:FuzzyBuffers[!] [pattern]`

List and filter open buffers.

- `:FuzzyBuffers` — all open buffers in the quickfix list.
- `:FuzzyBuffers pattern` — quickfix list filtered by pattern.
- `:FuzzyBuffers!` — opens the interactive buffer picker.
- `:FuzzyBuffers! query` — opens the picker pre-filled with the query.

### `:FuzzyCommands [query]`

Browse built-in, user, and plugin commands available in the current Neovim session, plus Neovim options such as `relativenumber`.

- `:FuzzyCommands` — opens the command picker.
- `:FuzzyCommands query` — opens the picker pre-filled with `query`.

Readable command names are shown by default, so punctuation commands like `!`, `#`, `=`, and `~` are hidden. Entries render as aligned `CMD`/`OPT` rows, with option aliases in their own column and long descriptions or values trimmed to the picker width. User and plugin commands show descriptions when Neovim exposes them, and option entries stay searchable by both full name and shortname. Press `<CR>` to stage the selected command or option edit in the command line, for example `:FuzzyFiles ` or `:set relativenumber `.

### `:FuzzyGitBranches [query]`

Browse and switch Git branches.

- `:FuzzyGitBranches` — open the branch picker.
- `:FuzzyGitBranches feat` — open the branch picker pre-filtered with `feat`.

The picker lists local and remote branches, marks the current branch with `*`, and switches on `<CR>` (`git switch <branch>` for local branches, `git switch --track <remote>` for remote branches).

### `:FuzzyGitWorktrees [query]`

Browse and switch Git worktrees.

- `:FuzzyGitWorktrees` — open the worktree picker.
- `:FuzzyGitWorktrees feature` — open the worktree picker pre-filtered with `feature`.

The picker lists `git worktree list --porcelain`, marks the current worktree with `*`, and switches on `<CR>` by changing Neovim's current directory to the selected worktree path.

More Git pickers may be added later using the same source architecture.

### `:FuzzyHelp [query]`

Browse and open Neovim/Vim help tags.

- `:FuzzyHelp` — opens the help tag picker.
- `:FuzzyHelp query` — opens the picker pre-filled with `query`.

Always opens the interactive picker; there is no quickfix-only mode. Tag discovery reads `doc/tags` and `doc/tags-{lang}` files across the full `runtimepath`. Language priority follows `'helplang'`, with `en` appended as a fallback.

Each entry shows `tagname  filename.txt`; filtering matches against both, so you can narrow by topic (`autocmd`) or by file (`lsp.txt`). Press `<CR>` to jump via `:help`, or `<M-q>` to export visible tags to the quickfix list (entries resolve to the exact tag location).

### `:FuzzyList[!]`

Browse and select from quickfix list history.

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
vim.keymap.set('n', '<leader>/', '<CMD>FuzzyGrep!<CR>', { desc = 'Live grep picker' })
vim.keymap.set('n', '<leader>ff', '<CMD>FuzzyFiles!<CR>', { desc = 'File picker' })
vim.keymap.set('n', '<leader>fb', '<CMD>FuzzyBuffers!<CR>', { desc = 'Buffer picker' })
vim.keymap.set('n', '<leader>fh', '<CMD>FuzzyHelp<CR>', { desc = 'Help tag picker' })
vim.keymap.set('n', '<leader>fc', '<CMD>FuzzyCommands<CR>', { desc = 'Command picker' })
vim.keymap.set('n', '<leader>gb', '<CMD>FuzzyGitBranches<CR>', { desc = 'Git branches' })
vim.keymap.set('n', '<leader>gw', '<CMD>FuzzyGitWorktrees<CR>', { desc = 'Git worktrees' })

-- Help tag for word under cursor
vim.keymap.set('n', 'K', function()
    vim.cmd('FuzzyHelp ' .. vim.fn.expand('<cword>'))
end, { desc = 'Help for word' })

-- Quickfix workflow (type a pattern, results stream to QF)
vim.keymap.set('n', '<leader>fg', ':FuzzyGrep ', { desc = 'Grep → QF' })

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
vim.keymap.set('n', '<leader>fH', '<CMD>FuzzyGrepIn! $VIMRUNTIME/doc<CR>', { desc = 'Search help docs' })
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

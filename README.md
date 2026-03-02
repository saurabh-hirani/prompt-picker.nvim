# nvim-prompt-picker

A Neovim plugin for quickly generating AI prompts with file context.

## Features

- Pre-defined prompts for common tasks (explain, fix, optimize, review, tests, etc.)
- Adhoc custom prompts with automatic context injection
- Automatically includes file path and line ranges
- Works with visual selections
- Integrates with LSP diagnostics
- Uses fzf-lua for selection UI

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "saurabh-hirani/nvim-prompt-picker",
  dependencies = { "ibhagwan/fzf-lua" },
  opts = {
    config_file = "/path/to/prompt_config.jsonc",  -- Optional: path to config file
  },
}
```

## Configuration

Create `prompt_config.jsonc` and reference it in your plugin setup. See `prompt_config.jsonc.example` for reference.

```lua
opts = {
  config_file = "/path/to/prompt_config.jsonc",
}
```

Configuration file format:

```jsonc
{
  "config": {
    "send_to_tmux": false,      // true - send to tmux pane instead of clipboard
    "tmux_target": [            // List of target panes in format: session:window.pane
      "+",                      // send to next panel
      "mysession:window1.1"
    ],
    "tmux_send_enter": false    // true - send Enter key after prompt
  },
  "prompts": {
    "explain": "Explain {range}",
    "fix": "Fix {range}"
  }
}
```

## Usage

### Keybindings

```lua
-- Select from predefined prompts
vim.keymap.set("n", "<leader>pp", function() require("prompt-picker").select() end)

-- Adhoc custom prompt
vim.keymap.set({"n", "v"}, "<leader>pa", function() require("prompt-picker").adhoc() end)
```

### Predefined Prompts

- `changes` - Review changes in file
- `diagnostics` - Fix diagnostics in current file
- `diagnostics_all` - Fix all diagnostics
- `document` - Add documentation
- `explain` - Explain code
- `implement` - Implement code
- `fix` - Fix code
- `optimize` - Optimize code
- `review` - Review file
- `tests` - Write tests

### Context Variables

Prompts support these variables:
- `{file}` - Current file path
- `{range}` - File path with line range (e.g., `@file.lua:L10-L20`)
- `{position}` - File path with cursor position
- `{selection}` - Selected text
- `{diagnostics}` - LSP diagnostics for current file
- `{diagnostics_all}` - All LSP diagnostics

## Workflow

1. Select code (visual mode) or position cursor
2. Trigger prompt picker (`<leader>pp` or `<leader>pa`)
3. Choose prompt or enter custom text
4. Prompt with context is copied to clipboard
5. Paste into your AI tool

## Requirements

- Neovim 0.11+
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)

## License

MIT

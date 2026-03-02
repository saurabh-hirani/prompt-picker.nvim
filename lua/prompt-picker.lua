local M = {}

local config_file_path = nil

local function load_config()
  if not config_file_path then
    return nil
  end
  local file = io.open(vim.fn.expand(config_file_path), 'r')
  if file then
    local content = file:read('*a')
    file:close()
    content = content:gsub('//[^\n]*', '')
    local ok, data = pcall(vim.json.decode, content)
    if ok then
      return data
    end
  end
  return nil
end

local default_config = {
  send_to_tmux = false,
  tmux_panes = {"+"},
  tmux_send_enter = false,
  tmux_auto_select_panes = {},  -- If set, use these panes directly without prompting
}

local default_prompts = {
  changes = "Review my changes in file: {file}",
  diagnostics = "Help me fix the diagnostics in {file}\n{diagnostics}",
  diagnostics_all = "Help me fix these diagnostics\n{diagnostics_all}",
  document = "Add documentation to {range}",
  explain = "Explain {range}",
  implement = "Implement {range}",
  fix = "Fix {range}",
  optimize = "Optimize {range}",
  review = "Review {file} for any issues or improvements",
  tests = "Write tests for {range}",
}

M.config = vim.deepcopy(default_config)
M.prompts = vim.deepcopy(default_prompts)

local function get_context()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))

  -- Check if we have a visual selection using marks
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  -- Only use visual selection if marks are in current buffer and valid
  local has_selection = start_line > 0 and end_line > 0 and start_line <= end_line

  local selection = ""
  if has_selection and start_line ~= end_line then
    local lines = vim.fn.getline(start_line, end_line)
    selection = table.concat(lines, "\n")
  else
    start_line = row
    end_line = row
    selection = vim.fn.getline(row)
  end

  local range = string.format("%s:L%d-L%d", file, start_line, end_line)

  local diagnostics = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    table.insert(diagnostics, string.format("Line %d: %s", d.lnum + 1, d.message))
  end

  return {
    file = file,
    position = string.format("%s :L%d:C%d", file, row, col),
    range = range,
    selection = selection,
    diagnostics = table.concat(diagnostics, "\n"),
    diagnostics_all = table.concat(diagnostics, "\n"),
  }
end

local function render_prompt(template)
  local ctx = get_context()
  return (template:gsub("{(%w+)}", function(key)
    return ctx[key] or "{" .. key .. "}"
  end))
end

local function send_prompt(text)
  if M.config.send_to_tmux then
    -- If tmux_auto_select_panes is set, use those panes directly without prompting
    if M.config.tmux_auto_select_panes and #M.config.tmux_auto_select_panes > 0 then
      for _, target in ipairs(M.config.tmux_auto_select_panes) do
        local escaped = text:gsub("'", "'\\''")
        vim.fn.system(string.format("tmux send-keys -t '%s' '%s'", target, escaped))
        if M.config.tmux_send_enter then
          vim.fn.system(string.format("tmux send-keys -t '%s' Enter", target))
        end
      end
      return
    end
    
    -- Get list of panes in current session
    local handle = io.popen('tmux list-panes -s -F "#{window_index}.#{pane_index}: #{pane_current_command} [#{window_name}]"')
    local panes = handle:read("*a")
    handle:close()
    
    -- Build items list from tmux_panes config
    local items = {"+ (next pane)"}
    local config_panes = type(M.config.tmux_panes) == "table" and M.config.tmux_panes or {M.config.tmux_panes}
    for _, pane in ipairs(config_panes) do
      if pane ~= "+" then
        table.insert(items, pane)
      end
    end
    
    for line in panes:gmatch("[^\r\n]+") do
      table.insert(items, line)
    end
    
    -- Use fzf-lua for multi-select
    require('fzf-lua').fzf_exec(items, {
      prompt = "Send to tmux pane(s) (Tab for multi-select): ",
      actions = {
        ['default'] = function(selected)
          if not selected or #selected == 0 then
            return
          end
          
          for _, choice in ipairs(selected) do
            local target
            if choice == "+ (next pane)" or choice == "+" then
              target = "+"
            elseif choice:match("^%d+%.%d+:") then
              target = choice:match("^(%d+%.%d+):")
            else
              target = choice
            end
            
            local escaped = text:gsub("'", "'\\''")
            vim.fn.system(string.format("tmux send-keys -t '%s' '%s'", target, escaped))
            if M.config.tmux_send_enter then
              vim.fn.system(string.format("tmux send-keys -t '%s' Enter", target))
            end
          end
        end
      }
    })
  else
    vim.fn.setreg('+', text)
    print("Prompt copied to clipboard")
  end
end

local function show_adhoc_prompt(ctx)
  -- Create floating window for input
  local buf = vim.api.nvim_create_buf(false, true)
  local width = 60
  local height = 1
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = 'minimal',
    border = 'rounded',
    title = ' Enter prompt ',
    title_pos = 'center',
  })

  vim.keymap.set('i', '<CR>', function()
    local input = vim.api.nvim_get_current_line()
    vim.api.nvim_win_close(win, true)
    vim.schedule(function()
      if input and input ~= "" then
        local rendered = string.format("%s %s", input, ctx.range)
        send_prompt(rendered)
      end
    end)
  end, { buffer = buf })

  vim.keymap.set('i', '<Esc>', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })

  vim.cmd('startinsert')
end

function M.select()
  -- Capture context before opening selector (to preserve visual mode)
  local ctx = get_context()

  local items = {}
  for name, template in pairs(M.prompts) do
    table.insert(items, name)
  end
  table.insert(items, "adhoc")
  table.sort(items)
  
  -- Move "explain" to the front if it exists
  for i, item in ipairs(items) do
    if item == "explain" then
      table.remove(items, i)
      table.insert(items, 1, "explain")
      break
    end
  end

  vim.ui.select(items, {
    prompt = "Select a prompt: ",
    format_item = function(name)
      if name == "adhoc" then
        return "[adhoc] Custom prompt with context"
      end
      return string.format("[%s] %s", name, M.prompts[name]:gsub("\n", " "))
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice == "adhoc" then
      show_adhoc_prompt(ctx)
    else
      local template = M.prompts[choice]
      local rendered = (template:gsub("{(%w+)}", function(key)
        return ctx[key] or "{" .. key .. "}"
      end))
      send_prompt(rendered)
    end
  end)
end

function M.adhoc()
  local ctx = get_context()
  show_adhoc_prompt(ctx)
end

function M.send_prompt_by_name(prompt_name)
  local ctx = get_context()
  local template = M.prompts[prompt_name]
  if not template then
    print("Prompt '" .. prompt_name .. "' not found")
    return
  end
  local rendered = (template:gsub("{(%w+)}", function(key)
    return ctx[key] or "{" .. key .. "}"
  end))
  send_prompt(rendered)
end

-- Convenience functions
function M.explain() M.send_prompt_by_name("explain") end
function M.document() M.send_prompt_by_name("document") end
function M.implement() M.send_prompt_by_name("implement") end

function M.setup(opts)
  opts = opts or {}
  if opts.config_file then
    config_file_path = opts.config_file
    local loaded = load_config()
    if loaded then
      M.config = vim.tbl_deep_extend("force", default_config, loaded.config or {})
      M.prompts = vim.tbl_deep_extend("force", default_prompts, loaded.prompts or {})
    end
  end
  if opts.config then
    M.config = vim.tbl_deep_extend("force", M.config, opts.config)
  end
  if opts.prompts then
    M.prompts = vim.tbl_deep_extend("force", M.prompts, opts.prompts)
  end
end

function M.reload_config()
  if config_file_path then
    local loaded = load_config()
    if loaded then
      M.config = vim.tbl_deep_extend("force", default_config, loaded.config or {})
      M.prompts = vim.tbl_deep_extend("force", default_prompts, loaded.prompts or {})
      print("Config reloaded from " .. config_file_path)
      print("tmux_panes: " .. vim.inspect(M.config.tmux_panes))
    else
      print("Failed to reload config from " .. config_file_path)
    end
  else
    print("No config file path set")
  end
end

return M

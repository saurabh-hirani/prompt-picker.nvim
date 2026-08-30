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
  send_to_herdr = false,
  herdr_panes = {"right"},      -- direction ("right"/"left"/"up"/"down") = that neighbour of
                                -- the calling pane, "current" = calling pane, or an explicit pane id
  herdr_send_enter = false,
  herdr_auto_select_panes = {}, -- If set, use these targets directly without prompting
  herdr_focus = true,           -- true - focus the target pane after sending
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

-- Send `text` to a single herdr pane via `pane send-text`, optionally Enter.
-- Args are passed as a list so no shell quoting is needed. `direction` (when the
-- target was chosen by direction) lets us focus it afterwards -- herdr's
-- `pane focus` is direction-based (`--pane` is not supported), so focus only
-- works for directional targets.
local function herdr_send(pane_id, text, direction)
  vim.fn.system({ "herdr", "pane", "send-text", pane_id, text })
  if M.config.herdr_send_enter then
    vim.fn.system({ "herdr", "pane", "send-keys", pane_id, "Enter" })
  end
  if M.config.herdr_focus and direction then
    vim.fn.system({ "herdr", "pane", "focus", "--direction", direction, "--current" })
  end
end

local HERDR_DIRECTION_LABELS = {
  right = "\u{2192} pane on the right",
  left = "\u{2190} pane on the left",
  up = "\u{2191} pane above",
  down = "\u{2193} pane below",
}

-- Resolve the pane id neighbouring $HERDR_PANE_ID in `direction` (nil if none).
local function herdr_neighbor(direction)
  local out = vim.fn.system({ "herdr", "pane", "neighbor", "--direction", direction, "--current" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, out)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local neighbor = data.result and data.result.neighbor
  return neighbor and neighbor.neighbor_pane_id or nil
end

-- Resolve a picker choice into a herdr pane id, plus the direction it came from
-- (nil for non-directional choices). A direction word or arrow label resolves to
-- that neighbour of the calling pane; "current" maps to $HERDR_PANE_ID;
-- otherwise the leading token is the opaque pane id.
local function herdr_target_of(choice)
  if choice == "current" or choice:match("^current pane") then
    return vim.env.HERDR_PANE_ID, nil
  end
  for direction, label in pairs(HERDR_DIRECTION_LABELS) do
    if choice == direction or choice == label then
      return herdr_neighbor(direction), direction
    end
  end
  return choice:match("^(%S+)"), nil
end

-- Live herdr panes as picker lines "<pane_id>  <agent/label/short-cwd>",
-- excluding `exclude` (the caller pane). cwd is shortened to its last segment.
local function herdr_pane_items(json, exclude)
  local ok, data = pcall(vim.json.decode, json)
  if not ok or type(data) ~= "table" then
    return {}
  end
  local panes = data.result and data.result.panes
  if type(panes) ~= "table" then
    return {}
  end
  local items = {}
  for _, pane in ipairs(panes) do
    if type(pane) == "table" and pane.pane_id and pane.pane_id ~= exclude then
      local desc = pane.agent or pane.label
      if not desc and pane.cwd then
        desc = pane.cwd:match("([^/]+)/?$") or pane.cwd
      end
      table.insert(items, pane.pane_id .. (desc and ("  " .. desc) or ""))
    end
  end
  return items
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
  elseif M.config.send_to_herdr then
    if vim.fn.executable("herdr") ~= 1 then
      print("herdr not found on PATH")
      return
    end
    if vim.env.HERDR_ENV ~= "1" then
      print("Not inside a herdr session")
      return
    end

    -- If herdr_auto_select_panes is set, use those targets directly.
    if M.config.herdr_auto_select_panes and #M.config.herdr_auto_select_panes > 0 then
      for _, pane in ipairs(M.config.herdr_auto_select_panes) do
        local target, direction = herdr_target_of(pane)
        if target then
          herdr_send(target, text, direction)
        end
      end
      return
    end

    -- Build the pane list: configured convenience targets first (a direction
    -- like "right" is your editor-left/agent-right default, shown as an arrow
    -- label; "current" is the calling pane), then the live panes in the current
    -- workspace only. Scoping mirrors tmux list-panes -s.
    local items = {}
    local config_panes = type(M.config.herdr_panes) == "table" and M.config.herdr_panes or {M.config.herdr_panes}
    for _, pane in ipairs(config_panes) do
      if HERDR_DIRECTION_LABELS[pane] then
        table.insert(items, HERDR_DIRECTION_LABELS[pane])
      elseif pane == "current" then
        table.insert(items, "current pane ($HERDR_PANE_ID)")
      else
        table.insert(items, pane)
      end
    end
    local list_cmd = { "herdr", "pane", "list" }
    if vim.env.HERDR_WORKSPACE_ID then
      vim.list_extend(list_cmd, { "--workspace", vim.env.HERDR_WORKSPACE_ID })
    end
    local list = vim.fn.system(list_cmd)
    if vim.v.shell_error == 0 then
      vim.list_extend(items, herdr_pane_items(list, vim.env.HERDR_PANE_ID))
    end

    require('fzf-lua').fzf_exec(items, {
      prompt = "Send to herdr pane(s) (Tab for multi-select): ",
      actions = {
        ['default'] = function(selected)
          if not selected or #selected == 0 then
            return
          end
          for _, choice in ipairs(selected) do
            local target, direction = herdr_target_of(choice)
            if target then
              herdr_send(target, text, direction)
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

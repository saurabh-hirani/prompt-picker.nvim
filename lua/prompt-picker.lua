local M = {}

M.prompts = {
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

  local range = string.format("@%s :L%d-L%d", file, start_line, end_line)

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
        vim.fn.setreg('+', rendered)
        print("Prompt copied to clipboard")
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
      vim.fn.setreg('+', rendered)
      print("Prompt copied to clipboard")
    end
  end)
end

function M.adhoc()
  local ctx = get_context()
  show_adhoc_prompt(ctx)
end

return M

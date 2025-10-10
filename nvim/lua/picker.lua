local M = {}

local function has_executable(cmd)
  return vim.fn.executable(cmd) == 1
end

local function file_source_command()
  if has_executable('rg') then
    return [[rg --files --hidden --follow --glob "!.git"]]
  end

  if has_executable('fd') then
    return [[fd --type f --hidden --strip-cwd-prefix --exclude .git]]
  end

  return [[find . -type f ! -path "*/.git/*"]]
end

local function preview_command()
  if has_executable('bat') then
    return [[bat --style=numbers --color=always --line-range :500 -- {}]]
  end

  if has_executable('head') then
    return [[sh -c 'head -n 200 "$1"' sh {}]]
  end

  if has_executable('cat') then
    return [[sh -c 'cat "$1"' sh {}]]
  end

  return nil
end

local function open_picker_window()
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight

  local width = math.max(columns, 1)
  local height = math.max(lines, 1)
  local row = 0
  local col = 0

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'none',
    row = row,
    col = col,
    width = width,
    height = height,
  })

  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)
  vim.api.nvim_win_set_option(win, 'cursorline', false)
  vim.bo[buf].bufhidden = 'wipe'

  return buf, win
end

local function trim_ansi(value)
  -- remove ANSI escape sequences that may leak from the terminal buffer
  local cleaned = value:gsub('\27%[[%d;]*[A-Za-z]', '')
  return cleaned:gsub('\r', '')
end

function M.files()
  if vim.fn.executable('fzf') == 0 then
    vim.notify('fzf executable not found in PATH', vim.log.levels.ERROR)
    return
  end

  local source_cmd = file_source_command()
  local tmpfile = vim.fn.tempname()
  pcall(vim.fn.delete, tmpfile)

  local bind = string.format(
    [[enter:execute-silent(printf '%%s\n' {} > %s)+accept]],
    vim.fn.shellescape(tmpfile)
  )

  local preview = preview_command()

  local fzf_args = {
    '--prompt="Files> "',
    '--height=100%',
    '--layout=reverse',
    '--info=inline',
    '--bind ' .. vim.fn.shellescape(bind),
    '--exit-0',
    '--select-1',
  }

  if preview ~= nil then
    table.insert(fzf_args, '--preview ' .. vim.fn.shellescape(preview))
    table.insert(fzf_args, '--preview-window=right:60%:wrap')
  end

  local fzf_command = string.format(
    [[set -o pipefail; %s | fzf %s]],
    source_cmd,
    table.concat(fzf_args, ' ')
  )

  local parent_win = vim.api.nvim_get_current_win()
  local buf, win = open_picker_window()

  local function cleanup()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local job_id = vim.fn.termopen({ 'bash', '-c', fzf_command }, {
    cwd = vim.fn.getcwd(),
    on_exit = function(_, code)
      vim.schedule(function()
        cleanup()
        if vim.api.nvim_win_is_valid(parent_win) then
          pcall(vim.api.nvim_set_current_win, parent_win)
        end

        local selection
        if code == 0 then
          local ok, lines = pcall(vim.fn.readfile, tmpfile)
          if ok and lines and lines[1] and lines[1] ~= '' then
            selection = vim.trim(trim_ansi(lines[1]))
          end
        end

        pcall(vim.fn.delete, tmpfile)

        if selection and selection ~= '' then
          vim.cmd('edit ' .. vim.fn.fnameescape(selection))
        elseif code ~= 0 and code ~= 130 and code ~= 1 then
          vim.notify('fzf exited with code ' .. tostring(code), vim.log.levels.WARN)
        end
      end)
    end,
  })

  if job_id <= 0 then
    cleanup()
    pcall(vim.fn.delete, tmpfile)
    vim.notify('Failed to start fzf picker job', vim.log.levels.ERROR)
    return
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd('startinsert')
    end
  end)
end

return M

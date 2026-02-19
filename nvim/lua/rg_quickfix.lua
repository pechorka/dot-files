-- Escape ripgrep regex metacharacters for literal matching
local function rg_escape(pattern)
  -- Escape regex special chars: \^$.|?*+()[]{}
  return (pattern:gsub("[\\^$.|?*+()%[%]{}]", "\\%0"))
end

-- Shell-quote a string (POSIX-style single quotes)
local function shell_quote(s)
  -- Replace ' with '\'' and wrap in single quotes
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function rg_quickfix(opts)
  local query = opts.args or ""
  if query == "" then
    vim.notify("Usage: :Rg {pattern} [path...]", vim.log.levels.WARN)
    return
  end

  -- If called from Rgs, sanitize the pattern portion
  local cmd
  if opts.sanitize then
    -- Treat entire args as literal pattern (no path support in sanitized mode)
    local escaped = rg_escape(query)
    cmd = "rg --vimgrep --smart-case -- " .. shell_quote(escaped)
  else
    cmd = "rg --vimgrep --smart-case -- " .. query
  end

  local lines = vim.fn.systemlist(cmd)
  local code = vim.v.shell_error

  if code == 127 then
    vim.notify("ripgrep (rg) not found in PATH", vim.log.levels.ERROR)
    return
  elseif code == 2 then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.ERROR)
    return
  end

  local saved_efm = vim.o.errorformat
  vim.o.errorformat = "%f:%l:%c:%m"
  vim.fn.setqflist({}, " ", { title = "rg: " .. query, lines = lines })
  vim.o.errorformat = saved_efm

  local qflen = #vim.fn.getqflist()
  if qflen > 0 then
    vim.cmd("copen")
    vim.cmd("cfirst")
  else
    vim.notify("rg: no matches", vim.log.levels.INFO)
    vim.cmd("cclose")
  end
end

-- Original: regex-aware, manual quoting needed
vim.api.nvim_create_user_command("Rg", rg_quickfix, {
  nargs = "+",
  complete = "file",
  desc = "Ripgrep → quickfix (regex)",
})

-- Sanitized: literal search, no quoting needed
vim.api.nvim_create_user_command("Rgs", function(opts)
  opts.sanitize = true
  rg_quickfix(opts)
end, {
  nargs = "+",
  desc = "Ripgrep → quickfix (literal/sanitized)",
})

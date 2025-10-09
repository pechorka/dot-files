local M = {}

local function git(args)
  local proc = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait()
  if proc.code ~= 0 then
    return nil, (proc.stderr ~= '' and proc.stderr) or proc.stdout
  end
  return vim.split(proc.stdout, '\n', { trimempty = true }), nil
end

local function git_fl(args) -- git first line
  local lines, err = git(args)
  return lines and lines[1], err
end

local function git_remote()
  local url = git_fl({ 'remote', 'get-url', 'origin' })
  if url then return url, nil end

  local name, names_err = git_fl({ 'remote' })
  if not name then return nil, names_err or 'no git remotes configured' end

  local any_url, err = git_fl({ 'remote', 'get-url', name })
  if not any_url then return nil, err or 'failed to resolve git remote' end

  return any_url, nil
end

local function file_path_relative_to_root(root, file)
  local rel = vim.fs.relpath(root, file)
  if not rel then
    return nil, ('file %s is outside git repository %s'):format(file, root)
  end
  return rel
end

local function urlencode(str)
  return (str:gsub('([^%w%-%._~/])', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

local function normalize_remote(remote)
  remote = remote:gsub('%.git$', '')
  if remote:match('^git@') then
    local host, repo = remote:match('^git@([^:]+):(.+)$')
    if host and repo then
      return string.format('https://%s/%s', host, repo)
    end
  end
  local ssh_host, ssh_repo = remote:match('^ssh://git@([^/]+)/(.+)$')
  if ssh_host and ssh_repo then
    return string.format('https://%s/%s', ssh_host, ssh_repo)
  end
  if remote:match('^https?://') then
    return remote
  end
  return remote
end

local function copy(text)
  for _, reg in ipairs { '+', '*' } do
    pcall(vim.fn.setreg, reg, text)
  end
end

local function parse_blame(lines)
  local data = {}
  for _, line in ipairs(lines) do
    if line:sub(1, 1) == '\t' then
      data.source = line:sub(2)
    elseif not data.commit then
      local commit = line:match('^(%S+)')
      if commit then
        data.commit = commit
      end
    else
      local key, value = line:match('^(%S+)%s+(.*)$')
      if key and value then
        data[key] = value
      end
    end
  end
  return data
end

local function format_time(timestamp)
  local num = tonumber(timestamp)
  if not num then
    return nil
  end
  return os.date('%Y-%m-%d %H:%M', num)
end

local function format_commit(c)
  if not c then return 'N/A' end
  if c == ('0'):rep(40) then return 'WORKTREE' end
  if c:sub(1, 1) == '^' then c = c:sub(2) end
  return (#c >= 8) and c:sub(1, 8) or c
end

-- Gather common context for current buffer/repo
local function repo_ctx()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  if file == '' then
    return nil, 'Current buffer has no file path'
  end

  local root, e1 = git_fl({ 'rev-parse', '--show-toplevel' })
  if not root then
    return nil, 'Failed to detect git repo root: ' .. (e1 or 'unknown')
  end

  local rel, e2 = file_path_relative_to_root(root, file)
  if not rel then
    return nil, 'Failed to transform file path to relative: ' .. (e2 or 'unknown')
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  return { root = root, file = file, rel = rel, line = line }, nil
end

function M.copy_remote_url()
  local ctx, ctx_err = repo_ctx()
  if not ctx then
    vim.notify(ctx_err or 'unknown error while gathering repo context', vim.log.levels.ERROR)
    return
  end

  local remote_url, remote_url_err = git_remote()
  if not remote_url then
    vim.notify('Failed to detect git remote url: ' .. (remote_url_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local commit, commit_err = git_fl({ 'rev-parse', 'HEAD' })
  if not commit then
    vim.notify('Failed to find current commit: ' .. (commit_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  remote_url = normalize_remote(remote_url)
  local url = string.format(
    '%s/blob/%s/%s#L%d',
    remote_url,
    commit,
    urlencode(ctx.rel),
    ctx.line
  )
  copy(url)
end

function M.show_current_line_blame()
  local ctx, ctx_err = repo_ctx()
  if not ctx then
    vim.notify(ctx_err or 'unknown error while gathering repo context', vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local current_file_path = vim.api.nvim_buf_get_name(buf)
  if current_file_path == '' then
    vim.notify('Current buffer has no file path', vim.log.levels.ERROR)
    return
  end

  -- Explicit -C for when cwd != repo root
  local blame, blame_err = git({
    '-C', ctx.root,
    'blame', '--line-porcelain',
    '-L', ('%d,%d'):format(ctx.line, ctx.line),
    ctx.rel,
  })

  if not blame then
    vim.notify('Failed to run git blame: ' .. (blame_err or 'unknown'), vim.log.levels.ERROR)
    return
  end
  if #blame == 0 then
    vim.notify('No blame information available', vim.log.levels.WARN)
    return
  end

  local d = parse_blame(blame)
  if not d.commit then
    vim.notify('Failed to parse git blame output', vim.log.levels.ERROR)
    return
  end

  local msg = table.concat({
    format_commit(d.commit),
    d.author or 'Unknown author',
    format_time(d['author-time']) or 'Unknown time',
    d.summary or d.source or 'No summary',
  }, ' • ')
  vim.api.nvim_echo({ { msg, 'Normal' } }, false, {})
end

return M

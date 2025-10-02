local M = {}

local function git(args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(result, '\n')
  end
  return result, nil
end

local function git_remote()
  local remotes, err = git({ 'remote', 'get-url', 'origin' })
  if remotes and #remotes > 0 then
    return remotes[1], nil
  end
  -- no origin, try to get any remote
  local names, names_err = git({ 'remote' })
  if not names or names_err then
    return nil, names_err or 'no git remotes configured'
  end
  remotes, err = git({ 'remote', 'get-url', names[1] })
  if not remotes or err then
    return nil, err or 'failed to resolve git remote'
  end
  return remotes[1], nil
end

local function file_path_relative_to_root(root, file)
  local nroot = vim.fs.normalize(root)
  local nfile = vim.fs.normalize(file)
  if nfile:sub(1, #nroot) ~= nroot then
    return nil, 'file ' .. file .. ' is outside git repository ' .. nroot
  end

  local relative = nfile:sub(#nroot + 1, -1)
  if relative:sub(1, 1) == '/' or relative:sub(1, 1) == '\\' then
    return relative:sub(2)
  end
  return relative
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
  pcall(vim.fn.setreg, '+', text)
  pcall(vim.fn.setreg, '*', text)
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

local function format_commit(commit)
  if not commit then
    return 'N/A'
  end
  if commit == '0000000000000000000000000000000000000000' then
    return 'WORKTREE'
  end
  if commit:sub(1, 1) == '^' then
    commit = commit:sub(2)
  end
  if #commit >= 8 then
    return commit:sub(1, 8)
  end
  return commit
end

function M.copy_remote_url()
  local buf = vim.api.nvim_get_current_buf()
  local current_file_path = vim.api.nvim_buf_get_name(buf)
  if current_file_path == '' then
    vim.notify('Current buffer has no file path', vim.log.levels.ERROR)
    return
  end

  local remote_url, remote_url_err = git_remote()
  if not remote_url or remote_url_err then
    vim.notify('Failed to detect git remote url: ' .. (remote_url_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local commit, commit_err = git({ 'rev-parse', 'HEAD' })
  if not commit or commit_err then
    vim.notify('Failed to find current commit: ' .. (commit_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local git_root, git_root_err = git({ 'rev-parse', '--show-toplevel' })
  if not git_root or git_root_err then
    vim.notify('Failed to detect git repo root: ' .. (git_root_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local relative, relative_err = file_path_relative_to_root(git_root[1], current_file_path)
  if not relative or relative_err then
    vim.notify('Failed to transform file path to relative: ' .. (relative_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]

  local url_path = urlencode(relative)
  remote_url = normalize_remote(remote_url)
  local line_suffix = string.format('#L%d', line)

  local url = string.format('%s/blob/%s/%s%s', remote_url, commit[1], url_path, line_suffix)
  copy(url)
end

function M.show_current_line_blame()
  local buf = vim.api.nvim_get_current_buf()
  local current_file_path = vim.api.nvim_buf_get_name(buf)
  if current_file_path == '' then
    vim.notify('Current buffer has no file path', vim.log.levels.ERROR)
    return
  end

  local git_root, git_root_err = git({ 'rev-parse', '--show-toplevel' })
  if not git_root or git_root_err then
    vim.notify('Failed to detect git repo root: ' .. (git_root_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local relative, relative_err = file_path_relative_to_root(git_root[1], current_file_path)
  if not relative or relative_err then
    vim.notify('Failed to transform file path to relative: ' .. (relative_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]

  local blame, blame_err = git({ '-C', git_root[1], -- have to explicitly specify root here for cases where git_root != cwd
    'blame', '--line-porcelain', '-L', string.format('%d', line),
    relative })
  if not blame or blame_err then
    vim.notify('Failed to run git blame: ' .. (blame_err or 'unknown'), vim.log.levels.ERROR)
    return
  end

  if #blame == 0 then
    vim.notify('No blame information available', vim.log.levels.WARN)
    return
  end

  local data = parse_blame(blame)
  if not data.commit then
    vim.notify('Failed to parse git blame output', vim.log.levels.ERROR)
    return
  end

  local commit = format_commit(data.commit)
  local author = data.author or 'Unknown author'
  local authored_at = format_time(data['author-time']) or 'Unknown time'
  local summary = data.summary or data.source or 'No summary'
  local message = table.concat({ commit, author, authored_at, summary }, ' • ')
  vim.api.nvim_echo({ { message, 'Normal' } }, false, {})
end

return M

-- Set leader key to space
vim.g.mapleader = " "

-- Basic Neovim settings
vim.opt.number = true
vim.opt.relativenumber = true
-- Number of spaces that a <Tab> counts for
vim.opt.tabstop = 4
-- Number of spaces to use for each step of (auto)indent
vim.opt.shiftwidth = 4
-- Convert tabs to spaces
vim.opt.expandtab = true
-- Do smart autoindenting when starting a new line
vim.opt.smartindent = true
-- Don't wrap lines
vim.opt.wrap = false
-- Don't create swap files
vim.opt.swapfile = false
-- Don't create backup files
vim.opt.backup = false
-- Highlight search results
vim.opt.hlsearch = true
-- Show search matches as you type
vim.opt.incsearch = true
-- Enable 24-bit RGB color in the TUI
vim.opt.termguicolors = true
-- Minimal number of screen lines to keep above and below the cursor
vim.opt.scrolloff = 8
-- Faster completion (default is 4000ms)
vim.opt.updatetime = 50
-- Show a vertical line at column 80
vim.opt.colorcolumn = "120"

-- netrw
vim.g.netrw_liststyle = 3
vim.g.netrw_banner = 0
vim.g.netrw_winsize = 25


local lsp = require('lsp')
lsp.setup()

-- LSP keymaps
vim.keymap.set('n', 'gd', lsp.definition, { desc = 'Go to definition' })
vim.keymap.set('n', 'gr', lsp.references, { desc = 'Go to references' })
vim.keymap.set('n', 'gi', lsp.implementation, { desc = 'Go to implementation' })
vim.keymap.set('n', 'K', lsp.hover, { desc = 'Show documentation' })
vim.keymap.set('n', '<leader>d', lsp.diagnostics, { desc = 'Show diagnostics' })
local display = require('plugins.prelude.list_files.init')

vim.keymap.set('n', '<leader>ff', function()
    local cwd = vim.fn.getcwd()
    local files = {}

    -- Find all files in current directory (excluding hidden files)
    local handle = io.popen('find ' .. cwd .. ' -type d -name ".*" -prune -o -type f -print | sort')
    if handle then
        for file in handle:lines() do
            -- Convert to path relative to cwd
            local relative_path = file:sub(#cwd + 2)
            table.insert(files, { path = relative_path })
        end
        handle:close()
    end

    -- Open display with relative paths
    display.open(files, cwd)
end)

vim.bo.omnifunc = 'v:lua.vim.lsp.omnifunc'
vim.opt.pumheight = 10
vim.opt.pumwidth = 40
vim.opt.completeopt = { 'menuone', 'noselect', 'noinsert' }
vim.lsp.set_log_level('off')
vim.opt.shortmess:append('c')  -- Hide completion messages
-- Use <Tab> in insert mode to open completion
-- vim.keymap.set('i', '<Tab>', '<C-X><C-O>', { noremap = true })
-- Enhanced Tab key behavior
vim.keymap.set('i', '<Tab>', function()
  if vim.fn.pumvisible() == 1 then
    return "<C-n>"
  else
    local col = vim.fn.col('.') - 1
    if col == 0 or vim.fn.getline('.'):sub(col, col):match('%s') then
      return "<Tab>"
    else
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-X><C-O>', true, true, true), 'n')
    end
  end
end, { expr = true, noremap = true })
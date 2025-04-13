-- Set leader key to space
vim.g.mapleader = " "

-- Basic Neovim settings
vim.opt.number = true
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

vim.opt.smartcase = true
vim.opt.ignorecase = true
-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.opt.confirm = true

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- sync vim and system clipboard
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- netrw
vim.g.netrw_liststyle = 3
vim.g.netrw_banner = 0
vim.g.netrw_winsize = 25


local lsp = require('lsp')
lsp.setup()

-- LSP keymaps
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = 'Go to definition' })
vim.keymap.set('n', 'gr', vim.lsp.buf.references, { desc = 'Go to references' })
vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, { desc = 'Go to implementation' })
vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = 'Show documentation' })
vim.keymap.set('n', '<leader>d', vim.diagnostic.setqflist, { desc = 'Show diagnostics' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next diagnostic' })
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous diagnostic' })
vim.keymap.set('n', '<leader>cr', vim.lsp.buf.rename, { desc = 'Code action: Rename symbol' })
local display = require('plugins.prelude.list_files.init')

vim.keymap.set('n', '<leader>f', function()
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

vim.keymap.set('n', '<leader>g', ":copen | :silent :grep ", { desc = 'Toggle Grep Quickfix' })
vim.keymap.set('n', '<leader>q', function()
  local qf_winnr = vim.fn.getqflist({winid = 1}).winid
  if qf_winnr ~= 0 and vim.api.nvim_win_is_valid(qf_winnr) then
    vim.api.nvim_set_current_win(qf_winnr)
  end
end)
vim.keymap.set('n', '<leader>]q', ":cnext <CR>")
vim.keymap.set('n', '<leader>[q', ":cprevious <CR>")

vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.go",
  callback = function()
    -- Run gofumpt and update the buffer if formatting succeeded
    local filepath = vim.fn.expand("%:p")
    vim.fn.jobstart({ "gofumpt", "-w", filepath }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.schedule(function()
            -- Reload the file to apply changes
            vim.cmd("edit!")
          end)
        else
          vim.notify("gofumpt failed", vim.log.levels.ERROR)
        end
      end,
    })
  end,
})

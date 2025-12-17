-- speed up module loads
pcall(vim.loader.enable)

vim.opt.number = true
vim.opt.guicursor = ""
vim.opt.signcolumn = "yes"
vim.opt.winborder = "rounded"
vim.opt.wrap = false

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undodir = vim.fn.stdpath('state') .. '/undo'
vim.opt.undofile = true

vim.opt.autoindent = true
vim.opt.smartindent = true

vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true

vim.opt.hlsearch = true
vim.opt.incsearch = true

vim.opt.termguicolors = true

vim.opt.scrolloff = 8
vim.opt.updatetime = 50
vim.opt.colorcolumn = "120"

vim.opt.smartcase = true
vim.opt.ignorecase = true

vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.confirm = true   -- dialogs instead of failure on :q with changes
vim.opt.timeoutlen = 400 -- crisper <leader> keyfeel
vim.opt.cursorline = true

if vim.fn.has("clipboard") == 1 then
  vim.opt.clipboard = "unnamedplus"
end

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  callback = function()
    vim.highlight.on_yank()
  end,
})
vim.g.mapleader = " "

vim.keymap.set("n", "-", vim.cmd.Ex)
vim.keymap.set('n', 'F', vim.lsp.buf.format)

local git_utils = require('git_utils')
vim.keymap.set('n', '<leader>cr', git_utils.copy_remote_url, { desc = 'Copy remote repository link' })
vim.keymap.set('n', '<leader>gb', git_utils.show_current_line_blame, { desc = 'Show git blame for current line' })

vim.keymap.set("x", "<leader>p", [["_dP]])       -- replace without yanking replaced text
vim.keymap.set({ "n", "v" }, "<leader>d", '"_d') -- delete without yanking
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "remove search highlighting" })

-- Quickfix navigation
vim.keymap.set("n", "<C-k>", "<cmd>cnext<CR>zz")
vim.keymap.set("n", "<C-j>", "<cmd>cprev<CR>zz")

--local picker = require('picker')
--vim.keymap.set('n', '<leader>ff', picker.files, { desc = 'Find file' })

-- insert if err != nil {return err}
vim.keymap.set("n", "<leader>ee", "oif err != nil {<CR>}<Esc>Oreturn err<Esc>bi")

-- transform func name(arg1 string, arg2 string) in to
-- func name(
--   arg1 string,
--   arg2 string,
-- )
vim.keymap.set("x", "<leader>as",
  [[:s/\%V,\s*/__SPLIT_ARGUMENTS__/g<CR>:'<,'>s/(/(\r/<CR>:s/__SPLIT_ARGUMENTS__/,\r/g<CR>]],
  { desc = "Split args on commas (visual)" })

vim.cmd [[set completeopt+=menuone,noselect,popup]]

local function setup_blink()
  require("blink.cmp").setup({
    keymap = { preset = "super-tab" },
    signature = { enabled = true },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 500 },
      menu = {
        auto_show = true,
        draw = {
          columns = { { "kind_icon", "label", "label_description", gap = 1 }, { "kind" } },
        },
      },
    },
    fuzzy = { implementation = 'lua' },
  })
end

local function setup_lsp()
  local lsps = {
    "lua_ls",
    "gopls",          -- go install golang.org/x/tools/gopls@latest
    "rust_analyzer",  -- rustup component add rust-src
    "pyright",        -- npm i -g pyright
    "ts_ls",          -- npm i -g typescript typescript-language-server
    "jsonls", "html", -- npm i -g vscode-langservers-extracted
    -- "htmx",           -- cargo install htmx-lsp
    --"tsgo",           -- npm install @typescript/native-preview
    "ols", -- https://github.com/DanielGavin/ols?tab=readme-ov-file#installation
    "zls",
  }
  vim.lsp.enable(lsps)
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(ev)
      local bufopts = { noremap = true, silent = true, buffer = ev.buf }
      vim.keymap.set("n", "gd", function() vim.lsp.buf.definition() end, bufopts)
    end,
  })
end

local function setup_ts()
  require("nvim-treesitter.configs").setup({
    ensure_installed = {
      "lua", "vim", "vimdoc", "regex",
      "go", "gomod", "gosum",
      "bash", "json", "jsonc", "yaml", "toml",
      "markdown", "markdown_inline",
      "python", "rust", "typescript", "tsx",
    },
    auto_install = true,
    highlight = { enable = true, additional_vim_regex_highlighting = false },
    indent = { enable = true },
  })
end

local function setup_minipick()
  local pick = require('mini.pick')
  pick.setup()
  vim.keymap.set('n', '<leader>ff', ':Pick files<CR>')
  vim.keymap.set('n', '<leader>fg', ':Pick grep_live<CR>')
  vim.keymap.set('n', '<leader>fh', ':Pick help<CR>')
end

vim.pack.add({
  { src = 'https://github.com/neovim/nvim-lspconfig' },
  { src = "https://github.com/Saghen/blink.cmp" },
  { src = 'https://github.com/nvim-mini/mini.pick' },
  { src = "https://github.com/nvim-treesitter/nvim-treesitter", version = 'master' },
})
setup_minipick()
setup_blink()
setup_ts()
setup_lsp()

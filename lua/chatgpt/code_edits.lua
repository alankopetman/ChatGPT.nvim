local M = {}

local Layout = require("nui.layout")
local Popup = require("nui.popup")

local ChatInput = require("chatgpt.input")
local Api = require("chatgpt.api")
local Config = require("chatgpt.config")
local Utils = require("chatgpt.utils")
local Spinner = require("chatgpt.spinner")
local Settings = require("chatgpt.settings")

local namespace_id = vim.api.nvim_create_namespace("ChatGPTNS")

local instructions_input, layout, input_window, output_window, output, timer, filetype, bufnr, extmark_id

local display_input_suffix = function(suffix)
  if extmark_id then
    vim.api.nvim_buf_del_extmark(instructions_input.bufnr, namespace_id, extmark_id)
  end

  if not suffix then
    return
  end

  extmark_id = vim.api.nvim_buf_set_extmark(instructions_input.bufnr, namespace_id, 0, -1, {
    virt_text = {
      { "", "ChatGPTTotalTokensBorder" },
      { "" .. suffix, "ChatGPTTotalTokens" },
      { "", "ChatGPTTotalTokensBorder" },
      { " ", "" },
    },
    virt_text_pos = "right_align",
  })
end

local spinner = Spinner:new(function(state)
  vim.schedule(function()
    output_window.border:set_text("top", " " .. state .. " ", "center")
    display_input_suffix(state)
  end)
end, {
  text = Config.options.loading_text,
})

local show_progress = function()
  spinner:start()
end

local hide_progress = function()
  spinner:stop()
  display_input_suffix()
  output_window.border:set_text("top", " Result ", "center")
end

local setup_and_mount = vim.schedule_wrap(function(lines)
  layout:mount()
  -- set input
  vim.api.nvim_buf_set_lines(input_window.bufnr, 0, -1, false, lines)

  -- set input and output settings
  for _, window in ipairs({ input_window, output_window }) do
    vim.api.nvim_buf_set_option(window.bufnr, "filetype", filetype)
    vim.api.nvim_win_set_option(window.winid, "number", true)
  end
end)

M.edit_with_instructions = function()
  local winnr = vim.api.nvim_get_current_win()
  bufnr = vim.api.nvim_win_get_buf(winnr)
  filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")

  local visual_lines, start_row, start_col, end_row, end_col = Utils.get_visual_lines(bufnr)
  local openai_params = Config.options.openai_edit_params
  local settings_panel = Settings.get_settings_panel("edits", openai_params)
  input_window = Popup(Config.options.chat_window)
  output_window = Popup(Config.options.chat_window)
  instructions_input = ChatInput(Config.options.chat_input, {
    prompt = Config.options.chat_input.prompt,
    on_close = function()
      if timer ~= nil then
        timer:stop()
      end
    end,
    on_submit = vim.schedule_wrap(function(instruction)
      -- clear input
      vim.api.nvim_buf_set_lines(instructions_input.bufnr, 0, -1, false, { "" })
      show_progress()

      local input = table.concat(vim.api.nvim_buf_get_lines(input_window.bufnr, 0, -1, false), "\n")
      local params = vim.tbl_extend("keep", { input = input, instruction = instruction }, Settings.params)
      Api.edits(params, function(output_txt, usage)
        hide_progress()
        local nlcount = Utils.count_newlines_at_end(input)
        local output_txt_nlfixed = Utils.replace_newlines_at_end(output_txt, nlcount)
        output = Utils.split_string_by_line(output_txt_nlfixed)

        vim.api.nvim_buf_set_lines(output_window.bufnr, 0, -1, false, output)
        display_input_suffix(usage.total_tokens)
      end)
    end),
  })

  layout = Layout(
    Config.options.chat_layout,
    Layout.Box({
      Layout.Box({
        Layout.Box(input_window, { grow = 1 }),
        Layout.Box(instructions_input, { size = 3 }),
      }, { dir = "col", size = "50%" }),
      Layout.Box(output_window, { size = "50%" }),
    }, { dir = "row" })
  )

  instructions_input:map("i", Config.options.keymaps.yank_last, function()
    instructions_input.input_props.on_close()
    vim.api.nvim_buf_set_text(bufnr, start_row - 1, start_col - 1, end_row - 1, end_col, output)
    vim.notify("Successfully applied the change!", vim.log.levels.INFO)
  end, { noremap = true })

  instructions_input:map("i", "<C-i>", function()
    local lines = vim.api.nvim_buf_get_lines(output_window.bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(input_window.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_lines(output_window.bufnr, 0, -1, false, {})
  end, { noremap = true })

  -- toggle settings
  local settings_open = false
  for _, popup in ipairs({ settings_panel, instructions_input }) do
    for _, mode in ipairs({ "n", "i" }) do
      popup:map(mode, Config.options.keymaps.toggle_settings, function()
        if settings_open then
          layout:update(Layout.Box({
            Layout.Box({
              Layout.Box(input_window, { grow = 1 }),
              Layout.Box(instructions_input, { size = 3 }),
            }, { dir = "col", size = "50%" }),
            Layout.Box(output_window, { size = "50%" }),
          }, { dir = "row" }))
          settings_panel:hide()
          vim.api.nvim_set_current_win(instructions_input.winid)
        else
          layout:update(Layout.Box({
            Layout.Box({
              Layout.Box(input_window, { grow = 1 }),
              Layout.Box(instructions_input, { size = 3 }),
            }, { dir = "col", grow = 1 }),
            Layout.Box(output_window, { grow = 1 }),
            Layout.Box(settings_panel, { size = 40 }),
          }, { dir = "row" }))
          settings_panel:show()
          settings_panel:mount()

          vim.api.nvim_set_current_win(settings_panel.winid)
          vim.api.nvim_buf_set_option(settings_panel.bufnr, "modifiable", false)
          vim.api.nvim_win_set_option(settings_panel.winid, "cursorline", true)
        end
        settings_open = not settings_open
        -- set input and output settings
        --  TODO
        for _, window in ipairs({ input_window, output_window }) do
          vim.api.nvim_buf_set_option(window.bufnr, "filetype", filetype)
          vim.api.nvim_win_set_option(window.winid, "number", true)
        end
      end, {})
    end
  end

  -- toggle panes
  local active_panel = instructions_input
  for _, popup in ipairs({ settings_panel, instructions_input }) do
    for _, mode in ipairs({ "n", "i" }) do
      popup:map(mode, Config.options.keymaps.cycle_windows, function()
        if active_panel == settings_panel then
          vim.api.nvim_set_current_win(instructions_input.winid)
          active_panel = instructions_input
        else
          vim.api.nvim_set_current_win(settings_panel.winid)
          vim.api.nvim_buf_set_option(settings_panel.bufnr, "modifiable", false)
          vim.api.nvim_win_set_option(settings_panel.winid, "cursorline", true)
          active_panel = settings_panel
        end

        -- TODO
        -- set input and output settings
        for _, window in ipairs({ input_window, output_window }) do
          vim.api.nvim_buf_set_option(window.bufnr, "filetype", filetype)
          vim.api.nvim_win_set_option(window.winid, "number", true)
        end
      end, {})
    end
  end

  setup_and_mount(visual_lines)
end

return M

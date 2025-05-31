local LABEL_KEYS = "asdfghjklqwertyuiopzxcvbnmABCDEFGHIJKLMNOPQRSTUVWXYZ"
local INPUT_KEYS = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
	"a",
	"b",
	"c",
	"d",
	"e",
	"f",
	"g",
	"h",
	"i",
	"j",
	"k",
	"l",
	"m",
	"n",
	"o",
	"p",
	"q",
	"r",
	"s",
	"t",
	"u",
	"v",
	"w",
	"x",
	"y",
	"z",
	"0",
	"1",
	"2",
	"3",
	"4",
	"5",
	"6",
	"7",
	"8",
	"9",
	"-",
	"_",
	".",
	"<Esc>",
	"<Space>",
	"<Enter>",
	"<Backspace>",
}

local INPUT_CANDS = {}
for _, k in ipairs(INPUT_KEYS) do
	INPUT_CANDS[#INPUT_CANDS + 1] = { on = k }
end

-- NOTE: Safely get highlight group hex (nil if not available)
local function hl_hex(group, kind)
	if not (vim and vim.api and vim.api.nvim_get_hl_by_name) then
		return nil
	end
	local ok, tbl = pcall(vim.api.nvim_get_hl_by_name, group, true)
	if not ok or type(tbl) ~= "table" or not tbl[kind] then
		return nil
	end
	return string.format("#%06x", tbl[kind])
end

-- Toggle literal vs. regex matching
local set_regex = ya.sync(function(s, f)
	s.r = f
end)
local get_regex = ya.sync(function(s)
	return s.r
end)

-- INFO: Find all match positions (literal or regex) in lowercase
local function find_pos(name, pat)
	if not pat or pat == "" then
		return nil, nil
	end
	name, pat = name:lower(), pat:lower()
	local st, en = {}, {}
	local i = 1
	if not get_regex() then
		while true do
			local s, e = string.find(name, pat, i, true)
			if not s then
				break
			end
			st[#st + 1], en[#en + 1] = s, e
			i = e + 1
		end
	else
		while true do
			local s, e = string.find(name, pat, i)
			if not s then
				break
			end
			st[#st + 1], en[#en + 1] = s, e
			i = e + 1
		end
	end
	return (#st > 0) and st or nil, (#en > 0) and en or nil
end

-- INFO: Return first label from s.matches
local first_label = ya.sync(function(s)
	if not s.matches then
		return nil
	end
	for _, info in pairs(s.matches) do
		if #info.keys > 0 then
			return info.keys[1]
		end
	end
	return nil
end)

-- INFO: Build highlight spans + labels for a filename
local function build_spans(url, name, file, s)
	local info = s.matches[url]
	local st, en, keys = info.st, info.en, info.keys
	local spans = {}
	if file.is_hovered then
		spans[#spans + 1] = ui.Span(name:sub(1, st[1] - 1))
	else
		spans[#spans + 1] = ui.Span(name:sub(1, st[1] - 1)):fg(s.col_unm)
	end
	for i = 1, #st do
		spans[#spans + 1] = ui.Span(name:sub(st[i], en[i])):fg(s.col_mfg):bg(s.col_mbg)
		if keys[i] then
			spans[#spans + 1] = ui.Span(keys[i]):fg(s.col_lfg):bg(s.col_lbg)
		end
		local next_start = (i < #st and st[i + 1] - 1) or #name
		local seg_start = en[i] + 1
		if seg_start <= next_start then
			local seg = name:sub(seg_start, next_start)
			if file.is_hovered then
				spans[#spans + 1] = ui.Span(seg)
			else
				spans[#spans + 1] = ui.Span(seg):fg(s.col_unm)
			end
		end
	end
	return spans
end

-- INFO: Scan one pane for matches
local function scan_pane(pane, folder, pat, s)
	if not folder then
		return
	end
	for idx, file in ipairs(folder.window) do
		local fname = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		local st, en = find_pos(fname, pat)
		if st then
			s.matches[url] = {
				st = st,
				en = en,
				keys = {},
				is_dir = file.cha.is_dir,
				pane = pane,
				cur = idx,
			}
		end
	end
end

-- INFO: Record matches across panes and assign labels
local record_matches = ya.sync(function(s, patterns)
	s.matches = {}
	local found = false
	for _, pat in ipairs(patterns) do
		scan_pane("current", cx.active.current, pat, s)
		if not s.only_current then
			scan_pane("parent", cx.active.parent, pat, s)
			scan_pane("preview", cx.active.preview.folder, pat, s)
		end
	end
	-- Build valid label list
	local valid = {}
	for i = 1, #LABEL_KEYS do
		local c = LABEL_KEYS:sub(i, i)
		if s.enable_caps or c:byte() > 96 then
			valid[#valid + 1] = c
		end
	end
	-- Assign labels
	local idx = 1
	for url, info in pairs(s.matches) do
		found = true
		for _ = 1, #info.st do
			info.keys[#info.keys + 1] = valid[idx]
			idx = idx + 1
		end
	end
	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
	ya.render()
	return found
end)

-- INFO: Toggle highlighting on/off
local toggle_ui = ya.sync(function(s)
	if s.on then
		Status:children_remove(s.status_id)
		Entity.highlights = s.old_hl
		s.on, s.status_id = nil, nil
		if cx.active.preview.folder then
			ya.mgr_emit("peek", { force = true })
		end
		ya.render()
		return
	end
	s.old_hl = Entity.highlights
	s.on = true
	Entity.highlights = function(self)
		local file = self._file
		local name = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		if s.matches and s.matches[url] then
			return ui.Line(build_spans(url, name, file, s))
		elseif file.is_hovered then
			return ui.Line({ ui.Span(name) })
		else
			return ui.Line({ ui.Span(name):fg(s.col_unm) })
		end
	end
	local function status_line()
		local style = Status:style()
		local txt = ""
		if s.search_pat ~= "" and s.show_status then
			txt = ":" .. s.search_pat
		end
		return ui.Line({ ui.Span("[SJ]" .. txt .. " "):style(style.main) })
	end
	s.status_id = Status:children_add(status_line, 1001, Status.LEFT)
	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
end)

-- NOTE: Return URL if key matches a label
local match_label = ya.sync(function(s, key)
	if s.backsp then
		s.backsp = nil
		return nil
	end
	if not s.matches then
		return nil
	end
	for url, info in pairs(s.matches) do
		for _, lbl in ipairs(info.keys) do
			if lbl == key then
				return url
			end
		end
	end
	return nil
end)

-- INFO: Handle one keypress: jump or re‐scan
local handle_input = ya.sync(function(s, patterns, key)
	local url = match_label(key)
	if url then
		local info = s.matches[url]
		if not s.autocd and info.pane == "current" then
			local f = cx.active.current
			local off = info.cur - f.cursor - 1 + f.offset
			ya.mgr_emit("arrow", { off })
		elseif s.autocd and info.is_dir then
			ya.mgr_emit("cd", { url })
		else
			ya.mgr_emit("reveal", { url })
		end
		return true, true
	end
	s.matches = nil
	local found = record_matches(patterns)
	ya.render()
	if not found and (s.r or patterns[1] ~= "") and s.auto_exit then
		return true, found
	end
	return false, found
end)

-- INFO: Clear transient state
local clear_state = ya.sync(function(s)
	s.matches = nil
	s.backsp = nil
	s.search_pat = ""
	ya.render()
end)

-- INFO: Initialize defaults and fetch Flash.nvim colors
local set_defaults = ya.sync(function(s)
	s.col_mfg = hl_hex("FlashMatch", "foreground") or "#000000"
	s.col_mbg = hl_hex("FlashMatch", "background") or "#FFD700"
	s.col_lfg = hl_hex("FlashLabel", "foreground") or "#FFFFFF"
	s.col_lbg = hl_hex("FlashLabel", "background") or "#FF0000"
	s.col_unm = hl_hex("FlashBackdrop", "foreground") or "#888888"
	s.only_current = s.only_current or false
	s.search_pat = ""
	s.show_status = s.show_status or false
	s.auto_exit = (s.auto_exit == nil) and true or s.auto_exit
	s.enable_caps = s.enable_caps or false
	return s.search_pat
end)

-- FIX: Backspace handler
local backspace = ya.sync(function(s, cur)
	local last = cur:sub(-2, -2)
	local nxt = cur:sub(1, -2)
	s.backsp = true
	s.search_pat = nxt
	ya.render()
	return nxt, last
end)

-- INFO: Update status‐bar text
local update_status = ya.sync(function(s, cur)
	s.search_pat = get_regex() and "[~]" or cur
	ya.render()
end)

-- INFO: Parse “autocd” arg
local parse_args = ya.sync(function(s, args)
	s.autocd = (args[1] == "autocd")
end)

return {
	setup = function(s, opts)
		if opts then
			if opts.only_current ~= nil then
				s.only_current = opts.only_current
			end
			if opts.show_status ~= nil then
				s.show_status = opts.show_status
			end
			if opts.auto_exit ~= nil then
				s.auto_exit = opts.auto_exit
			end
			if opts.enable_caps ~= nil then
				s.enable_caps = opts.enable_caps
			end
		end
	end,

	entry = function(_, job)
		set_defaults()
		parse_args(job.args)
		toggle_ui()

		local cur = ""
		local patterns = {}
		local last_key = ""

		while true do
			local cand = ya.which({ cands = INPUT_CANDS, silent = true })
			if not cand then
				goto cont
			end

			local key = INPUT_KEYS[cand]
			if key == "<Esc>" then
				break
			elseif key == "<Enter>" then
				last_key = first_label()
				patterns = { "" }
			elseif key == "<Space>" then
				last_key = ""
				cur = ""
				patterns = { "" }
				set_regex(true)
			elseif key == "<Backspace>" then
				cur, last_key = backspace(cur)
				patterns = { cur }
				set_regex(false)
			else
				last_key = key
				cur = cur .. string.lower(key)
				patterns = { cur }
				set_regex(false)
			end

			::reset::
			update_status(cur)
			local exit_loop, found = handle_input(patterns, last_key)
			if exit_loop then
				break
			end

			if not found and get_regex() then
				break
			elseif not found and cur ~= "" then
				cur, last_key = backspace(cur)
				patterns = { cur }
				goto reset
			end

			::cont::
		end

		clear_state()
		toggle_ui()
	end,
}

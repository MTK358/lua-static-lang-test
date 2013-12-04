
setmetatable(_G, {
	__index = function (t, k)
		error('get global varaible: ' .. k, 2)
	end;
	__newindex = function (t, k, v)
		error('set global varaible: ' .. k, 2)
	end;
})

local parse = require 'parser'
local read_types = require 'read_types'
local check_types = require 'check_types'
local expr_to_stat = require 'expr_to_stat'
local codegen = require 'lua_codegen'

local function compile(istream, ostream)
	if type(istream) == 'string' then
		istream = istream:gmatch('.')
	end

	local s = {
		raw_line = 1,
		raw_col = 0,
	}

	function s.getch()
		s.ch = istream()
		if s.ch == '\n' then
			s.raw_line, s.raw_col = s.raw_line + 1, 0
		else
			s.raw_col = s.raw_col + 1
		end
	end

	local error_tbl = {}

	function s.error(msg, cont, line, col)
		error_tbl.msg = msg
		error_tbl.cont = cont and true or false
		error_tbl.line = line or s.line
		error_tbl.col = col or s.col
		error(error_tbl)
	end

	local next_tmp_id = 0
	function s.tmp_name()
		local n = '____tmp_' .. next_tmp_id
		next_tmp_id = next_tmp_id + 1
		return n
	end

	function s.throwaway_name()
		return '____tmp_discarded'
	end

	local success, result = xpcall(function ()
		s.getch()
		local ast = parse(s)
		ast = read_types(s, ast)
		ast = check_types(s, ast)
		ast = expr_to_stat(s, ast)
		return ast
	end, function (e)
		return {e, debug.traceback('', 2)}
	end)

	if success then
		codegen(result, ostream)
		return true
	else
		if result[1] == error_tbl then
			return nil, error_tbl
		else
			error(result[1] .. '\n' .. result[2])
		end
	end
end


local ifile = arg[1] and assert(io.open(arg[1])) or io.stdin
local function istream()
	return ifile:read(1)
end

local out = {}
local function ostream(s)
	out[#out +1] = s
end

local success, err = compile(istream, ostream)

if success then
	print(table.concat(out))
else
	print(('compilation error: %d:%d: %s'):format(err.line, err.col, err.msg))
end



local M = {}

local node_mt = {}
node_mt.__index = node_mt

function M.new_node(s, node, ...)
	return setmetatable({
		line = s.line, col = s.col,
		node,
		...
	}, node_mt)
end

function node_mt:get_location()
	if self.line then
		return self.line, self.col
	end
	return '?', '?'
end

M.node_types = {
	['float'] = true,
	['int'] = true,
	['string'] = true,
	['bool'] = true,
	['nil'] = true,
	['if'] = true,
	['while'] = true,
	['repeat'] = true,
	['do'] = true,
	['seq'] = true,
	['comma'] = true,
	['tuple'] = true,
	['local'] = true,
	['assign'] = true,
	['binop'] = true,
	['unop'] = true,
	['function'] = true,
	['call'] = true,
}

function M.assert_all_node_types_handled(tbl)
	for k, v in pairs(M.node_types) do
		if not tbls[k] then
			error(('table does not handle node type `%s`'):format(k))
		end
	end
	for k, v in pairs(tbl) do
		if not M.node_types[k] then
			error(('table handles non-existant node type `%s`'):format(k))
		end
	end
end

return M

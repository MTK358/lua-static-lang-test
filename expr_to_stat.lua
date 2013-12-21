
------------------------------------------------------------------------------
-- Make the type-checked expression tree compatible with Lua. There are two
-- reasons why the tree can't be converted directly:
--
-- 1. Lua doesn't have static types and doesn't know about pass-by-value
--    structures.
--
-- 2. Lua's syntax differentiates between statements and expressions, and is
--    strict about not letting one be used where the other is expected.
--
-- To solve the first problem, structures need to be expanded to multiple
-- variables/function parameters/return values, one for each field in the
-- structure (and any substructures).
--
-- For the second problem, nodes that Lua treats as "statements" used in an
-- "expression" context should be moved to their own statement before the
-- current one, possibly using temporary varaibles to pass a result value.
-- Cases like loops being used as function parameters do not need to be
-- handled, since the type system should not allow it in the first place.
------------------------------------------------------------------------------

local types = require 'types'

local e2s_statement, e2s_expression, e2s_vsfield
local e2s_statement_tbl, e2s_expression_tbl, e2s_vsfield_tbl

------------------------------------------------------------------------------
-- handle a node used in a statement context
-- parameters:
--   node: the original node
-- returns:
--   the replacement node
------------------------------------------------------------------------------

e2s_statement = function (s, node)
	local f = e2s_statement_tbl[node[1]]
	if not f then
		error('e2s_statement node not handled: '..node[1])
	end
	return f(s, node)
end

local function dummy_statement(s, node)
	return {'if', node, {'seq'}}
end

e2s_statement_tbl = {
	['seq'] = function (s, node)
		for i = 2, #node do
			node[i] = e2s_statement(s, node[i])
		end
		return node
	end;

	['comma'] = function (s, node)
		node[1] = 'seq'
		for i = 2, #node do
			node[i] = e2s_statement(s, node[i])
		end
		return node
	end;

	['call'] = function (s, node)
		local _, replacement = e2s_expression(s, node, node, true)
		return replacement
	end;

	['local'] = function (s, node)
		local new_init, replacement = e2s_expression(s, node[4], node, true)
		node[2], replacement = e2s_expression(s, node[2], replacement, false)
		node[4] = new_init
		if replacement ~= node then
			replacement = {'seq', {'local', node[2]}, replacement}
			node[1] = 'assign'
		end
		return replacement
	end;

	['binop'] = function (s, node)
		local new_stat = {'if', node, {'seq'}}
		new_stat[2], new_stat = e2s_expression(s, node, new_stat)
		return new_stat
	end;

	['unop'] = function (s, node)
		local new_stat = {'if', node, {'seq'}}
		new_stat[2], new_stat = e2s_expression(s, node, new_stat)
		return new_stat
	end;

	['return'] = function (s, node)
		local new_stat = node
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		return new_stat
	end;

	['function'] = function (s, node)
		local new_stat = {'if', node, {'seq'}}
		new_stat[2], new_stat = e2s_expression(s, node, new_stat, true)
		return new_stat
	end;

	['if'] = function (s, node)
		local new_stat = node
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		node[3] = e2s_statement(s, node[3])
		if node[4] then
			node[4] = e2s_statement(s, node[4])
		end
		return new_stat
	end;

	['while'] = function (s, node)
		local new_stat = node
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		node[3] = e2s_statement(s, node[3])
		return new_stat
	end;

	['repeat'] = function (s, node)
		node[2] = e2s_statement(s, node[2])
		local new_stat = node
		node[3], new_stat = e2s_expression(s, node[3], new_stat, true)
		return new_stat
	end;

	['do'] = function (s, node)
		node[2] = e2s_statement(s, node[2])
		return node
	end;

	['parens'] = function (s, node)
		return e2s_statement(s, node[2])
	end;

	['assign'] = function (s, node)
		local new_stat = node
		node[2], new_stat = e2s_expression(s, node[2], new_stat, false)
		node[4], new_stat = e2s_expression(s, node[4], new_stat, true)
		return new_stat
	end;

	['new_variant'] = function (s, node)
		return {'void'}
	end;

	['vararg'] = dummy_statement,
	['float'] = dummy_statement,
	['int'] = dummy_statement,
	['string'] = dummy_statement,
	['boolean'] = dummy_statement,
	['nil'] = dummy_statement,
	['void'] = function (s, node) return node end,
}

------------------------------------------------------------------------------
-- handle a node used in an expression context
-- parameters:
--   node: the original node
--   stat: the statement containing `node`
--   multret_expanded: true if the results of this expression are used in a
--                     place where multiple function returns are not adjusted
--                     to 1 value
-- returns:
--   the replacement node
--   the replacement statement
------------------------------------------------------------------------------

e2s_expression = function (s, node, stat, multret_expanded)
	local f = e2s_expression_tbl[node[1]]
	if not f then
		error('e2s_expression node not handled: '..node[1])
	end
	return f(s, node, stat, multret_expanded)
end

local function expr_noop(s, node, stat, multret_expanded)
	return node, stat
end

e2s_expression_tbl = {
	['seq'] = function (s, node, stat, multret_expanded)
		local count = #node
		for i = 2, count-1 do
			node[i] = e2s_statement(s, node[i])
		end
		local new_expr
		new_expr, node[count] = e2s_expression(s, node[count], stat, multret_expanded)
		return new_expr, node
	end;

	['if'] = function (s, node, stat, multret_expanded)
		local new_expr, new_stat
		--if stat[1] == 'return' and stat[2] == node then
			--new_stat = node
			--node[3] = {'return', node[3]}
			--node[4] = {'return', node[4] or {'void'}}
		--elseif stat[1] == 'assign' and stat[4] == node then
		--elseif stat[1] == 'local' and stat[4] == node then
		--else
			local tmp_var
			if node.ty.valstruct then
				tmp_var = {'comma'}
				for i = 1, node.ty.valstruct.num_vars do
					tmp_var[i+1] = {'name', s.tmp_name()}
				end
			else
				tmp_var = {'name', s.tmp_name()}
			end
			new_expr = tmp_var
			new_stat = {'do', {'seq', {'local', tmp_var}, node, stat}}
			node[3] = {'assign', tmp_var, nil, node[3]}
			node[4] = {'assign', tmp_var, nil, node[4]}
		--end
		node[3][4], node[3] = e2s_expression(s, node[3][4], node[3], true)
		node[4][4], node[4] = e2s_expression(s, node[4][4], node[4], true)
		node[2], new_stat = e2s_expression(s, node[2], new_stat)
		return new_expr, new_stat
	end;

	['while'] = function (s, node, stat, multret_expanded)
		return {'void'}, {'seq', node, stat}
	end;

	['repeat'] = function (s, node, stat, multret_expanded)
		return {'void'}, {'seq', node, stat}
	end;

	['do'] = function (s, node, stat, multret_expanded)
		if node.ty == types.builtin_void then
			return {'void'}, {'seq', node, stat}
		else
			local tmp_var
			if node.ty.valstruct then
				tmp_var = {'comma'}
				for i = 1, node.ty.valstruct.num_vars do
					tmp_var[i+1] = {'name', s.tmp_name()}
				end
			else
				tmp_var = {'name', s.tmp_name()}
			end
			local new_stat = {'do', {'seq', {'local', tmp_var}, node, stat}}
			node[2] = {'assign', tmp_var, nil, node[2]}
			node[2][4], node[2] = e2s_statement(s, node[2][4], node[2], true)
			return tmp_var, new_stat
		end
	end;

	['comma'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		local count = #node
		for i = 2, count do
			node[i], new_stat = e2s_expression(s, node[i], new_stat, multret_expanded and i==count)
		end
		return node, new_stat
	end;

	['tuple'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		for i = 2, #node do
			node[i], new_stat = e2s_expression(s, node[i], new_stat)
		end
		node[1] = 'comma'
		return node, new_stat
	end;

	['call'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		node[2], new_stat = e2s_expression(s, node[2], new_stat)
		local count = #node
		for i = 3, count do
			node[i], new_stat = e2s_expression(s, node[i], new_stat, i==count)
		end
		if node.ty.valstruct and not multret_expanded then
			local tmp_vars = {'comma'}
			for i = 1, node.ty.valstruct.num_vars do
				tmp_vars[i+1] = {'name', s.tmp_name()}
			end
			new_stat = {'do', {'seq', {'local', tmp_vars, nil, node}, new_stat}}
			return tmp_vars, new_stat
		end
		return node, new_stat
	end;

	['function'] = function (s, node, stat, multret_expanded)
		node[2].lua = {}
		for i, v in ipairs(node[2]) do
			if v.var and v.var.expanded_replacement then
				for j = 2, #v.var.expanded_replacement do
					table.insert(node[2].lua, v.var.expanded_replacement[j][2])
				end
			else
				table.insert(node[2].lua, v.name)
			end
		end
		if node[2].vararg then
			table.insert(node[2].lua, '...')
		end
		node[4] = e2s_statement(s, node[4])
		return node, stat
	end;

	['binop'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		node[3], new_stat = e2s_expression(s, node[3], new_stat)
		node[4], new_stat = e2s_expression(s, node[4], new_stat)
		return node, new_stat
	end;

	['unop'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		node[3], new_stat = e2s_expression(s, node[3], new_stat)
		return node, new_stat
	end;

	['table'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		for i = 2, #node do
			local n = node[i]
			if n then
				node[i], new_stat = e2s_expression(s, n, new_stat)
			end
		end
		return node, new_stat
	end;

	['name'] = function (s, node, stat, multret_expanded)
		if node.var.expanded_replacement then
			return node.var.expanded_replacement, stat
		end
		return node, stat
	end;

	['field'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		if node.ty.valstruct then
			local container_var = {'name', s.tmp_name()}
			new_stat = {'do', {'seq', {'local', container_var, nil, node}, new_stat}}
			local new_node = {'comma'}
			for i = 1, node.ty.valstruct.num_vars do
				new_node[i+1] = {'num_field', container_var, i}
			end
			return new_node, new_stat
		end
		return node, new_stat
	end;

	['num_field'] = function (s, node, stat, multret_expanded)
		local new_stat = stat
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		if node.ty.valstruct then
			local container_var = node[2]
			if container_var[1] ~= 'name' then
				container_var = {'name', s.tmp_name()}
				new_stat = {'do', {'seq', {'local', container_var, nil, node[2]}, new_stat}}
			end
			local new_node = {'comma'}
			for i = node[3], node[3]+node.ty.valstruct.num_vars-1 do
				table.insert(new_node, {'num_field', container_var, i})
			end
			return new_node, new_stat
		end
		return node, new_stat
	end;

	['valstruct_field'] = function (s, node, stat, multret_expanded)
		return e2s_vsfield(s, node[2], stat, multret_expanded, node[3])
	end;

	['parens'] = function (s, node, stat, multret_expanded)
		if node[2].ty == types.builtin_vararg then
			local new_stat = stat
			node[2], new_stat = e2s_expression(s, node[2], stat, multret_expanded)
			return node, new_stat
		else
			return e2s_expression(s, node[2], stat, multret_expanded)
		end
	end;

	['new_variant'] = function (s, node, stat, multret_expanded)
		local v = node.ty.valstruct
		local idx = v.name_to_index[node[3]]
		local new_expr, new_stat = {'comma', {'int', idx}}, stat
		if v.members[idx] ~= types.builtin_void then
			if node[4].ty:num_vars() ~= node.ty:num_vars() - 1 then
				multret_expanded = false
			end
			new_expr[3], new_stat = e2s_expression(s, node[4], new_stat, multret_expanded)
			for i = node[4].ty:num_vars(), node.ty:num_vars()-2 do
				table.insert(new_expr, {'nil'})
			end
		else
			for i = 2, node.ty:num_vars() do
				table.insert(new_expr, {'nil'})
			end
		end
		return new_expr, new_stat
	end;

	['vararg'] = expr_noop,
	['float'] = expr_noop,
	['int'] = expr_noop,
	['string'] = expr_noop,
	['boolean'] = expr_noop,
	['nil'] = expr_noop,
	['void'] = expr_noop,
}

------------------------------------------------------------------------------
-- handle getting a field from a pass-by-value structure stored in different
-- kinds of locations
-- parameters:
--   node: the original node
--   stat: the statement containing `node`
--   multret_expanded: true if the results of this expression are used in a
--                     place where multiple function returns are not adjusted
--                     to 1 value
--  field: the index of the structure field to get
-- returns:
--   the replacement node
--   the replacement statement
------------------------------------------------------------------------------

e2s_vsfield = function (s, node, stat, multret_expanded, field)
	local f = e2s_vsfield_tbl[node[1]]
	return f(s, node, stat, multret_expanded, field)
end

e2s_vsfield_tbl = {
	['name'] = function (s, node, stat, multret_expanded, field)
		local first = node.ty.valstruct.member_offsets[field] + 1
		local last = first + node.ty.valstruct.members[field]:num_vars() - 1
		local new_node = {'comma'}
		for i = first, last do
			table.insert(new_node, node.var.expanded_replacement[i+1])
		end
		return new_node, stat
	end;

	['num_field'] = function (s, node, stat, multret_expanded, field)
		node[3] = node[3] + node.ty.valstruct.member_offsets[field]
		local new_stat = stat
		node[2], new_stat = e2s_expression(s, node[2], new_stat, true)
		return node, new_stat
	end;
}

local function e2s_vsfield_generic(s, node, stat, multret_expanded, field)
	local tmp_vars, result_vars = {'comma'}, {'comma'}
	local first_used_var = node.ty.valstruct.member_offsets[field] + 1
	local last_used_var = first_used_var + node.ty.valstruct.members[field]:num_vars() - 1
	for i = 1, last_used_var do
		if i >= first_used_var then
			local v = {'name', s.tmp_name()}
			tmp_vars[i+1] = v
			table.insert(result_vars, v)
		else
			local v = {'name', s.throwaway_name()}
			tmp_vars[i+1] = v
		end
	end
	local node, new_stat = e2s_expression(s, node, stat, true)
	local new_stat = {'do', {'seq', {'local', tmp_vars, nil, node}, new_stat}}
	return result_vars, new_stat
end

setmetatable(e2s_vsfield_tbl,
	{__index = function () return e2s_vsfield_generic end})

------------------------------------------------------------------------------

local function e2s(s, root)
	local new_root = e2s_statement(s, root)
	return new_root
end

return e2s

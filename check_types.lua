
local types = require 'types'

------------------------------------------------------------------------------
-- Container for local varaible information
--
-- The `vars` field contains an assocaiation of names to variable objects,
-- which are tables with these fields:
--
--   `ty`: the type of the variable, or `nil` if it's unknown
--   `init`: false if the varaible is still uninitialized
--
-- The `outer_init` field contains a set of all the names of variables in
-- outer scopes that are uninitialized, but were initialized in this scope.
------------------------------------------------------------------------------

local varscope_mt = {}
varscope_mt.__index = varscope_mt

local function varscope(parent)
	return setmetatable({
		parent = parent,
		vars = {},
		outer_init = {},
	}, varscope_mt)
end

function varscope_mt:decl_var(s, name, ty, init, mut)
	local v = {ty=ty, init=init, mut=mut}
	if ty and ty.valstruct then
		local rep = {'comma'}
		for i = 1, ty.valstruct.num_vars do
			rep[i+1] = {'name', s.tmp_name()}
		end
		v.expanded_replacement = rep
	end
	self.vars[name] = v
	return v
end

-- mark an unititialized varaible as having a valid value in this scope now
function varscope_mt:init_var(s, name, ty)
	local vars
	if self.vars[name] then
		self.vars[name].ty = ty
		self.vars[name].init = true
		vars = self.vars
	else
		self.outer_init[name] = true
		local p = self
		repeat
			p = p.parent
		until p.vars[name]
		p.vars[name].ty = ty
		vars = p.vars
	end
	if ty and ty.valstruct then
		local rep = {'comma'}
		for i = 1, ty.valstruct.num_vars do
			rep[i+1] = {'name', s.tmp_name()}
		end
		vars[name].expanded_replacement = rep
	end
end

-- returns the var object, and a bool saying whether the var is initialized
-- in the current scope
function varscope_mt:get_var(name, _is_init --[[for internal use]])
	local v = self.vars[name]
	if v then
		return v, _is_init or v.init
	elseif self.parent then
		return self.parent:get_var(name, _is_init or self.outer_init[name])
	end
end

function varscope_mt:add_explicit_return(ty)
	if self.explicit_return then
		--s.error('...') --TODO
	else
		self.explicit_return = ty
	end
end

------------------------------------------------------------------------------
-- Make sure that the node `node[id]` has a result value compatible with `ty`
------------------------------------------------------------------------------

local function expect_type(s, node, id, ty, extramsg, ...)
	if not ty:is_acceptable(node[id].ty) then
		local tmpmsg = ('expected type `%s`, got `%s`'):format(ty:to_str(), node[id].ty:to_str())
		if extramsg then
			tmpmsg = ('%s (%s)'):format(tmpmsg, extramsg:format(...))
		end
		s.error(tmpmsg, false, node[id]:get_location())
	end
end

------------------------------------------------------------------------------
-- Make sure that the node `node[id]` has a result value compatible with `ty`
------------------------------------------------------------------------------

local function expect_cond_value(s, node, id, extramsg, ...)
	local ty = node[id].ty
	if ty ~= types.builtin_bool and ty ~= types.builtin_dynamic and ty ~= types.builtin_vararg then
		local tmpmsg = ('expected condition type (bool or dyn), got `%s`'):format(node[id].ty:to_str())
		if extramsg then
			tmpmsg = ('%s (%s)'):format(tmpmsg, extramsg:format(...))
		end
		s.error(tmpmsg, false, node[id]:get_location())
	end
end

------------------------------------------------------------------------------
-- Make sure that the node `node[id]` has a result type containig an actual
-- value (not () or !)
------------------------------------------------------------------------------

local function expect_value(s, node, id)
	if node[id].ty == types.builtin_void then
		s.error('expected value, got `()` (void)', false, node[id]:get_location())
	elseif node[id].ty == types.builtin_noret then
		s.error('expected value, got `!` (no-return expression)', false, node[id]:get_location())
	end
end

------------------------------------------------------------------------------
-- Types that cannot be used for varaibles, function parameters, etc.
------------------------------------------------------------------------------

local forbidden_var_types = {
	[types.builtin_void] = true,
	[types.builtin_vararg] = true,
	[types.builtin_noret] = true,
}

------------------------------------------------------------------------------
-- Run the type checking function from the table for that type of node
-- parameters:
--   s: the compiler state
--   node: the current node
--   suggest: an optional suggestion for what result type the node should have
------------------------------------------------------------------------------

local check_types_tbl

local function check_types(s, node, tsuggest)
	return check_types_tbl[node[1]](s, node)
end

------------------------------------------------------------------------------
-- Check the lhs of a local variable declaration
-- parameters:
--   s: the compiler state
--   node: the current node
--   ty: the type of value being assigned to the node, or nil if unknown
--   init: is the variable initialized on declaration?
------------------------------------------------------------------------------

local function check_types_vardecl(s, node, ty, init, mut)
	if node[1] == 'name' then
		if ty == types.builtin_vararg then ty = types.builtin_dynamic end
		if forbidden_var_types[ty] then
			s.error(('variables cannot have a `%s` type'):format(ty:to_str()), false, node:get_location())
		end
		node.var = s.current_varscope:decl_var(s, node[2], ty, init, mut)
		return

	elseif node[1] == 'tuple' then
		if ty.valstruct and ty.valstruct.kind == 'tuple' then
			if #node-1 > ty.valstruct.num_members then
				s.error('tuple deconstructor has more members than value to be deconstructed', false, node:get_location())
			end
			for i = 2, #node do
				check_types_vardecl(s, node[i], ty.valstruct.members[i-1], init, mut)
			end

		elseif ty == types.builtin_vararg then
			for i = 2, #node do
				check_types_vardecl(s, node[i], types.builtin_dynamic, init, mut)
			end

		else
			s.error('tuple deconstructor used with non-tuple value', false, node:get_location())
		end
		return

	end
	s.error('invalid local varaible declaration', false, node:get_location())
end

------------------------------------------------------------------------------
-- Check a node in an lvalue context
-- parameters:
--   s: the compiler state
--   node: the current node
--   ty: the type of value being assigned to the node
------------------------------------------------------------------------------

local function check_types_lval(s, node, ty)
	if node[1] == 'name' then
		local var, var_init = s.current_varscope:get_var(node[2])
		node.var = var
		if not var then
			s.error(('assignment to varaible `%s`, which does not exist in the current scope'):format(node[2]), false, node:get_location())
		end
		if not var.mut then
			s.error(('assignment to immutable varaible `%s`'):format(node[2]), false, node:get_location())
		end
		if not var.ty then
			s.current_varscope:init_var(s, node[2], ty)
		else
			if not var.ty:is_acceptable(ty) then
				s.error(('assignment of `%s` value to variable `%s`, which has type `%s`'):format(ty:to_str(), node[2], var.ty:to_str()), false, node:get_location())
			end
			s.current_varscope:init_var(s, node[2], var.ty)
		end
		return

	elseif node[1] == 'tuple' then
		if ty.valstruct and ty.valstruct.kind == 'tuple' then
			if #node-1 ~= ty.valstruct.num_members then
				s.error('tuple deconstructor has different amount members than value to be deconstructed', false, node:get_location())
			end
			for i = 2, #node do
				check_types_vardecl(s, node[i], ty.valstruct.members[i-1], init)
			end

		elseif ty == types.builtin_vararg then
			for i = 2, #node do
				check_types_vardecl(s, node[i], types.builtin_dynamic, init)
			end

		else
			s.error('tuple deconstructor used with non-tuple value', false, node:get_location())
		end
		return

	elseif node[1] == 'field' then
		return check_types(s, node, nil)

	end
	s.error('assignment to rvalue expression', false, node:get_location())
end

------------------------------------------------------------------------------
-- table of functions for `check_types`
------------------------------------------------------------------------------

check_types_tbl = {
	['var'] = function (s, node, tsuggest)
		if node[3] then
			node[3] = node[3]:resolve_named(s)
			if forbidden_var_types[node[3]] then
				s.error(('variables cannot have a `%s` type'):format(ty:to_str()), false, node[3]:get_location())
			end
		end
		if node[4] then
			check_types(s, node[4], node[3])
			if node[3] then
				expect_type(s, node, 4, node[3])
			else
				node[3] = node[4].ty
			end
			check_types_vardecl(s, node[2], node[3], true, true)
		else
			check_types_vardecl(s, node[2], node[3], false, true)
		end
		node[1] = 'local'
		node.ty = types.builtin_void
	end;
	
	['let'] = function (s, node, tsuggest)
		if node[3] then
			node[3] = node[3]:resolve_named(s)
			if forbidden_var_types[node[3]] then
				s.error(('variables cannot have a `%s` type'):format(ty:to_str()), false, node[3]:get_location())
			end
		end
		check_types(s, node[4], node[3])
		if node[3] then
			expect_type(s, node, 4, node[3])
		else
			node[3] = node[4].ty
		end
		check_types_vardecl(s, node[2], node[3], true, false)
		node[1] = 'local'
		node.ty = types.builtin_void
	end;

	['assign'] = function (s, node, tsuggest)
		check_types(s, node[4], nil)
		check_types_lval(s, node[2], node[4].ty)
		--expect_type(s, node, 4, node[2].ty, 'in assignment')
		node.ty = types.builtin_void
	end;

	['name'] = function (s, node, tsuggest)
		local var, var_init = s.current_varscope:get_var(node[2])
		if not var then
			s.error(('no variable named `%s` in current scope'):format(node[2]), false, node:get_location())
		end
		if not (var_init and var.ty) then
			s.error(('accessing uninitialized variable `%s`'):format(node[2]), false, node:get_location())
		end
		node.var = var
		node.ty = var.ty
	end;

	['if'] = function (s, node, tsuggest)
		check_types(s, node[2])
		expect_cond_value(s, node, 2, 'in `if` condition')
		-- `true` branch
		local old = s.current_varscope
		s.current_varscope = varscope(old)
		local scope_a = s.current_varscope
		check_types(s, node[3], tsuggest)
		s.current_varscope = old
		if node[4] then
			-- optional `false` branch
			local old = s.current_varscope
			s.current_varscope = varscope(old)
			local scope_b = s.current_varscope
			check_types(s, node[4], tsuggest)
			s.current_varscope = old
			-- if one of the branches doesn't return, use the type of the other
			-- branch. otherwise, make sure they match
			if node[3].ty == types.builtin_noret then
				node.ty = node[4].ty
			elseif node[4].ty == types.builtin_noret then
				node.ty = node[3].ty
			else
				expect_type(s, node, 4, node[3].ty, '`if` branch result types do not match')
				node.ty = node[3].ty
			end
			-- if any of the branches contain a return statement, make sure they return
			-- the same type
			if scope_a.explicit_return then
				if scope_b.explicit_return and not scope_a.explicit_return:equal(scope_b.explicit_return) then
					s.error('`if` branches have `return` statements with different types', false, node:get_location())
				end
				s.current_varscope:add_explicit_return(scope_a.explicit_return)
			elseif scope_b.explicit_return then
				s.current_varscope:add_explicit_return(scope_b.explicit_return)
			end
			-- if a varaible was initialized in both branches, mark it as
			-- initialized in this scope too
			for k in pairs(scope_a.outer_init) do
				if scope_b.outer_init[k] then
					if s.current_varscope.vars[k] then
						s.current_varscope.vars[k].init = true
					else
						s.current_varscope.outer_init[k] = true
					end
				end
			end
		else
			-- `false` branch omitted, defaults to `()`
			if node[3].ty ~= types.builtin_noret and node[3].ty ~= types.builtin_void then
				s.error('when the `else` branch is omitted, the `true` branch must have a `()` or `!` type', false, node:get_location())
			end
			node.ty = types.builtin_void
		end
	end;

	['repeat'] = function (s, node, tsuggest)
		check_types(s, node[2], types.builtin_void)
		if node[2].ty == types.builtin_noret then
			s.error('body of repeat...until loop never returns, condition never used')
		end
		check_types(s, node[3], types.builtin_bool)
		expect_cond_value(s, node, 3, 'in repeat...until loop condition')
		node.ty = types.builtin_void
	end;

	['while'] = function (s, node, tsuggest)
		check_types(s, node[2], types.builtin_bool)
		expect_cond_value(s, node, 2, 'in while loop condition')
		local old = s.current_varscope
		s.current_varscope = varscope(old)
		check_types(s, node[3], types.builtin_void)
		if s.current_varscope.explicit_return then
			old:add_explicit_return(s.current_varscope.explicit_return)
		end
		s.current_varscope = old
		node.ty = types.builtin_void
	end;

	['do'] = function (s, node, tsuggest)
		local old = s.current_varscope
		s.current_varscope = varscope(old)
		check_types(s, node[2], tsuggest)
		if s.current_varscope.explicit_return then
			old:add_explicit_return(s.current_varscope.explicit_return)
		end
		s.current_varscope = old
		node.ty = node[2].ty
	end;

	--[=[
	['method_call'] = function (s, node, tsuggest)
		check_types(s, node[2], nil)
		local call = node[2].ty.call
		if not call then
			s.error(('value with type `%s` is not callable'):format(node[2].ty:to_str()), false, node[2]:get_location())
		end
		if call.vararg then
			if #call.params > #node-2 then
				s.error(('function expected at least %d parameters (not counting hidden `self`), got %d'):format(#call.params, #node-2), false, node[2]:get_location())
			end
			for i = 3, #node do
				local param = call.params[i-2]
				if param then
					local expected_type = param.ty
					check_types(s, node[i], expected_type)
					expect_type(s, node, i, expected_type, 'in function parameter #%d', i-2)
				else
					check_types(s, node[i], nil)
					expect_value(s, node, i)
				end
			end
		else
			if #call.params ~= #node-2 then
				s.error(('function expected %d parameters (not counting hidden `self`), got %d'):format(#call.params, #node-2), false, node[2]:get_location())
			end
			for i = 3, #node do
				local expected_type = call.params[i-2].ty
				check_types(s, node[i], expected_type)
				expect_type(s, node, i, expected_type, 'in function parameter #%d', i-2)
			end
		end
		node.ty = call.ret
	end;
	--]=]

	['call'] = function (s, node, tsuggest)
		check_types(s, node[2], nil)
		local call = node[2].ty.call
		if not call then
			s.error(('value with type `%s` is not callable'):format(node[2].ty:to_str()), false, node[2]:get_location())
		end
		if call.vararg then
			if #call.params > #node-2 then
				s.error(('function expected at least %d parameters, got %d'):format(#call.params, #node-2), false, node[2]:get_location())
			end
			for i = 3, #node do
				local param = call.params[i-2]
				if param then
					local expected_type = param.ty
					check_types(s, node[i], expected_type)
					expect_type(s, node, i, expected_type, 'in function parameter #%d', i-2)
				else
					check_types(s, node[i], nil)
					expect_value(s, node, i)
				end
			end
		else
			if #call.params ~= #node-2 then
				s.error(('function expected %d parameters, got %d'):format(#call.params, #node-2), false, node[2]:get_location())
			end
			for i = 3, #node do
				local expected_type = call.params[i-2].ty
				check_types(s, node[i], expected_type)
				expect_type(s, node, i, expected_type, 'in function parameter #%d', i-2)
			end
		end
		node.ty = call.ret
	end;

	['function'] = function (s, node, tsuggest)
		-- save the old scope and current function info
		local old_fn = s.current_fn
		s.current_fn = {rettype = nil}
		local old = s.current_varscope
		s.current_varscope = varscope(old)
		-- add parameter varaibles to scope
		local params = node[2]
		if params.implicit_types then
			s.error('inferred function params not supported yet')
		else
			for i, v in ipairs(params) do
				v.ty = v.ty:resolve_named(s)
				if forbidden_var_types[v.ty] then
					s.error(('function parameters cannot have a `%s` type'):format(v.ty:to_str()), false, node:get_location())
				end
				v.var = s.current_varscope:decl_var(s, v.name, v.ty, true)
			end
		end
		-- explicit return type
		if node[3] then
			node[3] = node[3]:resolve_named(s)
			s.current_fn.rettype = node[3]
		end
		-- -- implicit return
		-- node[4] = {'return', node[4]}
		-- do this pass on the contents of the function
		check_types(s, node[4], node[3])
		if node[3] then
			if node[4].ty == types.builtin_noret then
				if (not s.current_varscope.explicit_return) and node[3] ~= types.builtin_noret then
					s.error(('function has explicit `%s` return type, but all code paths return `!`'):format(node[3]), false, node:get_location())
				end
			end
		else
			if node[4].ty == types.builtin_noret then
				if s.current_varscope.explicit_return then
					node[3] = s.current_varscope.explicit_return
				else
					node[3] = types.builtin_noret
				end
			else
				if s.current_varscope.explicit_return then
					expect_type(s, node, 4, s.current_varscope.explicit_return)
				end
				node[3] = node[4].ty
			end
		end
		if node[4].ty ~= types.builtin_void and node[4].ty ~= types.builtin_noret then
			node[4] = {'return', node[4]}
		end
		node.ty = types.new_function(params, node[3], params.vararg)
		-- restore outer function context
		s.current_varscope = old
		s.current_fn = old_fn
	end;

	['seq'] = function (s, node, tsuggest)
		local noret = false
		local count = #node
		for i = 2, count do
			check_types(s, node[i], i==count and tsuggest or types.builtin_void)
			-- if any of the nodes in the list don't return, that makes the whole
			-- sequence not return
			noret = noret or node[i].ty == types.builtin_noret
		end
		node.ty = noret and types.builtin_noret or node[count].ty
	end;

	['tuple'] = function (s, node, tsuggest)
		local t = {}
		for i = 2, #node do
			check_types(s, node[i], nil)
			expect_value(s, node, i)
			t[i - 1] = node[i].ty
		end
		node.ty = types.new_tuple(t)
	end;

	['field'] = function (s, node, tsuggest)
		check_types(s, node[2], nil)
		local t = node[2].ty
		if t.valstruct then
			if t.valstruct.kind == 'tuple' then
				local index = node[3]:match('^_([1-9][0-9]*)$')
				if not index then
					s.error('tuple fields must be accessed as `_N`, where N is the number of the field starting from 1', false, node:get_location())
				end
				index = tonumber(index)
				if index > t.valstruct.num_members then
					s.error(('attempt to get member #%d from tuple with %d members'):format(index, t.valstruct.num_members), false, node:get_location())
				end
				node.ty = t.valstruct.members[index]
				node[3] = index
			else -- struct
				local index = t.valstruct.name_to_index[node[3]]
				if not index then
					s.error(('struct `%s` does not have a field named `%s`'):format(t:to_str(), node[3]), false, node:get_location())
				end
				node.ty = t.valstruct.members[index]
				node[3] = index
			end
			node[1] = 'valstruct_field'
		elseif t.cls then
			local index = t.cls.name_to_index[node[3]]
			if not index then
				s.error(('class `%s` does not have a field named `%s`'):format(t:to_str(), node[3]), false, node:get_location())
			end
			if t.cls.packed then
				node[1] = 'num_field'
				node[3] = t.cls.member_offsets[index] + 1
			end
			node.ty = t.cls.members[index]
		elseif t.dynamic then
			node.ty = types.builtin_dynamic
		else
			s.error(('`%s` value does not have named fields'):format(node[2].ty:to_str()), false, node:get_location())
		end
	end;

	['index'] = function (s, node, tsuggest)
		check_types(s, node[2], nil)
		check_types(s, node[3], nil)
		node.ty= types.builtin_dynamic
	end;

	['binop'] = function (s, node, tsuggest)
		check_types(s, node[3], nil)
		expect_value(s, node, 3)
		check_types(s, node[4], nil)
		expect_value(s, node, 4)
		local res = types.binop_supported(node[2], node[3].ty, node[4].ty)
		if not res then
			s.error(('binary operator `%s` not supported for `%s` and `%s` parameters'):format(node[2], node[3].ty:to_str(), node[4].ty:to_str()), false, node:get_location())
		end
		node.ty = res
	end;

	['unop'] = function (s, node, tsuggest)
		check_types(s, node[3], nil)
		expect_value(s, node, 3)
		node.ty = types.builtin_dynamic
		local res = types.unop_supported(node[2], node[3].ty)
		if not res then
			s.error(('unary operator `%s` not supported for `%s` parameter'):format(node[2], node[3].ty:to_str()), false, node:get_location())
		end
		node.ty = res
	end;

	['return'] = function (s, node, tsuggest)
		check_types(s, node[2], nil)
		if node[2].ty ~= types.builtin_noret then
			if s.current_fn.rettype then
				if node[2].ty ~= types.builtin_noret then
					expect_type(s, node, 2, s.current_fn.rettype)
				end
			end
			s.current_varscope:add_explicit_return(node[2].ty)
		end
		node.ty = types.builtin_noret
	end;

	['new_variant'] = function (s, node, tsuggest)
		node[2] = node[2]:resolve_named(s)
		local vty = node[2]
		if not (vty.valstruct and vty.valstruct.kind == 'variant') then
			s.error(('expected variant type'):format(), false, node:get_location())
		end
		local idx = vty.valstruct.name_to_index[node[3]]
		if not idx then
			s.error(('variant type does not have a varaint named `%s`'):format(node[3]), false, node:get_location())
		end
		check_types(s, node[4], vty.valstruct.members[idx])
		expect_type(s, node, 4, vty.valstruct.members[idx])
		node.ty = vty
	end;

	['new_kv'] = function (s, node, tsuggest)
		node[2] = node[2]:resolve_named(s)
		if node[2].valstruct and node[2].valstruct.kind == 'struct' then
			local ty = node[2]
			local vs = ty.valstruct
			local members = node[3]
			node.ty = ty
			node[1], node[2], node[3] = 'tuple', nil, nil
			local all = {}
			for i, v in ipairs(members) do
				if not vs.name_to_index[v.name] then
					s.error(('struct constructor contains member `%s`, which is not in type `%s`'):format(v.name, ty:to_str()), false, node:get_location())
				end
				if all[v.name] then
					s.error(('struct constructor contains duplicate for member `%s`'):format(v.name), false, node:get_location())
				end
				all[v.name] = true
			end
			for i, v in ipairs(vs.member_names) do
				if not all[v] then
					s.error(('struct constructor for type `%s` is missing field `%s`'):format(ty:to_str(), v), false, node:get_location())
				end
			end
			table.sort(members, function (a, b)
				return vs.name_to_index[a.name] < vs.name_to_index[b.name]
			end)
			for i, v in ipairs(members) do
				table.insert(node, v.val)
				local mty = vs.members[i]
				check_types(s, node[#node], mty)
				expect_type(s, node, #node, mty)
			end
		elseif node[2].cls then
			local ty = node[2]
			local cls = ty.cls
			local members = node[3]
			node.ty = ty
			node[1], node[2], node[3] = 'table', nil, nil
			local all = {}
			for i, v in ipairs(members) do
				if not cls.name_to_index[v.name] then
					s.error(('struct constructor contains member `%s`, which is not in type `%s`'):format(v.name, ty:to_str()), false, node:get_location())
				end
				if all[v.name] then
					s.error(('struct constructor contains duplicate for member `%s`'):format(v.name), false, node:get_location())
				end
				all[v.name] = true
			end
			for i, v in ipairs(cls.member_names) do
				if not all[v] then
					s.error(('struct constructor for type `%s` is missing field `%s`'):format(ty:to_str(), v), false, node:get_location())
				end
			end
			if cls.packed then
				table.sort(members, function (a, b)
					return cls.name_to_index[a.name] < cls.name_to_index[b.name]
				end)
				for i, v in ipairs(members) do
					table.insert(node, false)
					table.insert(node, v.val)
					local mty = cls.members[i]
					check_types(s, node[#node], mty)
					expect_type(s, node, #node, mty)
				end
			else
				for i, v in ipairs(members) do
					table.insert(node, {'string', v.name})
					table.insert(node, v.val)
					local mty = cls.members[cls.name_to_index[v.name]]
					check_types(s, node[#node], mty)
					expect_type(s, node, #node, mty)
				end
			end
		else
			s.error('`new` can only be used with class and struct types', false, node:get_location())
		end
	end;

	['vararg'] = function (s, node, tsuggest)
		node.ty = types.builtin_vararg
	end;
	['parens'] = function (s, node, tsuggest)
		check_types(s, node[2], tsuggest)
		if node[2].ty == types.builtin_vararg then
			node.ty = types.builtin_dynamic
		else
			node.ty = node[2].ty
		end
	end;

	['int'] = function (s, node, tsuggest)
		node.ty = types.builtin_int
	end;
	['float'] = function (s, node, tsuggest)
		node.ty = types.builtin_float
	end;
	['string'] = function (s, node, tsuggest)
		node.ty = types.builtin_string
	end;
	['true'] = function (s, node, tsuggest)
		node.ty = types.builtin_bool
	end;
	['false'] = function (s, node, tsuggest)
		node.ty = types.builtin_bool
	end;
	['boolean'] = function (s, node, tsuggest)
		node.ty = types.builtin_bool
	end;
	['nil'] = function (s, node, tsuggest)
		node.ty = types.builtin_nil
	end;
	['void'] = function (s, node, tsuggest)
		node.ty = types.builtin_void
	end;
}

------------------------------------------------------------------------------
-- Main function for this pass
------------------------------------------------------------------------------

local function check_types_start(s, root)
	s.current_varscope = varscope()
	s.current_fn = {
		rettype = nil
	}
	check_types(s, root)
	if root.ty ~= types.builtin_void and root.ty ~= types.builtin_noret then
		root = {'return', root}
	end
	s.current_varscope = nil
	s.current_fn = nil
	return root
end

return check_types_start

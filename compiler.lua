
-- Lua magic to not pollute the global namespace
_ENV = setmetatable({}, {__index = _ENV})

Parser = require("parser")

file = io.open("test.lua", "r")
contents = file:read("a")
Parser.open(contents)
ast = Parser.parse()
if not ast then print("Error: " .. Parser.error) os.exit(1) end

function tostr (obj, pre)
  pre = pre or ""
  if type(obj) ~= "table" then
    return tostring(obj) end

  if #obj > 0 then
    local str = "["
    for i = 1, #obj do
      if i > 1 then str = str .. ", " end
      str = str .. tostr(obj[i], pre)
    end
    return str .. "]"
  end

  local first = true
  local str = "{"
  for k, v in pairs(obj) do
    if first then first = false
    else str = str .. "," end
    str = str .. "\n" .. pre .. "  " .. k .. " = " .. tostr(v, pre .. "  ")
  end
  str = str .. "\n" .. pre .. "}"
  if first then return "[]" end
  return str
end

function err (msg, node)
  if node then
    msg = msg .. ", at " .. node.line .. ":" .. node.column
  end
  error(msg)
end

modules = {}
types = {}
funcs = {}

local _m = {}
function _m:type (name)
  local t = {id=#types, name=name, module=self.id}
  table.insert(types, t)
  return t
end
function _m:func (name, ins, outs)
  local f = {_id=#funcs, name=name, ins={}, outs={}, module=self.id}
  function f:id () return self._id end
  for i, t in ipairs(ins) do f.ins[i] = t.id end
  for i, t in ipairs(outs) do f.outs[i] = t.id end
  table.insert(funcs, f)
  return f
end
function module (name)
  -- Positions 0 and 1 are reserved
  local m = {id=#modules+2, name=name}
  setmetatable(m, {__index = _m})
  table.insert(modules, m)
  return m
end

local _f = {}
function _f:id () return self._id end
function _f:reg ()
  local r = {id=#self.regs}
  table.insert(self.regs, r)
  return r
end
function _f:inst (data)
  table.insert(self.code, data)
  return data
end
function _f:lbl ()
  local l = self.lblc + 1
  self.lblc = l
  return l
end
function code (name)
  local f = {
    _id=#funcs,
    name=name,
    regs={},
    code={},
    lblc=0,
    ins={},
    outs={},
    locals={},
  }
  setmetatable(f, {__index = _f})
  table.insert(funcs, f)
  return f
end

core_m = module("cobre.core")
int_m = module("cobre.int")
str_m = module("cobre.string")
lua_m = module("lua")

any_t = core_m:type("any")
bin_t = core_m:type("bin")
int_t = int_m:type("int")
string_t = str_m:type("string")
stack_t = lua_m:type("Stack")

newstr_f = str_m:func("new", {bin_t}, {string_t})
str_f = lua_m:func("_string", {string_t}, {any_t})

int_f = lua_m:func("_int", {int_t}, {any_t})
nil_f = lua_m:func("nil", {}, {any_t})
true_f = lua_m:func("_true", {}, {any_t})
false_f = lua_m:func("_false", {}, {any_t})
print_f = lua_m:func("_print", {stack_t}, {stack_t})

push_f = lua_m:func("push:Stack", {stack_t, any_t}, {})
next_f = lua_m:func("next:Stack", {stack_t}, {any_t})
stack_f = lua_m:func("newStack", {}, {stack_t})

table_f = lua_m:func("newTable", {}, {any_t})
get_f = lua_m:func("get", {any_t, any_t}, {any_t})
set_f = lua_m:func("set", {any_t, any_t, any_t}, {})

binops = {
  ["+"] = lua_m:func("add", {any_t,any_t}, {any_t}),
  ["-"] = lua_m:func("sub", {any_t,any_t}, {any_t}),
  ["*"] = lua_m:func("mul", {any_t,any_t}, {any_t}),
  ["/"] = lua_m:func("div", {any_t,any_t}, {any_t}),
  [".."] = lua_m:func("concat", {any_t,any_t}, {any_t}),
}

constants = {}

function constant (tp, value)
  local data = {_id=#constants, type=tp, value=value, ins={}, outs={0}}
  function data:id () return self._id + #funcs end
  table.insert(constants, data)
  return data
end

function constcall (f, ...)
  local data = constant("call")
  data.f = f
  data.args = table.pack(...)
  return data
end

main_f = code("main")

function compileExpr (node)
  local tp = node.type
  if tp == "const" then
    local reg = main_f:reg()
    local f
    if node.value == "nil" then f = nil_f
    elseif node.value == "true" then f = true_f
    elseif node.value == "false" then f = false_f
    end
    main_f:inst{"call", f}
    return reg
  elseif tp == "num" then
    local n = tonumber(node.value)
    local raw = constant("int", n)
    local cns = constcall(int_f, raw)
    local reg = main_f:reg()
    main_f:inst{"call", cns}
    return reg
  elseif tp == "str" then
    local raw = constant("bin", node.value)
    local str = constcall(newstr_f, raw)
    local cns = constcall(str_f, str)
    local reg = main_f:reg()
    main_f:inst{"call", cns}
    return reg
  elseif tp == "var" then
    return main_f.locals[node.name]
  elseif tp == "binop" then
    local f = binops[node.op]
    local a = compileExpr(node.left)
    local b = compileExpr(node.right)
    local reg = main_f:reg()
    main_f:inst{"call", f, a, b}
    return reg
  elseif tp == "index" then
    local base = compileExpr(node.base)
    local key = compileExpr(node.key)
    local reg = main_f:reg()
    main_f:inst{"call", get_f, base, key}
    return reg
  elseif tp == "constructor" then
    local reg = main_f:reg()
    main_f:inst{"call", table_f}
    for i, item in ipairs(node.items) do
      if item.type == "indexitem" then
        local key = compileExpr(item.key)
        local value = compileExpr(item.value)
        main_f:inst{"call", set_f, reg, key, value}
      else err("Only index items are supported in constructors", node) end
    end
    return reg
  elseif tp == "call" then
    if node.base.type == "var" and node.base.name == "print" then
      local args = main_f:reg()
      main_f:inst{"call", stack_f}
      for i, v in ipairs(node.values) do
        local arg = compileExpr(v)
        main_f:inst{"call", push_f, args, arg}
      end
      local result = main_f:reg()
      main_f:inst{"call", print_f, args}
      local reg = main_f:reg()
      main_f:inst{"call", next_f, result}
      return reg
    else err("The only function supported is print with 1 argument", node) end
  else err("expression " .. tp .. " not supported", node) end
end

function compileStmt (node)
  local tp = node.type
  if tp == "local" then
    if (#node.names ~= #node.values) then
      err("different number of names and expressions are not supported", node)
    end
    for i = 1, #node.names do
      local reg = compileExpr(node.values[i])
      main_f.locals[node.names[i]] = reg
    end
  elseif tp == "call" then compileExpr(node)
  else
    err("statement not supported: " .. tp, node)
  end
end

function compileBlock (nodes)
  for i, node in ipairs(nodes) do
    compileStmt(node)
  end
end

compileBlock(ast)
main_f:inst{"end"}

outfile = io.open("out", "wb")

function wbyte (...)
  outfile:write(string.char(...))
end

function wint (n)
  function f (n)
    if n > 0 then
      f(n >> 7)
      wbyte((n & 0x7f) | 0x80)
    end
  end
  f(n >> 7)
  wbyte(n & 0x7f)
end

function wstr (str)
  wint(#str)
  outfile:write(str)
end

outfile:write("Cobre 0.5\0")
wint(#modules+1) -- Count the export module, but not the argument module
wbyte(1, 1, 2) -- Export module is a module definition with 1 item, main
wint(main_f:id())
wstr("main")
for i, mod in ipairs(modules) do
  wbyte(0)
  wstr(mod.name)
end

wint(#types)
for i, tp in ipairs(types) do
  wint(tp.module + 1)
  wstr(tp.name)
end

wint(#funcs)
for i, fn in ipairs(funcs) do
  if fn.module then
    wint(fn.module + 2)
  elseif fn.code then
    wbyte(1)
  end
  wint(#fn.ins)
  for i, t in ipairs(fn.ins) do wint(t) end
  wint(#fn.outs)
  for i, t in ipairs(fn.outs) do wint(t) end
  if fn.module then wstr(fn.name) end
end

wint(#constants)
for i, cns in ipairs(constants) do
  if cns.type == "int" then
    wbyte(1)
    wint(cns.value)
  elseif cns.type == "bin" then
    wbyte(2)
    wstr(cns.value)
  elseif cns.type == "call" then
    if #cns.args ~= #cns.f.ins then
      error(cns.f.name .. " expects " .. #cns.f.ins .. " arguments, but got " .. #cns.args)
    end
    wint(cns.f:id() + 16)
    for i, v in ipairs(cns.args) do
      wint(v:id())
    end
  else error("constant " .. cns.type .. " not supported") end
end

function write_code (fn)
  wint(#fn.code)
  for i, inst in ipairs(fn.code) do
    local k = inst[1]
    if k == "end" then wbyte(0)
    elseif k == "call" then
      local f = inst[2]
      wint(f:id() + 16)
      if #inst-2 ~= #f.ins then
        error(f.name .. " expects " .. #f.ins .. " arguments, but got " .. #inst-2)
      end
      for i = 3, #inst do
        wint(inst[i].id)
      end
    else error("Unsupported instruction: " .. k) end
  end
end

-- Code
for i, fn in ipairs(funcs) do
  if fn.code then write_code(fn) end
end

wbyte(0) -- metadata

--print(tostr(funcs))

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 属性克制 ============================
--
-- 架构文档 §6 把"属性克制"列为战斗核的规则之一，它同时也是 §11 的开放问题 3
-- （配置表用什么格式）。这个文件把**机制**定死，把**数据**留成一张表：
--
--   * 机制：乘法叠加。双属性防守方 = 两个属性倍率相乘。
--     乘出 0 就是免疫，乘出 4 就是"克制到极点"——这两个特例不用单独写代码。
--   * 数据：`Element.MULTIPLIERS[攻击属性][防守属性] = 倍率`。
--     表里没写的组合一律 1 倍，所以这张表只需要写"不寻常"的那些格子，
--     不必把 18×18 全部填满。
--
-- ---------------------------- 关于下面这张表 ----------------------------
--
-- **这是占位数据**：只覆盖了一部分属性、一部分组合，够把机制跑通和自测用。
-- 它有意写得短，因为写错一半的克制表比没有克制表更害人——你会照着错的数字
-- 去调平衡。正式数据应当在接入精灵图鉴时整表替换（换表不用改任何代码）。
--
-- 替换方式：
--   `Element.loadTable(图鉴导出的表)` 或直接 `dofile` 覆盖 `Element.MULTIPLIERS`。

Element = {}

-- 倍率常量（写成常量是为了让规则代码能自解释，也避免满篇魔法数字）
Element.IMMUNE = 0        -- 免疫
Element.RESIST_QUARTER = 0.25
Element.RESIST_HALF = 0.5 -- 效果不佳
Element.NORMAL = 1        -- 一般
Element.WEAK = 2          -- 效果拔群（克制）
Element.WEAK_QUARTER = 4  -- 双属性都被克制

--- 倍率表：`[攻击属性][防守属性] = 倍率`。没写的组合按 1 倍处理。
---@type table<string, table<string, number>>
Element.MULTIPLIERS = {
  -- 普通：没什么克制关系（图鉴里普通系是"万能但无加成"的定位）
  ["普通"] = {},

  ["草"] = {
    ["水"] = Element.WEAK,
    ["地面"] = Element.WEAK,
    ["草"] = Element.RESIST_HALF,
    ["火"] = Element.RESIST_HALF,
    ["飞行"] = Element.RESIST_HALF,
    ["机械"] = Element.RESIST_HALF,
  },

  ["水"] = {
    ["火"] = Element.WEAK,
    ["地面"] = Element.WEAK,
    ["水"] = Element.RESIST_HALF,
    ["草"] = Element.RESIST_HALF,
    ["龙"] = Element.RESIST_HALF,
  },

  ["火"] = {
    ["草"] = Element.WEAK,
    ["冰"] = Element.WEAK,
    ["机械"] = Element.WEAK,
    ["水"] = Element.RESIST_HALF,
    ["火"] = Element.RESIST_HALF,
    ["地面"] = Element.RESIST_HALF,
    ["龙"] = Element.RESIST_HALF,
  },

  ["电"] = {
    ["水"] = Element.WEAK,
    ["飞行"] = Element.WEAK,
    ["电"] = Element.RESIST_HALF,
    ["草"] = Element.RESIST_HALF,
    ["龙"] = Element.RESIST_HALF,
    ["地面"] = Element.IMMUNE, -- 电打地面无效
  },

  ["地面"] = {
    ["火"] = Element.WEAK,
    ["电"] = Element.WEAK,
    ["机械"] = Element.WEAK,
    ["草"] = Element.RESIST_HALF,
    ["飞行"] = Element.IMMUNE, -- 地面打飞行无效
  },

  ["飞行"] = {
    ["草"] = Element.WEAK,
    ["战斗"] = Element.WEAK,
    ["电"] = Element.RESIST_HALF,
    ["机械"] = Element.RESIST_HALF,
  },

  ["冰"] = {
    ["草"] = Element.WEAK,
    ["飞行"] = Element.WEAK,
    ["地面"] = Element.WEAK,
    ["龙"] = Element.WEAK,
    ["火"] = Element.RESIST_HALF,
    ["水"] = Element.RESIST_HALF,
    ["冰"] = Element.RESIST_HALF,
    ["机械"] = Element.RESIST_HALF,
  },

  ["超能"] = {
    ["战斗"] = Element.WEAK,
    ["超能"] = Element.RESIST_HALF,
    ["机械"] = Element.RESIST_HALF,
  },

  ["战斗"] = {
    ["普通"] = Element.WEAK,
    ["冰"] = Element.WEAK,
    ["机械"] = Element.WEAK,
    ["飞行"] = Element.RESIST_HALF,
    ["超能"] = Element.RESIST_HALF,
  },

  ["机械"] = {
    ["冰"] = Element.WEAK,
    ["火"] = Element.RESIST_HALF,
    ["水"] = Element.RESIST_HALF,
    ["电"] = Element.RESIST_HALF,
    ["机械"] = Element.RESIST_HALF,
  },

  ["光"] = {
    ["暗影"] = Element.WEAK,
    ["光"] = Element.RESIST_HALF,
  },

  ["暗影"] = {
    ["超能"] = Element.WEAK,
    ["光"] = Element.RESIST_HALF,
    ["暗影"] = Element.RESIST_HALF,
  },

  ["龙"] = {
    ["龙"] = Element.WEAK,
    ["机械"] = Element.RESIST_HALF,
  },
}

--- 用图鉴导出的表整表替换（换数据不改代码）
---@param tbl table<string, table<string, number>>
function Element.loadTable(tbl)
  assert(type(tbl) == "table", "Element.loadTable 需要一张表")
  Element.MULTIPLIERS = tbl
  Log.info(("属性克制表已替换，共 %d 个攻击属性"):format(Element._count(tbl)))
end

function Element._count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- 注册/覆盖一条克制关系
---@param atk string
---@param def string
---@param mult number
function Element.set(atk, def, mult)
  Element.MULTIPLIERS[atk] = Element.MULTIPLIERS[atk] or {}
  Element.MULTIPLIERS[atk][def] = mult
end

--- 单属性对单属性的倍率
---@param atk string?
---@param def string?
---@return number
function Element.getSingle(atk, def)
  if atk == nil or def == nil then return Element.NORMAL end
  local row = Element.MULTIPLIERS[atk]
  if row == nil then return Element.NORMAL end
  return row[def] or Element.NORMAL
end

--- 攻击属性 × 防守方（可能双属性）的总倍率。
--- 双属性就是两次相乘：比如草打"水/飞行"，水 2 倍 × 飞行 0.5 倍 = 1 倍。
---@param atk_element string?
---@param def_elements string|string[]?
---@return number
function Element.getMultiplier(atk_element, def_elements)
  if atk_element == nil or def_elements == nil then return Element.NORMAL end
  if type(def_elements) == "string" then def_elements = { def_elements } end

  local ret = Element.NORMAL
  for _, de in ipairs(def_elements) do
    ret = ret * Element.getSingle(atk_element, de)
  end
  return ret
end

--- 给客户端/日志用的人话描述
---@param mult number
---@return string
function Element.describe(mult)
  if mult == Element.IMMUNE then return "没有效果" end
  if mult > Element.NORMAL then return "效果拔群" end
  if mult < Element.NORMAL then return "效果不佳" end
  return "一般"
end

---@param mult number
---@return boolean
function Element.isImmune(mult)
  return mult == Element.IMMUNE
end

return Element

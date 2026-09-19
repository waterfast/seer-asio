-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 属性克制（查询） ============================
--
-- 数据全在 `core/elements/chart.lua`，这个文件只做两件事：查表、算双属性。
-- 纯表 + 纯函数——没有类、没有状态、没有副作用，require 一次之后随便调，
-- 返回值也可以随便缓存。
--
-- ---------------------------- 要用的时候只有一行 ----------------------------
--
--     local coef = Elements.getMultiplier(skill.element, target.elements)
--
--   * 第 1 个参数是**技能**的属性，单个字符串（见 skill.lua 的 `element` 字段；
--     那边写 nil 表示"跟随使用者本属性"，跟随的那一步不属于这里）。
--   * 第 2 个参数是**受击精灵**的属性，字符串或数组都行（见 pet.lua 的
--     `elements` 字段，1~2 个）。传数组就自动走双属性规则。
--
-- ---------------------------- 倍率约定 ----------------------------
--
--     2    克制        技能属性打对方是 2 倍
--     0.5  微弱        被对方抵抗
--     0    无效        对方免疫
--     1    中性        其余
--
-- 双属性还会出现 4 / 1.5 / 1.25 / 0.5 / 0.25 这些合并结果，见下一节。
--
-- ---------------------------- 双属性怎么算（重要） ----------------------------
--
-- 先把技能的属性分别打向受击精灵的**每一个**属性，拿到 1~2 个单属性倍率，
-- 再合并（`combine`）：
--
--     a == 2 且 b == 2    →  4              两个属性都被克 → 四倍克制
--     a == 0 或 b == 0    →  (a + b) / 4    其中一个免疫  → 在平均的基础上再砍一半
--     其余                →  (a + b) / 2    取平均
--
-- 也就是说：**"取平均"是通常情况，但不是全部**，上面两个特例是真的存在。
-- 这不是我们发明的规则，来源（赛尔号 WIKI 的 `Module:属性克制`）原文就是：
--
--     -- 计算 双属性 A·B 对 单属性 C 的系数
--     -- 符合官方规则：
--     --   两个系数都是 2 → 4
--     --   任一系数为 0 → (和)/4
--     --   其余           → (和)/2
--
-- 而且那段代码**两个方向共用**：既算"双属性打单属性"，也算"单属性打双属性"
-- （本站精灵页面显示"这个双属性精灵被打"用的就是同一条分支）——我们这个引擎
-- 属于后者，技能只有一个属性，双属性在受击方。
--
-- 具体几个例子：
--
--     getMultiplier("电", { "水", "飞行" })     == 4      2 和 2，四倍克制
--     getMultiplier("电", { "地面", "水" })     == 0.5    (0 + 2) / 4，**不是 1**
--     getMultiplier("地面", { "机械", "地面" }) == 1.5    (2 + 1) / 2，这个才是平均
--
-- 如果一律按"两个单属性取平均"算，上面第 2 条会算成 1（中性）、第 1 条会算成 2，
-- 四倍克制和免疫双双被吃掉——那正是项目规矩里说的"半对半错的克制表比没有更害人"。
-- 所以这里照来源实现，不按直觉简化。
--
-- 这条规则**有六个独立来源互相印证**（2011 → 2021：7k7k《赛尔号属性相克系数表》
-- 的实测、4399 2012 的公式整理、4399 2018 那篇带 12 场对局实测数据的、
-- seer.fandom 中文 wiki 的属性页、B 站专栏 cv6206519、以及上面那份 biligame 模块），
-- 没有找到任何一个说"相乘"或者"一律取平均"的来源。几个可靠的数字：
--
--   * 双属性的倍率范围是 [0.125, 4]；
--   * "两个都免疫"（0+0 → 0）在真实数据里**凑不出来**——26 个属性里每个最多只免疫
--     一个属性，所以 0 只会出现在单属性对单属性上；
--   * 取平均那一档才是我们平时见到最多的（1.5 / 1.25 / 0.75 …）。
--
-- 顺带记一笔：**双属性技能打双属性精灵**是另一套算法（两个中间值再取平均，没有
-- 那几个特例）。本引擎的技能只有 1 个属性，用不到；哪天真要加双属性技能，别直接
-- 复用下面的 `combine`。
--
-- ---------------------------- 报错策略 ----------------------------
--
-- 属性名写错（`"雷"` 这种）**直接 error**，不静默返回 1：静默返回中性的话，
-- 表现是"某个技能的伤害莫名其妙一直不对"，这种不报错的 bug 最难查，而且查出来
-- 也已经误导过人了。数据是静态的，名字错了应该在开发阶段就炸。
-- （想知道一个名字合不合法就问 `Elements.isValid`。）

local Chart = require "core.elements.chart"

--- 属性克制的查询函数集合。纯函数，没有状态。
---@class Elements
local Elements = {}

-- 倍率常量，和 chart.lua 里那组保持一致。查表本身不需要它们（值直接从 CHART 里读），
-- 只有 `combine` 判特例和空属性兜底时用得上；四个写全是为了和倍率约定一眼对上。
local NEUTRAL, STRONG, WEAK, IMMUNE = 1, 2, 0.5, 0

--- CHART[攻击属性][防御属性] = 倍率（中性项是显式的 1，不会是 nil）
---@type table<string, table<string, number>>
local CHART = Chart.CHART

--- 保序的属性名（顺序同 chart.lua 的 ELEMENTS）
---@type string[]
local ELEMENT_NAMES = Chart.ELEMENT_NAMES

--- name --> ElementEntry
---@type table<string, ElementEntry>
local BY_NAME = {}
for i = 1, #Chart.ELEMENTS do BY_NAME[Chart.ELEMENTS[i].name] = Chart.ELEMENTS[i] end

--- 排好序的属性名，加载时算一次。`list()` 每次返回它的拷贝，见那边的注释。
---@type string[]
local SORTED_NAMES = {}
for i = 1, #ELEMENT_NAMES do SORTED_NAMES[i] = ELEMENT_NAMES[i] end
table.sort(SORTED_NAMES)

--- 属性名不合法时报错。文案只有这一处，免得三处各写一套说法。
---@param who string @ "攻击属性" / "防御属性" / "属性"
---@param name any @ 拿到的那个值（已经是错的了，只用来打印）
---@param level integer @ error 的层级，让报错指向真正写错名字的那行调用
local function badName(who, name, level)
  local shown = type(name) == "string" and ("\"" .. name .. "\"") or tostring(name)
  error(("属性克制：%s不是赛尔号的属性（拿到了 %s）。全部合法属性见 Elements.list()")
    :format(who, shown), level)
end

--- 查一个"单属性 → 单属性"的倍率。内部用，`CHART` 的完整性由 chart.lua 保证，
--- 这里只管名字合不合法。
---@param attack string @ 攻击属性名
---@param defend string @ 防御属性名
---@return number multiplier @ 2 / 1 / 0.5 / 0
local function single(attack, defend)
  local row = CHART[attack]
  if row == nil then badName("攻击属性", attack, 3) end
  local value = row[defend]
  if value == nil then badName("防御属性", defend, 3) end
  return value
end

--- 双属性的合并规则，见文件头"双属性怎么算"。
---@param a number @ 技能属性打受击方第一个属性的倍率
---@param b number @ 技能属性打受击方第二个属性的倍率
---@return number multiplier @ 合并后的倍率（4 / 1.5 / 1.25 / 0.5 / 0.25 …）
local function combine(a, b)
  if a == STRONG and b == STRONG then return 4 end
  if a == IMMUNE or b == IMMUNE then return (a + b) / 4 end
  return (a + b) / 2
end

--- 算属性倍率。技能只有一个属性，受击精灵有 1~2 个。
---
--- `defend` 传字符串就是单属性：直接查表，返回 2 / 1 / 0.5 / 0。
--- 传数组就是（双）属性：对每个属性各查一次再合并（见文件头）。
--- 空数组当"没有属性关系"，返回中性 1（pet.lua 对没写属性的种族已经会告警）。
---
--- 名字不合法会 error，不会静默返回 1。
---@param attack string @ 技能的属性，单个，如 "电"
---@param defend string|string[] @ 受击精灵的属性：字符串 = 单属性；数组 = 1~2 个属性
---@return number multiplier @ 倍率
function Elements.getMultiplier(attack, defend)
  if type(defend) == "string" then
    return single(attack, defend)
  end
  if type(defend) ~= "table" then
    error(("属性克制：getMultiplier 的第二个参数要么是属性名，要么是属性名数组，拿到的是 %s")
      :format(type(defend)), 2)
  end

  -- 用 # 取长度：spec 里的 elements 都是 `{ "水", "飞行" }` 这种正常数组
  local n = #defend
  if n == 0 then
    return NEUTRAL
  elseif n == 1 then
    return single(attack, defend[1])
  elseif n > 2 then
    -- 赛尔号的精灵最多 2 个属性。多出来的不是"可以算"，而是数据写错了，
    -- 与其悄悄只取前两个，不如当场说清楚。
    error(("属性克制：赛尔号的精灵最多 2 个属性，这只写了 %d 个（%s）")
      :format(n, table.concat(defend, " + ")), 2)
  end
  return combine(single(attack, defend[1]), single(attack, defend[2]))
end

--- 全部属性名，**按字符串排序**返回。
--- 每次返回一份新拷贝：调用方拿去排序、删改都不会动到内部那份数据。
---@return string[] names @ 排序后的属性名数组
function Elements.list()
  local names = {}
  for i = 1, #SORTED_NAMES do names[i] = SORTED_NAMES[i] end
  return names
end

--- 取一个属性的原始数据。
--- 返回的是 chart.lua 里那一份（**只读，别改**；要改自己拷贝）。
---@param name string @ 属性名
---@return ElementEntry entry @ `{ name, strong, weak, immune }`，见 chart.lua 的字段说明
function Elements.get(name)
  local entry = BY_NAME[name]
  if entry == nil then badName("属性", name, 2) end
  return entry
end

--- 这个名字认不认识。任何非字符串都是 false，不会报错。
---@param name any @ 想查的值（字符串以外一律 false，方便直接拿协议里的字段来问）
---@return boolean valid
function Elements.isValid(name)
  return type(name) == "string" and BY_NAME[name] ~= nil
end

return Elements

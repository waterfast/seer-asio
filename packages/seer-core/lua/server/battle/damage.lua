-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 伤害计算 ============================
--
-- 只有**一个**函数：给定攻防双方和技能，算出这一下的基础伤害。
-- 它不算"最终伤害"——最终伤害是伤害链上一堆时机改出来的：
-- 克制、暴击、本系加成在这里算，而"受到伤害减半""改成固定伤害"这类
-- 是挂在 DetermineDamage 时机上的效果干的（见 events.lua / effect.lua）。
--
-- 为什么单独一个文件：这套数值是**最常被调**的东西。平衡性调整只该动这里，
-- 而不该在战斗流程里到处找 `* 1.5`。同理，下面所有常量都做成可覆盖的字段
-- （`Damage.STAB = 1.5`），改数值不用改逻辑。
--
-- 注意：下面的公式是主流回合制的通行形式（等级项 × 威力 × 攻防比 ÷ 50 + 2，
-- 再乘各系数），**具体系数需要和赛尔号的实际结算核对**。核对之后只需改这里的
-- 常量，不用碰任何调用方。

Damage = {}

Damage.STAB = 1.5         -- 本系加成：技能属性和精灵本属性相同时的加成
Damage.CRIT_MULTIPLIER = 2.0 -- 暴击倍率
Damage.CRIT_RATE = 1 / 16  -- 基础暴击率（百分数形式见 getCritChance）
Damage.RANDOM_MIN = 0.85  -- 随机浮动下限（0.85 ~ 1.00）

--- 暴击率（百分数）。
--- 暴击等级：0 级 = 基础值，每 +1 级翻倍（1/16 → 1/8 → 1/4 → 1/2 → 必定）。
---@param crit_stage? integer
---@return number @ 0~100
function Damage.getCritChance(crit_stage)
  crit_stage = crit_stage or 0
  if crit_stage <= 0 then
    return Damage.CRIT_RATE * 100
  end
  local rate = Damage.CRIT_RATE * (2 ^ math.min(crit_stage, 4))
  return math.min(100, rate * 100)
end

--- 算出一击的基础伤害。
---@param logic BattleLogic @ 要拿它的 rng（随机浮动必须走确定性随机）
---@param opts table @ 见下
---@field opts.source Pet? @ 攻击方；nil 表示"无来源"的固定伤害
---@field opts.target Pet @ 受击方
---@field opts.skill Skill? @ 用的技能
---@field opts.power integer? @ 直接给威力（没有技能对象时用）
---@field opts.category? SkillCategory
---@field opts.element? string @ 伤害属性；nil 则取技能属性
---@field opts.fixed integer? @ 固定伤害：直接返回这个数，不吃克制/暴击/本系
---@field opts.is_status_damage? boolean @ 异常状态伤害：不吃克制/暴击/本系
---@param crit_stage? integer
---@return table @ `{ damage, effectiveness, element, crit, stab }`
---@return table @ `{ damage, effectiveness, element, crit, stab }`
function Damage.calculate(logic, opts, crit_stage)
  local target = opts.target
  local ret = {
    damage = 0,
    effectiveness = Element.NORMAL,
    element = opts.element,
    crit = false,
    stab = false,
  }

  -- 固定伤害：不参与任何倍率计算
  if opts.fixed ~= nil then
    ret.damage = math.max(0, math.floor(opts.fixed))
    return ret
  end

  local skill = opts.skill
  local power = opts.power or (skill and skill:getPower(opts.source, target)) or 0
  local category = opts.category or (skill and skill.category) or Skill.Physical

  -- 增伤（官方的 37/42/88 那种）：前置效果会把倍率写进 ctx，
  -- UseSkill 再把它交到这里。必须在这里乘，因为"威力"是公式的输入，
  -- 等伤害算完再改就成了"改结果"，语义不一样（也绕不过后面的减伤）。
  if opts.power_multiplier and opts.power_multiplier ~= 1 then
    power = power * opts.power_multiplier
  end

  -- 属性技 / 威力 0：不造成伤害
  if category == Skill.Status or power <= 0 then
    return ret
  end

  local source = opts.source
  if source == nil then
    -- 没有来源就没有攻防比可言，只能当固定伤害处理
    ret.damage = math.max(0, math.floor(power))
    return ret
  end

  local element = opts.element or (skill and skill:getElement(source))
  ret.element = element

  -- 1) 攻防比：物理看攻击/防御，特殊看特攻/特防。
  --    直接读 Pet 的字段——那几个字段里已经含了性格修正和能力等级，
  --    所以这里不需要（也不该）再乘一次倍率。
  local atk_field, def_field
  if category == Skill.Special then
    atk_field, def_field = "sp_attack", "sp_defense"
  else
    atk_field, def_field = "attack", "defense"
  end
  local atk = math.max(1, source[atk_field])
  local def = math.max(1, target[def_field])

  -- 2) 基础伤害
  local base = math.floor(math.floor((2 * source.level / 5 + 2) * power * atk / def) / 50) + 2

  -- 3) 本系加成
  if element and source.species and table.contains(source.species.elements, element) then
    base = base * Damage.STAB
    ret.stab = true
  end

  -- 4) 属性克制（双属性相乘，0 就是免疫）
  local effectiveness = Element.NORMAL
  if element and not opts.is_status_damage then
    effectiveness = Element.getMultiplier(element, target.species and target.species.elements)
  end
  ret.effectiveness = effectiveness
  base = base * effectiveness

  -- 5) 暴击
  if not opts.is_status_damage then
    local chance = Damage.getCritChance(crit_stage)
    if chance >= 100 or logic.rng:chance(chance) then
      base = base * Damage.CRIT_MULTIPLIER
      ret.crit = true
    end
  end

  -- 6) 随机浮动。**必须**用 logic.rng：这一发伤害是可回放的一部分
  if not opts.is_status_damage then
    base = base * (Damage.RANDOM_MIN + logic.rng:randomFloat() * (1 - Damage.RANDOM_MIN))
  end

  ret.damage = math.max(1, math.floor(base))
  -- 免疫就是 0，不能被上面那个 max(1, ...) 救回来
  if effectiveness == Element.IMMUNE then
    ret.damage = 0
  end
  return ret
end

return Damage

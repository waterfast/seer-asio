-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 王·雷伊 / 王·盖亚 技能效果 ============================
--
-- 本文件只放**现有核心能干净表达**的效果；技能定义见同目录 skills.lua，
-- 数据来源与取舍依据见 init.lua 的注释，表达不了的条目逐条记在
-- docs/unimplemented-effects.md。
--
-- 写法沿用 standard/effects/thunder_awakening.lua 的"临时状态"模式：
--   * Effect 定义是全场共享的，**不保存任何局内状态**（次数、过期回合都不写进来）；
--   * 局内状态写在 pet 上，用 `wang_` 前缀，避免和别的包撞名；
--   * 需要跨回合存在的效果，由技能效果在触发时挂到 pet 上（pet:addEffect），
--     用完或过期时摘掉（pet:removeEffect）。
--
-- 技能效果由 GameLogic:buildEffectHandler 收集：技能挂的效果 owner = 使用者，
-- pet 挂的效果 owner = 该 pet。所以下面用 ctx.owner / ctx.source / ctx.data.target
-- 区分"使用者自己"和"被打的那只"。

--- 对手能力下降等级总和（返回正数）。现有核心没有这个查询，按能力项现算。
--- "一种能力"= Pet.STAT_STAGE_FIELDS 里的一项，几级就是几。
---@param pet Pet
---@return integer
local function negativeStageSum(pet)
  local sum = 0
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    local stage = pet:getStatStage(field)
    if stage < 0 then sum = sum - stage end
  end
  return sum
end

-- ---------------------------- 王·雷伊 ----------------------------

-- 惊颤霹雳（19732）：100%概率额外附加500点固定伤害。
-- 实现在伤害公式之后追加：固定伤害不吃属性克制倍率，也不会被暴击翻倍
-- （公式里的暴击翻倍在 AfterDamageCalculate 之前就做完了）。
local shock_flat = Seer:createEffect{
  id = "wang_shock_flat_500",
  name = "惊颤霹雳·附加500固定伤害",
  timing = SeerTiming.AfterDamageCalculate,
  can_trigger = function(_, ctx)
    -- 只在自己打出有效伤害时追加，伤害被防止时本时机根本不会到。
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage > 0
  end,
  on_use = function(_, ctx)
    ctx.data.damage = ctx.data.damage + 500
  end,
}

-- 金翼剑轮（19731）：免疫下1次受到的攻击。
-- 核心没有"免疫次数/护盾"系统，这里按项目的临时状态模式模拟：
--   命中时给使用者挂一个计数 + 一个常驻免疫效果；下一次受到的攻击在 BeforeAttack
--   被整体取消（多段攻击也只消耗一次），然后计数清零、效果摘掉。
-- 注意"攻击"只走攻击流程：属性技不经过 resolveAttack，不会被这条免疫挡。
local immune_attack = Seer:createEffect{
  id = "wang_guard_immune_attack",
  name = "金翼剑轮·免疫一次攻击",
  timing = SeerTiming.BeforeAttack,
  can_trigger = function(_, ctx)
    return ctx.owner == ctx.data.target and (ctx.owner.wang_immune_attacks or 0) > 0
  end,
  on_use = function(effect, ctx)
    ctx.owner.wang_immune_attacks = nil
    ctx.owner:removeEffect(effect)
    ctx.data.prevented = true
    -- 攻击被整体取消时不发 DamagePrevented，这里补一条，便于测试与 UI 观察。
    ctx.logic:notify{
      type = "AttackImmune", target = ctx.owner, source = ctx.data.source, skill = ctx.data.skill.name,
    }
  end,
}
local guard_grant = Seer:createEffect{
  id = "wang_guard_grant",
  name = "金翼剑轮",
  timing = SeerTiming.SkillUsed,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner
  end,
  on_use = function(_, ctx)
    -- 重复使用只刷新为 1 次，不叠加（免疫效果按引用挂载，重复 addEffect 不生效）。
    ctx.owner.wang_immune_attacks = 1
    ctx.owner:addEffect(immune_attack)
  end,
}

-- 天威力破（30155）后半段：若造成的伤害不足280，则下2回合的攻击必定致命一击。
-- 前半段（消除对手回合类效果、免疫异常状态）核心表达不了，见 unimplemented 文档。
-- 判定用 Attack 时机（扣血之后），data.damage 是本次攻击实际造成的总伤害。
-- crit_guarantee / crit_expire 先声明：tianwei_mark 的闭包在执行时要引用它们。
local crit_guarantee, crit_expire
local tianwei_mark = Seer:createEffect{
  id = "wang_tianwei_crit_mark",
  name = "天威力破·伤害不足280",
  timing = SeerTiming.Attack,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage < 280
  end,
  on_use = function(_, ctx)
    -- "下2回合"不含当回合：记下发动回合，之后两个回合内生效。
    ctx.owner.wang_crit_guarantee = {
      logic = ctx.logic,
      start_round = ctx.logic.round,
      expires_after_round = ctx.logic.round + 2,
    }
    ctx.owner:addEffect(crit_guarantee)
    ctx.owner:addEffect(crit_expire)
  end,
}

-- 必暴击的结算点：把本次伤害的致命概率抬到 100%（CriticalChanceCalculate 之后才掷骰）。
crit_guarantee = Seer:createEffect{
  id = "wang_tianwei_guaranteed_crit",
  name = "天威力破·下两回合必致命",
  timing = SeerTiming.CriticalChanceCalculate,
  can_trigger = function(_, ctx)
    local state = ctx.owner.wang_crit_guarantee
    return ctx.source == ctx.owner and state ~= nil and state.logic == ctx.logic
      and ctx.logic.round > state.start_round and ctx.logic.round <= state.expires_after_round
  end,
  on_use = function(_, ctx)
    ctx.data.crit_chance = 100
  end,
}

-- 过期清理：第 start+2 回合结束后摘掉状态与两个常驻效果。
crit_expire = Seer:createEffect{
  id = "wang_tianwei_crit_expire",
  name = "天威力破·必致命结束",
  timing = SeerTiming.TurnEnd,
  can_trigger = function(_, ctx)
    local state = ctx.owner.wang_crit_guarantee
    return state ~= nil and state.logic == ctx.logic and ctx.logic.round >= state.expires_after_round
  end,
  on_use = function(_, ctx)
    ctx.owner.wang_crit_guarantee = nil
    ctx.owner:removeEffect(crit_guarantee)
    ctx.owner:removeEffect(crit_expire)
  end,
}

-- ---------------------------- 王·盖亚 ----------------------------

-- 威斗天罡破（30157）后半段：造成的伤害提升，倍数 = 对手能力下降等级总和 × 10%。
-- 前半段"对手处于能力下降状态时自身先制+1"要在出手排序之前生效，核心排不了，见文档。
local weidou_boost = Seer:createEffect{
  id = "wang_weidou_debuff_boost",
  name = "威斗天罡破·按对手负等级增伤",
  timing = SeerTiming.AfterDamageCalculate,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage > 0
      and negativeStageSum(ctx.data.target) > 0
  end,
  on_use = function(_, ctx)
    local stages = negativeStageSum(ctx.data.target)
    ctx.data.damage = math.floor(ctx.data.damage * (1 + 0.1 * stages))
  end,
}

-- 王·联盟审判[追加]（30185）后半段：造成的伤害不足300则下1次攻击造成的伤害提高100%。
-- 前半段"对大暗黑天长老造成的伤害提高50%"没有目标分类钩子，见文档。
-- damage_double 先声明：lianmeng_mark 的闭包在执行时要引用它。
local damage_double
local lianmeng_mark = Seer:createEffect{
  id = "wang_lianmeng_damage_mark",
  name = "王·联盟审判·伤害不足300",
  timing = SeerTiming.Attack,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage < 300
  end,
  on_use = function(_, ctx)
    ctx.owner.wang_damage_double = { logic = ctx.logic }
    ctx.owner:addEffect(damage_double)
  end,
}

-- 一次性翻倍：下一次由自己造成的有效伤害翻倍后立刻消耗（多段攻击只翻第一击）。
damage_double = Seer:createEffect{
  id = "wang_lianmeng_damage_double",
  name = "王·联盟审判·下次伤害翻倍",
  timing = SeerTiming.AfterDamageCalculate,
  can_trigger = function(_, ctx)
    local state = ctx.owner.wang_damage_double
    return ctx.source == ctx.owner and state ~= nil and state.logic == ctx.logic
      and not ctx.data.prevented and ctx.data.damage > 0
  end,
  on_use = function(effect, ctx)
    ctx.owner.wang_damage_double = nil
    ctx.owner:removeEffect(effect)
    ctx.data.damage = ctx.data.damage * 2
  end,
}

return {
  shock_flat = shock_flat,
  guard_grant = guard_grant,
  immune_attack = immune_attack,
  tianwei_mark = tianwei_mark,
  crit_guarantee = crit_guarantee,
  crit_expire = crit_expire,
  weidou_boost = weidou_boost,
  lianmeng_mark = lianmeng_mark,
  damage_double = damage_double,
}

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 王·雷伊 / 王·盖亚 技能效果 ============================
--
-- 本文件只放**现有核心能干净表达**（或按仓库既有模式模拟）的效果；技能定义见同目录
-- skills.lua，数据来源与取舍依据见 init.lua，表达不了的条目逐条记在
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

-- ---------------------------- 通用查询 / 写入 ----------------------------

--- 对手能力**下降等级**总和（返回正数）。30157 的原文是"等级总和"，所以按等级累加。
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

--- 处于能力**提升状态**的能力项数（每一项算 1，不看等级高低）。
--- 原文是"每处于一种能力提升状态"——"一种"指一项能力；与 30157 的"下降等级总和"不同，
--- 24970 万鸣齐闪的 10% 按项数算，不按等级数算。
---@param pet Pet
---@return integer
local function positiveStageKinds(pet)
  local count = 0
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    if pet:getStatStage(field) > 0 then count = count + 1 end
  end
  return count
end

--- 1v1 演示对战里的"对手"：房间里除了自己以外的第一只精灵。
---@param room BattleRoom
---@param pet Pet
---@return Pet?
local function opponentOf(room, pet)
  for _, other in ipairs(room:getPets()) do
    if other ~= pet then return other end
  end
  return nil
end

--- "全属性 +stages"。赛尔号语境下的"全属性"就是六项：
--- 攻击 / 防御 / 特攻 / 特防 / 速度 / 命中，正好等于 Pet.STAT_STAGE_FIELDS
--- （交叉旁证：24120 战神狂怒的原文把"全属性"逐项写成这六项）。
---@return StatStageChangeData
local function raiseAllStats(room, pet, stages, source, reason)
  local changes = {}
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do changes[field] = stages end
  return room:changeStatStages(pet, changes, source, reason)
end

--- 反转自身能力下降：把每个负等级抬到它的相反数（-n → +n），正等级与 0 不动。
---
--- 核心没有 `BattleRoom:reverseStatStages`（core/events/stat_stage.lua 只定义了
--- operation="reverse" 的数据契约与 Before/AfterStatStagesReverse 时机，写明"本次不提供
--- Room 反转函数"）。这里用"增量 = -2×当前等级"的组合近似，**结果数值与反转一致**，
--- 但走的是普通 `change` 操作、发 operation="change" 的通知，也没有专用的反转前后时机。
--- 这是"解除能力下降"的语义边界：单看数值是干净的，时机与操作类型是近似。
--- 待核心提供 reverseStatStages 时应迁移（见 docs/unimplemented-effects.md）。
---@return boolean reversed @ 是否真的存在负等级
local function reverseNegativeStages(room, pet, source, reason)
  local changes = {}
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    local stage = pet:getStatStage(field)
    if stage < 0 then changes[field] = -2 * stage end
  end
  if next(changes) == nil then return false end
  room:changeStatStages(pet, changes, source, reason)
  return true
end

-- ============================ 王·雷伊 ============================

-- 惊颤霹雳（19732）：100%概率额外附加500点固定伤害。
-- 攻击造成有效伤害后另发一次固定伤害；有独立的伤害/HP 时机，不吃攻击增伤与暴击。
local shock_flat = Seer:createEffect{
  id = "wang_shock_flat_500",
  name = "惊颤霹雳·附加500固定伤害",
  timing = SeerTiming.AfterAttack,
  can_trigger = function(_, ctx)
    -- 被免疫、没有有效攻击伤害或目标已倒下时不追加。
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage > 0
      and not ctx.logic:isFainted(ctx.data.target)
  end,
  on_use = function(effect, ctx)
    ctx.room:damage{ source = ctx.source, target = ctx.data.target, skill = ctx.data.skill,
      kind = "fixed", damage = 500, reason = effect.name, parent = ctx.data }
  end,
}

-- 传承王意（24971）可做的那一段：全属性+1，自身当前体力低于对手时强化效果翻倍。
-- "体力低于对手"按**当前体力绝对值**比较（原文措辞），不看百分比；
-- skill target = "self"，所以对手要从房间对象里找。
-- 持续回复已有 Buff 基础但本技能尚未接线；异常状态系统未实现，见技能 extra 与文档。
local chuancheng_boost = Seer:createEffect{
  id = "wang_chuancheng_all_stats",
  name = "传承王意·全属性强化",
  timing = SeerTiming.SkillUsed,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner
  end,
  on_use = function(effect, ctx)
    local foe = opponentOf(ctx.room, ctx.owner)
    local stages = (foe ~= nil and ctx.owner.hp < foe.hp) and 2 or 1
    raiseAllStats(ctx.room, ctx.owner, stages, ctx.source, effect.name)
  end,
}

-- 万鸣齐闪（24970）第一段：反转自身能力下降状态。
local wanming_reverse = Seer:createEffect{
  id = "wang_wanming_reverse",
  name = "万鸣齐闪·反转自身能力下降",
  timing = SeerTiming.SkillUsed,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner
  end,
  on_use = function(effect, ctx)
    reverseNegativeStages(ctx.room, ctx.owner, ctx.source, effect.name)
  end,
}

-- 万鸣齐闪（24970）第三段的数学：自身每处于一种能力提升状态，让"直接造成的伤害"提高 10%。
-- 这段本身是干净的（项数 ×10%），但**没有载体**：它要乘的是"直接造成 260 点电系伤害"，
-- 目前该技能仍未接线。核心已提供 room:damage；后续需核对电系固定伤害规则，
-- 在技能效果中计算数值并调用该入口，不能把这段攻击增伤直接挂给属性技。
local wanming_stage_boost = Seer:createEffect{
  id = "wang_wanming_stage_boost",
  name = "万鸣齐闪·按能力提升项增伤",
  timing = SeerTiming.AfterDamageCalculate,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage > 0
      and positiveStageKinds(ctx.owner) > 0
  end,
  on_use = function(_, ctx)
    ctx.data.damage = math.floor(ctx.data.damage * (1 + 0.1 * positiveStageKinds(ctx.owner)))
  end,
}

-- 第五技能共同段（19734 王·万霆朝宗 / 30158 王·圣勇战意）：
-- 攻击时造成的伤害不会出现微弱。克制倍率在 DamageParamCalculate 时已由 Elements 算好，
-- 这里把 (0,1) 区间抬回 1；0（无效/免疫）不动——"不微弱"不等于"无视免疫"。
-- 两个第五技能共享这一个定义（技能各自挂引用，效果只在使用的那个技能上被收集）。
local fifth_no_weak = Seer:createEffect{
  id = "wang_fifth_no_weak",
  name = "第五技能·伤害不出现微弱",
  timing = SeerTiming.DamageParamCalculate,
  can_trigger = function(_, ctx)
    local multiplier = ctx.data.multiplier or 1
    return ctx.source == ctx.owner and multiplier > 0 and multiplier < 1
  end,
  on_use = function(_, ctx)
    ctx.data.multiplier = 1
  end,
}

-- 王·万霆朝宗（19734）第四段：未击败对手则自身全属性+1。
-- AfterAttack 在整次攻击（含每击扣血）之后触发一次，此时判定目标是否还活着；
-- 未命中不会走到 AfterAttack（UseSkill 的未命中分支只发 AttackEnd）。
local wanting_survive = Seer:createEffect{
  id = "wang_wanting_survive_all_stats",
  name = "王·万霆朝宗·未击败对手则全属性+1",
  timing = SeerTiming.AfterAttack,
  can_trigger = function(_, ctx)
    return ctx.data.source == ctx.owner and not ctx.logic:isFainted(ctx.data.target)
  end,
  on_use = function(effect, ctx)
    raiseAllStats(ctx.room, ctx.owner, 1, ctx.source, effect.name)
  end,
}

-- ============================ 王·盖亚 ============================

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

-- 不败之境（25184）可做的那一段：全属性+1，自身当前体力高于最大体力的1/2时翻倍。
-- 判定是**严格大于** 1/2（hp*2 > max_hp）；恰好一半按 +1 处理。
-- 四回合吸血尚未接线；动态先制仍缺排序前修正入口，见技能 extra 与文档。
local bubai_boost = Seer:createEffect{
  id = "wang_bubai_all_stats",
  name = "不败之境·全属性强化",
  timing = SeerTiming.SkillUsed,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner
  end,
  on_use = function(effect, ctx)
    local pet = ctx.owner
    local stages = (pet.hp * 2 > pet.max_hp) and 2 or 1
    raiseAllStats(ctx.room, pet, stages, ctx.source, effect.name)
  end,
}

-- 极度冲刺（30156）：反转自身能力下降状态（组合近似，说明见文件头 helper）。
-- 它在 SkillUsed 结算（命中判定之后、伤害链之前），所以反转出来的正等级会参与本次伤害计算；
-- 原文没有说明结算先后，这里按"使用技能时先反转"处理，并在文档里记明。
local jidu_reverse = Seer:createEffect{
  id = "wang_jidu_reverse",
  name = "极度冲刺·反转自身能力下降",
  timing = SeerTiming.SkillUsed,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner
  end,
  on_use = function(effect, ctx)
    reverseNegativeStages(ctx.room, ctx.owner, ctx.source, effect.name)
  end,
}

-- 王·圣勇战意（30158）第二段：吸取对手能力提升状态。
-- "吸取"= 对手清掉正等级 + 同额加给自身；用现有 clearPositiveStatStages + changeStatStages
-- 组合，正是能力等级系统的语义（清正等级走 clear_positive，不冒充弱化）。
-- 后半句"吸取成功则吸取对手300点体力"尚未接线；伤害/回复基础已提供，见文档。
local shengyong_steal = Seer:createEffect{
  id = "wang_shengyong_steal_positive",
  name = "王·圣勇战意·吸取对手能力提升",
  timing = SeerTiming.AfterAttack,
  can_trigger = function(_, ctx)
    return ctx.data.source == ctx.owner and positiveStageKinds(ctx.data.target) > 0
  end,
  on_use = function(effect, ctx)
    local target = ctx.data.target
    local stolen = {}
    for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
      local stage = target:getStatStage(field)
      if stage > 0 then stolen[field] = stage end
    end
    if next(stolen) == nil then return end
    ctx.room:clearPositiveStatStages(target, ctx.source, effect.name)
    ctx.room:changeStatStages(ctx.owner, stolen, ctx.source, effect.name)
  end,
}

-- ============================ 参考技能（不占四格，效果保留）============================

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
  -- 王·雷伊
  shock_flat = shock_flat,
  chuancheng_boost = chuancheng_boost,
  wanming_reverse = wanming_reverse,
  wanming_stage_boost = wanming_stage_boost,
  fifth_no_weak = fifth_no_weak,
  wanting_survive = wanting_survive,
  -- 王·盖亚
  weidou_boost = weidou_boost,
  bubai_boost = bubai_boost,
  jidu_reverse = jidu_reverse,
  shengyong_steal = shengyong_steal,
  -- 参考技能
  guard_grant = guard_grant,
  immune_attack = immune_attack,
  tianwei_mark = tianwei_mark,
  crit_guarantee = crit_guarantee,
  crit_expire = crit_expire,
  lianmeng_mark = lianmeng_mark,
  damage_double = damage_double,
}

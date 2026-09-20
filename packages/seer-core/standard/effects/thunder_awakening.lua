-- SPDX-License-Identifier: GPL-3.0-or-later
-- 按本项目要求：攻击/速度 +2，三回合内致命概率增加 100 个百分点（封顶 100%）。
-- 持续期包含发动当回合，重用只刷新三回合，不叠加；状态属于精灵，不写入共享定义。
local critical = Seer:createEffect{
  id = "standard_thunder_critical", name = "雷神觉醒·致命",
  timing = SeerTiming.CriticalChanceCalculate,
  can_trigger = function(_, ctx)
    local state = ctx.owner.thunder_awakening
    return ctx.source == ctx.owner and state ~= nil and state.logic == ctx.logic
      and ctx.logic.round <= state.expires_after_round
  end,
  on_use = function(_, ctx)
    ctx.data.crit_chance = math.min(100, ctx.data.crit_chance + 100)
  end,
}
local expire
expire = Seer:createEffect{
  id = "standard_thunder_expire", name = "雷神觉醒·结束",
  timing = SeerTiming.TurnEnd,
  can_trigger = function(_, ctx)
    local state = ctx.owner.thunder_awakening
    return state ~= nil and state.logic == ctx.logic and ctx.logic.round >= state.expires_after_round
  end,
  on_use = function(_, ctx)
    ctx.owner.thunder_awakening = nil
    ctx.owner:removeEffect(critical)
    ctx.owner:removeEffect(expire)
  end,
}
return Seer:createEffect{
  id = "standard_thunder_awakening", name = "雷神觉醒",
  timing = SeerTiming.SkillUsed,
  on_use = function(effect, ctx)
    ctx.room:changeStatStages(ctx.owner, { attack = 2, speed = 2 }, ctx.source, effect.name)
    ctx.owner.thunder_awakening = { logic = ctx.logic, expires_after_round = ctx.logic.round + 2 }
    ctx.owner:addEffect(critical)
    ctx.owner:addEffect(expire)
  end,
}

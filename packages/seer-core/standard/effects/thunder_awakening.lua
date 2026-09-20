-- SPDX-License-Identifier: GPL-3.0-or-later
-- 按项目要求扩展：攻击/速度 +2，三回合致命概率 +100 个百分点（封顶 100%）。
-- 持续期包含发动当回合，重用刷新；状态由 Room 的 Buff 实例管理，不写进共享 Effect。
local critical = Seer:createEffect{
  id = "standard_thunder_critical", name = "雷神觉醒·致命",
  timing = SeerTiming.CriticalChanceCalculate,
  can_trigger = function(_, ctx) return ctx.source == ctx.owner end,
  on_use = function(_, ctx)
    ctx.data.crit_chance = math.min(100, ctx.data.crit_chance + 100)
  end,
}
return Seer:createEffect{
  id = "standard_thunder_awakening", name = "雷神觉醒",
  timing = SeerTiming.SkillUsed,
  on_use = function(effect, ctx)
    ctx.room:changeStatStages(ctx.owner, { attack = 2, speed = 2 }, ctx.source, effect.name)
    ctx.room:addBuff(ctx.owner, {
      id = "standard_thunder_awakening", name = "雷神觉醒·致命", source = ctx.source,
      duration = 3, category = "turn", effects = { critical },
    })
  end,
}

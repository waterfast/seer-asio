-- SPDX-License-Identifier: GPL-3.0-or-later
-- 当前技能每一击造成的伤害提高 50%，在公式计算后修改伤害，向下取整。
-- 效果定义由技能共享；具体伤害始终写入本次时机的 data。
return Seer:createEffect{
  id = "standard_damage_up_50",
  name = "伤害提升50%",
  timing = SeerTiming.AfterDamageCalculate,
  can_trigger = function(_, ctx)
    return ctx.source == ctx.owner and not ctx.data.prevented and ctx.data.damage > 0
  end,
  on_use = function(_, ctx)
    ctx.data.damage = math.floor(ctx.data.damage * 1.5)
  end,
}

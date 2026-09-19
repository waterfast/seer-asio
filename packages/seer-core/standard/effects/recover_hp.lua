-- SPDX-License-Identifier: GPL-3.0-or-later
-- 攻击后回复自身最大体力的 1/3，向下取整；恢复上限和濒死判定沿用 GameLogic。
return Seer:createEffect{
  id = "standard_recover_third",
  name = "回复三分之一体力",
  timing = SeerTiming.AfterAttack,
  can_trigger = function(_, ctx)
    return not ctx.logic:isFainted(ctx.owner) and ctx.owner.hp < ctx.owner.max_hp
  end,
  on_use = function(effect, ctx)
    ctx.logic:recover(ctx.owner, math.floor(ctx.owner.max_hp / 3), effect.name)
  end,
}

-- SPDX-License-Identifier: GPL-3.0-or-later
-- 攻击后令使用者的攻击能力等级 +1，最高 +6；不修改攻击面板。
return Seer:createEffect{
  id = "standard_attack_up_1",
  name = "攻击提升一级",
  timing = SeerTiming.AfterAttack,
  can_trigger = function(_, ctx)
    return not ctx.logic:isFainted(ctx.owner)
      and ctx.owner:getStatStage("attack") < Pet.STAT_STAGE_MAX
  end,
  on_use = function(_, ctx)
    ctx.room:changeStatStages(ctx.owner, { attack = 1 }, ctx.source, "攻击提升一级")
  end,
}

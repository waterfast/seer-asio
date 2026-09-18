-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 内置效果类型（注册点）============================
--
-- **"效果写在哪里"的答案就是这里。**
--
-- 一个技能/一条规则要用到的每一种"效果类型"，都在这份文件里用
-- `Effect.registerKind(key, def)` 登记一次，写清三件事：
--
--   * `validate(spec)`  —— 数据长什么样才算合法（加载期就报笔误，别等打到一半崩）
--   * `instant`         —— true = 当场结算；false = 挂到精灵身上持续生效
--   * `on_apply`        —— 结算体（instant 用）
--     `triggers`        —— 持续型挂在哪些时机上
--     `on_expire`       —— 回合数归零被清除时做什么
--
-- 加一种新效果**不用改核心**：在自己的文件里再调一次就行，扩展包也一样
-- （现成例子见 `lua/specs/standard/effects.lua`，那里注册了偷取能力等级、
-- 按最大体力比例造成伤害、封招、抵挡致死这类效果）。
--
-- `def.triggers` 里写的是**时机名**（字符串），因为时机类在
-- `server/battle/timing.lua` 里登记、core 不该反过来依赖 server；
-- 真正 install 时再解析成时机类（见 init.lua 的 `resolveKindTriggers`）。
--
-- 下面按"官方效果ID 的形状"分组，每条都注明了它对应官方的哪个效果，
-- 以后往技能表里抄数据时能对上号。

-- ---------- damage：造成伤害（立即）----------
Effect.registerKind("damage", {
  name = "伤害",
  instant = true,
  validate = function(spec)
    if type(spec.value) ~= "number" then
      return false, "damage 效果需要数字 value（伤害值）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    effect.logic:damage{
      source = effect.source,
      target = pet,
      fixed = effect.value,
      element = effect.element,
      reason = effect.name,
      skill = effect.extra.skill,
    }
  end,
})

-- ---------- heal：回复体力（立即）----------
Effect.registerKind("heal", {
  name = "回复",
  instant = true,
  validate = function(spec)
    if type(spec.value) ~= "number" and type(spec.ratio) ~= "number" then
      return false, "heal 效果需要 value（固定回复量）或 ratio（按最大体力的比例）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    -- 两种写法：写死数字（value），或者按最大体力比例（ratio，比如"回复最大体力的 1/3"）
    local amount = effect.value
    if type(effect.ratio) == "number" then
      amount = math.max(1, math.floor(pet.max_hp * effect.ratio))
    end
    effect.logic:recover{
      target = pet,
      num = amount,
      reason = effect.name,
    }
  end,
})

-- ---------- stat：能力等级变化（立即）----------
Effect.registerKind("stat", {
  name = "能力等级变化",
  instant = true,
  validate = function(spec)
    if type(spec.stages) ~= "table" then
      return false, "stat 效果需要 stages 表，如 { attack = 2 }"
    end
    for k, v in pairs(spec.stages) do
      if not Pet.STAGE_FIELDS_SET[k] then
        -- 注意用 STAGE_FIELDS 而不是 STAT_FIELDS：**体力没有能力等级**，
        -- 写成 `{ hp = 2 }` 是数据笔误，要在加载期就报出来
        return false, ("stages 里有不能改的项 %q（只能改攻击/防御/特攻/特防/速度）")
          :format(tostring(k))
      end
      if type(v) ~= "number" or v == 0 then
        return false, ("stages.%s 需要非 0 数字"):format(k)
      end
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    effect.logic:doStatChange{
      target = pet,
      stages = effect.stages,
      source = effect.source,
      reason = effect.name,
    }
  end,
})

-- ---------- drain：吸取（按造成的伤害给自己回血）----------
--
-- "按结果算"的效果必须读 ctx：spec 里写不出"刚刚打了多少"。
Effect.registerKind("drain", {
  name = "吸取",
  instant = true,
  validate = function(spec)
    if spec.ratio ~= nil and type(spec.ratio) ~= "number" then
      return false, "drain 的 ratio 需要数字（默认 0.5，即回复造成伤害的一半）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    local dealt = (ctx and ctx.damage) or 0
    if dealt <= 0 then return end   -- 没打出伤害就没什么可吸的
    local amount = math.max(1, math.floor(dealt * (effect.ratio or 0.5)))
    effect.logic:recover{ target = effect.source, num = amount, reason = effect.name }
  end,
})

-- ---------- recoil：反作用力（自己挨一部分）----------
Effect.registerKind("recoil", {
  name = "反作用力",
  instant = true,
  validate = function(spec)
    if spec.ratio ~= nil and type(spec.ratio) ~= "number" then
      return false, "recoil 的 ratio 需要数字（默认 1/3）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    -- 两种写法：按"造成了多少伤害"算（ratio），或者写死一个数（value）
    local amount
    if type(effect.value) == "number" then
      amount = effect.value
    else
      local dealt = (ctx and ctx.damage) or 0
      if dealt <= 0 then return end
      amount = math.max(1, math.floor(dealt * (effect.ratio or 0.34)))
    end
    effect.logic:damage{
      target = effect.source,
      fixed = amount,
      reason = effect.name,
      is_status_damage = true,   -- 不吃克制/暴击/本系
    }
  end,
})

-- ---------- cure：解除异常状态 ----------
--
-- 注意它只清**弱化类/控制类**（异常状态），不动增益印记——
-- 这是"异常状态 ⊂ 印记"这个设计带来的好处：两类挂在同一个表里，
-- 但语义上分得清，所以"解毒"不会顺手把护盾也拆了。
Effect.registerKind("cure", {
  name = "解除异常状态",
  instant = true,
  on_apply = function(effect, pet, ctx)
    local logic = effect.logic
    if effect.status then
      logic:cureStatus(pet, effect.status)
    else
      logic:cureStatus(pet)
    end
  end,
})

-- ---------- mark / status：给目标挂一个印记 ----------
--
-- 挂印记这件事**不在 effect 里做**，而是交给 `logic:applyMark`：
-- 免疫判定、已有印记的叠层、时机、通知、以及"印记之后自己怎么动"都在那边。
-- 效果只是"把印记挂上去"的那一下——技能负责挂，印记负责之后一直管。
Effect.registerKind("mark", {
  name = "印记（含异常状态）",
  instant = true,
  validate = function(spec)
    local key = spec.mark or spec.status
    if type(key) ~= "string" then
      return false, "mark 效果需要 `mark`（或 `status`）指定挂哪个印记"
    end
    if Mark.defs[key] == nil then
      return false, ("未注册的印记 %q（先用 Mark.register 定义它）"):format(key)
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    effect.logic:applyMark{
      target = pet,
      mark = effect.mark or effect.status,
      source = effect.source,
      turns = effect.duration,
    }
  end,
})

-- `status` 是 `mark` 的别名：一个 kind 两种写法，
-- 写"施加异常状态"时用 status 更顺，写"挂个增益印记"时用 mark 更顺。
Effect.registerKind("status", {
  name = "异常状态",
  alias_of = "mark",   -- 它只是 mark 的另一种写法
  instant = true,
  validate = Effect.kinds.mark.validate,
  on_apply = Effect.kinds.mark.on_apply,
})

-- ---------- clear_stages：消除能力等级（官方的"消强"(33) / "解弱"(3)）----------
--
-- 这两个官方效果**只有一个参数不同**（清对方的提升 / 清自己的下降），
-- 所以做成一个 kind + `side` 参数，而不是写两个 kind。
-- "消除成功则令对方烧伤"这种接在后面的效果用 `then_effects` 串起来。
Effect.registerKind("clear_stages", {
  name = "消除能力等级",
  instant = true,
  validate = function(spec)
    local side = spec.side or "up"
    if side ~= "up" and side ~= "down" and side ~= "all" then
      return false, "clear_stages 的 side 只能是 up（消强）/ down（解弱）/ all"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    local side = effect.side or "up"
    local cleared = {}
    for _, field in ipairs(Pet.STAGE_FIELDS) do
      local stage = pet:getStatStage(field)
      local hit = (side == "all")
        or (side == "up" and stage > 0)
        or (side == "down" and stage < 0)
      if hit and stage ~= 0 then
        pet:setStatStage(field, -stage)      -- 直接归零
        table.insert(cleared, field)
      end
    end

    if #cleared > 0 then
      effect.logic:notify{
        type = "StatCleared",
        target = pet.seat,
        fields = cleared,
        side = side,
        reason = effect.name,
      }
      -- 记进 ctx：跟在后面的效果（"消除成功则……"）靠它判断成没成
      ctx.extra = ctx.extra or {}
      ctx.extra.cleared_stages = cleared
    end
  end,
})

-- ---------- add_damage：附加固定伤害（官方的 29 / 38 / 60）----------
--
-- 29 = 额外附加 50 点固定伤害；38 = 降低对方 10 点最大体力；
-- 60 = "3 回合内每回合都能附加 30 点"（那个其实是挂一个印记，回合末打固定伤害）。
-- 这里做的是前两者的形状：**在本次伤害之外再打一笔固定伤害**。
Effect.registerKind("add_damage", {
  name = "附加固定伤害",
  instant = true,
  validate = function(spec)
    if type(spec.value) ~= "number" or spec.value <= 0 then
      return false, "add_damage 需要一个正的 value（附加多少点固定伤害）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    effect.logic:damage{
      target = pet,
      fixed = effect.value,
      reason = effect.name,
      is_status_damage = true,   -- 附加伤害不吃克制/暴击/本系
    }
  end,
})

-- ---------- power_modifier：增伤（官方的 37 / 42 / 88）----------
--
-- 37 = 自身 HP 小于 1/2 时威力 ×2；42 = 当局使用电系招式伤害 ×2；
-- 88 = 10% 概率伤害 ×4。三个都是"条件 + 倍率"，条件用 condition 写，倍率用 multiplier。
--
-- 注意它是 **phase = "before"** 的效果：增伤必须在**伤害算出来之前**改威力，
-- 所以 UseSkill 流程会先把 before 的效果跑完（攒一个 power_multiplier），再去打伤害。
Effect.registerKind("power_modifier", {
  name = "威力倍率（增伤）",
  instant = true,
  phase = "before",
  validate = function(spec)
    if type(spec.multiplier) ~= "number" or spec.multiplier <= 0 then
      return false, "power_modifier 需要正的 multiplier（比如 2 表示威力翻倍）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)
    ctx.power_multiplier = (ctx.power_multiplier or 1) * effect.multiplier
  end,
})

-- ---------- modifier：修正某个时机的数值（持续）----------
-- 例："接下来 3 回合受到的伤害减半"
--   { kind = "modifier", duration = 3, probability = 100,
--     extra = { timing = "DetermineDamage", apply = function(effect, data) data:changeDamage(-...) end } }
Effect.registerKind("modifier", {
  name = "数值修正",
  instant = false,
  validate = function(spec)
    local ev = spec.extra and spec.extra.timing
    if ev == nil then
      return false, "modifier 效果需要在 extra.timing 里写明修正哪个时机"
    end
    local fn = spec.extra and spec.extra.apply
    if type(fn) ~= "function" then
      return false, "modifier 效果需要在 extra.apply 里写明怎么改数据"
    end
    return true
  end,
  triggers = "MODIFIER",
})

-- ============================ 目录 ============================
--
-- 内置效果类型的清单（也当"现在有哪些效果可用"的目录）：
--   damage          伤害（固定值）
--   heal            回复（固定值 / 按最大体力比例）
--   stat            能力等级变化
--   drain           吸取（按本次造成的伤害给自己回血）
--   recoil          反作用力
--   cure            解除异常状态
--   mark / status   挂印记（含异常状态）；status 是 mark 的别名
--   clear_stages    消除能力等级（消强 / 解弱）
--   add_damage      附加固定伤害（官方 29 / 38 / 60 的形状）
--   power_modifier  威力倍率（增伤，phase = "before"）
--   modifier        修正某个时机的数值（持续型）
return {
  "damage", "heal", "stat", "drain", "recoil", "cure",
  "mark", "status", "clear_stages", "add_damage", "power_modifier", "modifier",
}

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ standard 包：技能与印记 ============================
--
-- 雷伊、盖亚的**真实技能表**（来源：赛尔号 WIKI，wiki.biligame.com/seer/雷伊 与 /盖亚）。
-- 名字、图鉴ID、学习等级、先制、威力、PP、命中、物理/特殊/属性 都是抄的。
--
-- ---------------------------- 这份数据在演示什么 ----------------------------
--
-- 它同时是**"效果可复用"的活教材**——看看官方是怎么用同一批效果拼出这 37 个技能的：
--
--   * 官方每个技能挂的是「**效果ID + 参数**」：
--       33 = 消强（消除对手能力提升状态）
--        3 = 解弱（解除自身能力下降状态）
--        4 = 强化（改变自身能力等级）      5 = 弱化（改变对手能力等级）
--       10 = 施加异常（命中后 N% 令对方 XX）  29/38/60 = 附加伤害
--       31 = 连击                        37/42/88 = 增伤（条件 + 倍率）
--       43 = 恢复   46 = 抵挡
--   * **同一批效果，参数不同就是不同技能**：电击光束/放电/电闪雷鸣/霹雳斩/极电千鸟/瞬雷天闪
--     全都是"命中后 5% 令对方麻痹"，只有威力/PP/命中不同；雷祭则是"100% 麻痹但命中只有 50%"。
--   * "消除对手能力提升状态"（消强）在盖亚身上出现了两次（日月皆伤 / 石破天惊），
--     区别只有威力——所以它就该是**一个 Effect + 一个参数**，不是两段代码。
--
-- 每个技能上方那行注释（"弱化：100% 对手防御 -1"、"恢复：恢复自身最大体力的 1/3" …）
-- 就是**官方效果的中文说明**，保留下来当"这里该填什么效果"的清单，见下一节。
--
-- ---------------------------- 效果怎么填（effects 字段）----------------------------
--
-- **`kind = ...` 那套写法已经全部删掉了**：那是**已被删除的效果类型系统**
-- （原 core/effect/kinds.lua）的遗留数据——它既不会被校验也不会被执行
-- （`Skill` 只是原样存着这串东西），留着只会让人以为它有用。所以本文件里现在
-- 一条 `effects = { { kind = ... } }` 都不剩，对应技能都退化成**纯数值**：
--
--     { name = "神经修复", id = 20309, category = Skill.Status, pp = 10, accuracy = 0,
--       target = "self" },
--
-- 现在 `Skill.effects` 里装的必须是 **Effect 实例**——用 `Seer:createEffect{ ... }`
-- 现场造出来的对象（id / name / reason / timing / can_trigger / on_cost / on_use），
-- 触发由战斗逻辑负责（`GameLogic:buildEffectHandler` 收集 → `EffectHandler` 执行）。
-- 写法示范见文件末尾「效果链路演示（非官方数据）」那一段（`heal_demo`）。
--
-- ⚠ **等 kinds.lua（效果类型表：消强 / 弱化 / 施加异常 / 附加伤害那一批可复用效果）
--   按新的 Effect 体系重建之后，要照着每个技能上方的注释把效果一条条填回来。**
--   现在先空着：空着只是"这个技能只有数值"，填错成 kind 数据才是真的会出事。
--
-- ---------------------------- 还没能一比一还原的地方 ----------------------------
--
-- * 「灭生啸」官方是"降低对方 10 点战斗时的最高体力"，暂时用**附加 10 点固定伤害**
--   近似（要真做需要"最大体力变化"的机制）。
-- * 「末日宣告」官方是"3 回合内每回合都能附加 30 点固定伤害"——这是挂在回合结束时机上的
--   持续 Effect（本文件原来用 `dot30` 这个包内印记演示，那段已删）。
-- * 「惊雷切」的增伤官方是"自身 HP 小于 1/2 时威力 ×2"，原来的条件写的是
--   `ctx.source:getHpRatio() < 0.5`——`pet:getHpRatio()` 已随重构从 Pet 上删除
--   （当前体力现在由战斗逻辑管，见 server/gamelogic.lua 的 `pet.hp` / `pet.max_hp`），
--   所以这条效果暂时没填。
-- * 特性（魂印）没抄，见 species.lua 的 TODO。
--
-- ---------------------------- 重构后的状态（必读）----------------------------
--
-- 这份表**只保留纯数据**（名字 / 图鉴id / 属性 / 类别 / 威力 / PP / 命中 / 先制 /
-- 暴击率 / hits）+ 末尾那一段演示 Effect，所以能被 `Seer:createSkill` 直接吃进去。
-- 被清掉的东西都指向已随重构删除的机制，留着就是死引用：
--
--   1. **全部 `effects = { { kind = ... } }`**（见上面"效果怎么填"）；
--   2. **旧的 `marks = {...}`（charge / dot30 两个包内印记）**：`Mark.register` /
--      `Seer:addMark` 现在都不存在（core/mark 依赖的 `OwnedTrigger` 还没重建），
--      `[SeerTiming.DetermineDamage]` / `[SeerTiming.RoundEnd]` 这些旧时机名也不存在
--      （现在的时机是 core/events 里那 18 个类）。旧内容见 git 历史。
--   3. **两个"特性"占位技能（静电庇护 / 不灭战意）**：它们用
--      `tags = { Skill.Ability, Skill.Compulsory }`（这两个常量从来没定义过）
--      和 `pet:getHpRatio()/isFainted()/getStatStage()`（Pet 上已删除）。

-- ============================ 效果链路演示（非官方数据）============================
--
-- 下面这一个 Effect + 一个挂它的技能，**都不是官方数据**，唯一的作用是让
-- 「技能的 effects → GameLogic:triggerEffects → EffectHandler → Effect:use → logic」
-- 这条链路真的跑起来一遍（`GameLogic:run()` 里能看见它把血加回去）。
-- 等 kinds.lua 重建、上面那些技能都按新写法补上效果之后，**整段删掉**。
--
-- 写法要点：
--   * 用 `Seer:createEffect` 造：走这一个入口，引擎才知道自己有哪些效果
--     （`Effect:new` 也能造出对象，但那样它就不在 `Seer.effects` 这份目录里了）；
--   * `timing` 用**时机类**（`SeerTiming.AfterAttack`，见 core/events）；EffectHandler
--     比的是 `effect:getTiming() == timing`（**同一个对象/同一个字符串**），
--     所以"调用方传什么，这里就得写什么"。`SeerTiming` 还没就绪时退化成字符串
--     `"AfterAttack"`——那样就要求调用方也传同名串（GameLogic 传的是时机类）。
--   * `on_use(effect, ctx)` 的 ctx 由调用方给：`logic`（战局）/ `source`（用技能的那只）
--     / `target` / `skill` / `damage`（本次攻击造成的总伤害）。
--
-- 注意它**在文件加载期**就造好了（下面的技能表要直接引用这个局部变量），
-- 所以 spec 文件被 dofile 的时候就会往 `Seer.effects` 里登记一条 effect。
local heal_demo = Seer:createEffect{
  id = "heal_demo",
  name = "恢复",
  reason = "演示：攻击后恢复自身最大体力的 1/3",
  timing = SeerTiming and SeerTiming.AfterAttack or "AfterAttack",
  -- 满血就没必要恢复（加 0 点血照样会打日志、发通知），所以先拦掉
  can_trigger = function(effect, ctx)
    local src = ctx.source
    local max_hp = src.max_hp or src:getStat("hp")
    return (src.hp or 0) > 0 and src.hp < max_hp
  end,
  on_use = function(effect, ctx)
    local src = ctx.source
    -- 当前体力上限由战斗逻辑写在 pet.max_hp 上（见 GameLogic:initialize）；
    -- 脱离战局单独用这个效果时退化读面板体力，免得直接 nil 报错。
    local max_hp = src.max_hp or src:getStat("hp")
    ctx.logic:recover(src, math.floor(max_hp / 3), effect.name)
  end,
}

return {
  name = "standard",

  skills = {
    -- ============================ 雷伊（电系）============================

    { name = "抓", id = 10006, element = "普通", category = Skill.Physical,
      power = 40, pp = 35, accuracy = 100 },

    -- 官方效果ID 42：1~1 回合自己使用电系招式伤害 ×2
    { name = "充电", id = 20006, category = Skill.Status, pp = 20, accuracy = 0,
      target = "self" },

    { name = "风驰电掣", id = 10166, element = "电", category = Skill.Physical,
      power = 50, pp = 35, accuracy = 100, priority = 2 },

    { name = "雷电击", id = 10171, element = "电", category = Skill.Special,
      power = 40, pp = 40, accuracy = 100 },

    -- 弱化：100% 对手防御 -1
    { name = "瞪眼", id = 20004, category = Skill.Status, pp = 30, accuracy = 100,
      target = "enemy" },

    { name = "闪光击", id = 10167, element = "电", category = Skill.Physical,
      power = 60, pp = 35, accuracy = 100, priority = 1 },

    -- 施加异常：命中后 5% 令对方麻痹
    { name = "电击光束", id = 10172, element = "电", category = Skill.Special,
      power = 60, pp = 35, accuracy = 100 },

    -- 施加异常：命中后 100% 麻痹，但命中率只有 50%
    { name = "雷祭", id = 20085, category = Skill.Status, pp = 30, accuracy = 50,
      target = "enemy" },

    { name = "放电", id = 10010, element = "电", category = Skill.Special,
      power = 80, pp = 15, accuracy = 100 },

    -- 增伤：自身 HP 小于 1/2 时威力 ×2
    { name = "惊雷切", id = 10168, element = "电", category = Skill.Physical,
      power = 55, pp = 25, accuracy = 100 },

    { name = "电闪雷鸣", id = 10173, element = "电", category = Skill.Special,
      power = 90, pp = 25, accuracy = 100 },

    -- 弱化：对手防御 -1（官方还带了别的，只抄了能确认的这一条）
    { name = "雷雨天", id = 20086, category = Skill.Status, pp = 20, accuracy = 100,
      target = "enemy" },

    { name = "霹雳斩", id = 10169, element = "电", category = Skill.Physical,
      power = 80, pp = 25, accuracy = 100 },

    -- 解弱：解除自身能力下降状态
    { name = "万丈光芒", id = 10174, element = "电", category = Skill.Special,
      power = 75, pp = 15, accuracy = 100 },

    -- 暴击率高（官方：37.5% = 6/16）
    { name = "白光刃", id = 10170, element = "电", category = Skill.Physical,
      power = 95, pp = 20, accuracy = 100, crit_rate = 2 },

    -- 弱化：对手速度 -1
    { name = "电闪光", id = 20087, category = Skill.Status, pp = 30, accuracy = 100,
      target = "enemy" },

    { name = "极电千鸟", id = 10175, element = "电", category = Skill.Special,
      power = 120, pp = 5, accuracy = 100 },

    { name = "瞬雷天闪", id = 10176, element = "电", category = Skill.Physical,
      power = 150, pp = 5, accuracy = 100 },

    -- 雷伊的第五技能：官方"元气电光球"（140 威力、必中、附带 5% 麻痹）
    --
    -- 注意这里**没有**任何"因为是第五技能所以要满足某个前提"的条件：
    -- 赛尔号的第五技能一样有 PP，机制上和普通技能没有区别，区别只在于它摆在
    -- 单独一个技能位上。真想禁止某个技能使用，用 `usable = false`，
    -- 或者把 PP 耗光——和它是不是第五技能无关。
    -- （旧注释里还提到 `pet:sealSkill(name)`：封招机制随重构删掉了，见 core/mark 的 TODO。）
    { name = "元气电光球", id = 10824, element = "电", category = Skill.Special,
      power = 140, pp = 10, accuracy = 0 },

    -- ============================ 盖亚（战斗系）============================

    { name = "叩击", id = 10127, element = "普通", category = Skill.Physical,
      power = 40, pp = 40, accuracy = 100 },

    -- 强化：自身攻击 +1
    { name = "气力", id = 20117, category = Skill.Status, pp = 40, accuracy = 0,
      target = "self" },

    -- 附加伤害：额外附加 50 点固定伤害
    { name = "渗透劲", id = 10716, element = "战斗", category = Skill.Special,
      power = 20, pp = 25, accuracy = 95 },

    -- 强化：自身防御 +1
    { name = "战意", id = 20307, category = Skill.Status, pp = 20, accuracy = 0,
      target = "self" },

    { name = "破元闪", id = 10710, element = "战斗", category = Skill.Physical,
      power = 60, pp = 25, accuracy = 100, priority = 1 },

    -- 强化：自身攻击 +1
    { name = "怒嚎", id = 20308, category = Skill.Status, pp = 15, accuracy = 0,
      target = "self" },

    { name = "气合斩", id = 10711, element = "战斗", category = Skill.Physical,
      power = 80, pp = 20, accuracy = 100 },

    -- 弱化：15% 对手防御 -1
    { name = "碎梦吟", id = 10717, element = "战斗", category = Skill.Special,
      power = 60, pp = 20, accuracy = 100 },

    { name = "擒九域", id = 10712, element = "战斗", category = Skill.Physical,
      power = 100, pp = 15, accuracy = 0 },

    -- 恢复：恢复自身最大体力的 1/3
    { name = "神经修复", id = 20309, category = Skill.Status, pp = 10, accuracy = 0,
      target = "self" },

    -- 附加伤害：官方是"降低对方 10 点战斗时的最高体力"，
    -- 我们暂时用附加 10 点固定伤害近似（TODO: 需要"最大体力变化"的机制）
    { name = "灭生啸", id = 10718, element = "战斗", category = Skill.Special,
      power = 80, pp = 15, accuracy = 100 },

    -- 连击：1 回合做 2~3 次攻击
    { name = "连环摔投", id = 10713, element = "战斗", category = Skill.Physical,
      power = 40, pp = 10, accuracy = 100,
      hits = function(skill, source, target, logic)
        return logic.rng:random(2, 3)
      end },

    -- 抵挡下 1 次对手的攻击（挂一个护盾印记）
    { name = "群影乱舞", id = 20310, category = Skill.Status, pp = 5, accuracy = 0,
      target = "self" },

    -- 强化：20% 自身速度 +1
    { name = "天罗地网", id = 10719, element = "战斗", category = Skill.Special,
      power = 110, pp = 10, accuracy = 100 },

    -- 强化：自身防御 +1
    { name = "不灭斗气", id = 20311, category = Skill.Status, pp = 15, accuracy = 0,
      target = "self" },

    -- 消强：消除对手能力提升状态
    { name = "日月皆伤", id = 10714, element = "战斗", category = Skill.Physical,
      power = 140, pp = 5, accuracy = 100 },

    -- 附加伤害：3 回合内每回合都能附加 30 点固定伤害（挂一个持续印记）
    { name = "末日宣告", id = 10720, element = "战斗", category = Skill.Special,
      power = 140, pp = 5, accuracy = 100 },

    -- 强化：自身攻击 +2
    { name = "返璞归真", id = 20312, category = Skill.Status, pp = 5, accuracy = 0,
      target = "self" },

    -- 消强（和日月皆伤是同一个效果，只有威力不同——这就是"复用"）
    { name = "石破天惊", id = 10715, element = "战斗", category = Skill.Physical,
      power = 150, pp = 5, accuracy = 100 },

    -- 盖亚的第五技能：官方"联盟的审判"（300 威力、必中、PP 1）
    -- 同样没有特殊条件：PP 只有 1，用完就用不了了——这就是它的限制。
    { name = "联盟的审判", id = 13582, element = "战斗", category = Skill.Physical,
      power = 300, pp = 1, accuracy = 0 },

    -- ============================ 效果链路演示（非官方数据）============================
    --
    -- 挂上面那个 `heal_demo`（攻击后恢复自身最大体力的 1/3）的技能，**不是官方数据**。
    -- 它做成**物理攻击技**而不是属性技是有原因的：GameLogic 现在的默认决策
    -- （`pickAction`）只挑"能造成伤害"的技能，属性技挂 AfterAttack 效果的话，
    -- 跑 `GameLogic:run()` 时根本轮不到它出手，链路也就验不出来。
    { name = "演示·雷鸣愈合", id = 90001, element = "电", category = Skill.Physical,
      power = 40, pp = 30, accuracy = 100,
      effects = { heal_demo } },

    -- ============================ 特性（魂印）：待重建 ============================
    --
    -- TODO: 这里原来放着两个演示用的"特性"占位技能（静电庇护 / 不灭战意），
    -- 已随重构删除，因为它们整个是基于已删除的 API 写的：
    --   * tags = { Skill.Ability, Skill.Compulsory }  —— 这两个标签常量从来没有定义过；
    --   * [SeerTiming.RoundEnd] / [SeerTiming.HpChanged] —— 旧时机名，
    --     现在的 18 个时机见 core/events（流程类叫 TurnEnd / AfterTurnEnd …）；
    --   * pet:getHpRatio() / pet:isFainted() / pet:getStatStage() —— Pet 上已删除；
    --   * timing.logic:recover{...} / logic:doStatChange{...} —— 现在在 GameLogic 上
    --     对应 `logic:recover(target, num, reason)` / 能力等级机制（尚未重建）。
    -- 官方"魂印"数据本身也还没抄（网页是 JS 渲染的，抓不到），
    -- 等特性 = "挂在时机上的技能"这套机制在 core/events + 触发体系里重建后再补。
  },
}

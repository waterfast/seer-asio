-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ standard 包：技能与印记 ============================
--
-- 雷伊、盖亚的**真实技能表**（来源：赛尔号 WIKI，wiki.biligame.com/seer/雷伊 与 /盖亚）。
-- 名字、图鉴ID、学习等级、先制、威力、PP、命中、物理/特殊/属性 都是抄的。
--
-- ---------------------------- 这份数据在演示什么 ----------------------------
--
-- 它同时是**"效果可复用"的活教材**——看看官方是怎么用同一批效果拼出 37 个技能的：
--
--   * 官方每个技能挂的是「**效果ID + 参数**」，和我们的 `{ kind = ..., 参数 }` 是同一回事：
--       33 = 消强（消除对手能力提升状态）
--        3 = 解弱（解除自身能力下降状态）
--        4 = 强化（改变自身能力等级）      5 = 弱化（改变对手能力等级）
--       10 = 施加异常（命中后 N% 令对方 XX）  29/38/60 = 附加伤害
--       31 = 连击                        37/42/88 = 增伤（条件 + 倍率）
--       43 = 恢复   46 = 抵挡
--   * **同一批效果，参数不同就是不同技能**：电击光束/放电/电闪雷鸣/霹雳斩/极电千鸟/瞬雷天闪
--     全都是"命中后 5% 令对方麻痹"，只有威力/PP/命中不同；雷祭则是"100% 麻痹但命中只有 50%"。
--   * "消除对手能力提升状态"（消强）在盖亚身上出现了两次（日月皆伤 / 石破天惊），
--     区别只有威力——所以它就该是一个 kind + 一个倍率参数，不是两段代码。
--
-- 我们这边对应的写法：
--   `{ kind = "clear_stages", side = "up" }`         —— 消强
--   `{ kind = "clear_stages", side = "down" }`       —— 解弱
--   `{ kind = "stat", target = "self", stages = {...} }`         —— 强化
--   `{ kind = "stat", stages = {...}, probability = 15 }`        —— 弱化（带概率）
--   `{ kind = "mark", mark = "paralysis", probability = 5 }`     —— 施加异常
--   `{ kind = "add_damage", value = 50 }`                        —— 附加固定伤害
--   `hits = 2`（技能字段）                                        —— 连击
--   `{ kind = "power_modifier", multiplier = 2, condition = ... }` —— 增伤
--   `{ kind = "heal", target = "self", ratio = 1/3 }`            —— 恢复
--   `{ kind = "mark", mark = "shield" }`                         —— 抵挡
--
-- ---------------------------- 还没能一比一还原的地方 ----------------------------
--
-- * 「灭生啸」官方是"降低对方 10 点战斗时的最高体力"，我们暂时用**附加 10 点固定伤害**
--   近似（要真做需要"最大体力变化"的机制）。
-- * 「末日宣告」官方是"3 回合内每回合都能附加 30 点固定伤害"——这就是**挂一个印记**，
--   本文件原来用 `dot30` 这个包内印记演示，见下面"重构后的状态"。
-- * 特性（魂印）没抄，见 species.lua 的 TODO。
--
-- ---------------------------- 重构后的状态（必读）----------------------------
--
-- 这份表**只保留了纯数据**（名字 / 图鉴id / 属性 / 类别 / 威力 / PP / 命中 /
-- 先制 / 暴击率 / hits），所以它现在能直接被 `Seer:createSkill` 吃进去。
-- 下面两类东西被清掉了，因为它们指向的东西已经被重构删除，留着就是死引用：
--
--   1. **旧的 `marks = {...}`（charge / dot30 两个包内印记）**：
--      `Mark.register` / `Seer:addMark` 现在都不存在（core/mark 依赖的
--      `OwnedTrigger` 还没重建），`[SeerTiming.DetermineDamage]` /
--      `[SeerTiming.RoundEnd]` 这些旧时机名也不存在（现在的时机是
--      core/events 里那 18 个类）。旧内容见 git 历史。
--   2. **两个"特性"占位技能（静电庇护 / 不灭战意）**：它们用
--      `tags = { Skill.Ability, Skill.Compulsory }`（这两个常量从来没定义过）
--      和 `pet:getHpRatio()/isFainted()/getStatStage()`（Pet 上已删除）。
--
-- ⚠ 每个技能上的 `effects = { { kind = "...", ... } }` **是数据、不是代码**：
--   它现在既不会被校验也不会被执行（`Skill` 只是原样存着），
--   但 `kind = ...` 那套写法属于**已被删除的效果类型系统**（原 core/effect/kinds.lua）。
--   等效果系统重建后，这里要按新的 `Effect` spec（`Seer:createEffect{ id = ..., ... }`）
--   重新对齐一遍——现在留着是因为它记录了每个技能到底该干什么，比丢掉强。
--   其中「惊雷切」的 `condition` 原本调 `ctx.source:getHpRatio()`（已删除），
--   已就地改成 TODO。

return {
  name = "standard",

  skills = {
    -- ============================ 雷伊（电系）============================

    { name = "抓", id = 10006, element = "普通", category = Skill.Physical,
      power = 40, pp = 35, accuracy = 100 },

    -- 官方效果ID 42：1~1 回合自己使用电系招式伤害 ×2
    { name = "充电", id = 20006, category = Skill.Status, pp = 20, accuracy = 0,
      target = "self",
      effects = {
        { kind = "mark", mark = "charge", target = "self" },   -- 见下方 marks 说明
      } },

    { name = "风驰电掣", id = 10166, element = "电", category = Skill.Physical,
      power = 50, pp = 35, accuracy = 100, priority = 2 },

    { name = "雷电击", id = 10171, element = "电", category = Skill.Special,
      power = 40, pp = 40, accuracy = 100 },

    -- 弱化：100% 对手防御 -1
    { name = "瞪眼", id = 20004, category = Skill.Status, pp = 30, accuracy = 100,
      target = "enemy",
      effects = { { kind = "stat", stages = { defense = -1 }, probability = 100 } } },

    { name = "闪光击", id = 10167, element = "电", category = Skill.Physical,
      power = 60, pp = 35, accuracy = 100, priority = 1 },

    -- 施加异常：命中后 5% 令对方麻痹
    { name = "电击光束", id = 10172, element = "电", category = Skill.Special,
      power = 60, pp = 35, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- 施加异常：命中后 100% 麻痹，但命中率只有 50%
    { name = "雷祭", id = 20085, category = Skill.Status, pp = 30, accuracy = 50,
      target = "enemy",
      effects = { { kind = "mark", mark = "paralysis", probability = 100 } } },

    { name = "放电", id = 10010, element = "电", category = Skill.Special,
      power = 80, pp = 15, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- 增伤：自身 HP 小于 1/2 时威力 ×2
    { name = "惊雷切", id = 10168, element = "电", category = Skill.Physical,
      power = 55, pp = 25, accuracy = 100,
      effects = {
        -- TODO(效果系统未重建)：条件原本写的是 `ctx.source:getHpRatio() < 0.5`，
        -- 而 `pet:getHpRatio()` 已随重构从 Pet 上删除（当前体力现在由战斗逻辑管，
        -- 见 server/gamelogic.lua 里的 pet.hp / pet.max_hp）。等效果系统重建、
        -- 定下"效果怎么拿到当前体力"之后再补回来。
        { kind = "power_modifier", multiplier = 2, phase = "before",
          condition = nil },
      } },

    { name = "电闪雷鸣", id = 10173, element = "电", category = Skill.Special,
      power = 90, pp = 25, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- 弱化：对手防御 -1（官方还带了别的，只抄了能确认的这一条）
    { name = "雷雨天", id = 20086, category = Skill.Status, pp = 20, accuracy = 100,
      target = "enemy",
      effects = { { kind = "stat", stages = { defense = -1 }, probability = 100 } } },

    { name = "霹雳斩", id = 10169, element = "电", category = Skill.Physical,
      power = 80, pp = 25, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- 解弱：解除自身能力下降状态
    { name = "万丈光芒", id = 10174, element = "电", category = Skill.Special,
      power = 75, pp = 15, accuracy = 100,
      effects = { { kind = "clear_stages", side = "down", target = "self" } } },

    -- 暴击率高（官方：37.5% = 6/16）
    { name = "白光刃", id = 10170, element = "电", category = Skill.Physical,
      power = 95, pp = 20, accuracy = 100, crit_rate = 2 },

    -- 弱化：对手速度 -1
    { name = "电闪光", id = 20087, category = Skill.Status, pp = 30, accuracy = 100,
      target = "enemy",
      effects = { { kind = "stat", stages = { speed = -1 }, probability = 100 } } },

    { name = "极电千鸟", id = 10175, element = "电", category = Skill.Special,
      power = 120, pp = 5, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    { name = "瞬雷天闪", id = 10176, element = "电", category = Skill.Physical,
      power = 150, pp = 5, accuracy = 100,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- 雷伊的第五技能：官方"元气电光球"（140 威力、必中、附带 5% 麻痹）
    --
    -- 注意这里**没有**任何"因为是第五技能所以要满足某个前提"的条件：
    -- 赛尔号的第五技能一样有 PP，机制上和普通技能没有区别，区别只在于它摆在
    -- 单独一个技能位上。真想禁止某个技能使用，用 `usable = false`，
    -- 或者把 PP 耗光——和它是不是第五技能无关。
    -- （旧注释里还提到 `pet:sealSkill(name)`：封招机制随重构删掉了，见 core/mark 的 TODO。）
    { name = "元气电光球", id = 10824, element = "电", category = Skill.Special,
      power = 140, pp = 10, accuracy = 0,
      effects = { { kind = "mark", mark = "paralysis", probability = 5 } } },

    -- ============================ 盖亚（战斗系）============================

    { name = "叩击", id = 10127, element = "普通", category = Skill.Physical,
      power = 40, pp = 40, accuracy = 100 },

    -- 强化：自身攻击 +1
    { name = "气力", id = 20117, category = Skill.Status, pp = 40, accuracy = 0,
      target = "self",
      effects = { { kind = "stat", target = "self", stages = { attack = 1 }, probability = 100 } } },

    -- 附加伤害：额外附加 50 点固定伤害
    { name = "渗透劲", id = 10716, element = "战斗", category = Skill.Special,
      power = 20, pp = 25, accuracy = 95,
      effects = { { kind = "add_damage", value = 50 } } },

    -- 强化：自身防御 +1
    { name = "战意", id = 20307, category = Skill.Status, pp = 20, accuracy = 0,
      target = "self",
      effects = { { kind = "stat", target = "self", stages = { defense = 1 }, probability = 100 } } },

    { name = "破元闪", id = 10710, element = "战斗", category = Skill.Physical,
      power = 60, pp = 25, accuracy = 100, priority = 1 },

    -- 强化：自身攻击 +1
    { name = "怒嚎", id = 20308, category = Skill.Status, pp = 15, accuracy = 0,
      target = "self",
      effects = { { kind = "stat", target = "self", stages = { attack = 1 }, probability = 100 } } },

    { name = "气合斩", id = 10711, element = "战斗", category = Skill.Physical,
      power = 80, pp = 20, accuracy = 100 },

    -- 弱化：15% 对手防御 -1
    { name = "碎梦吟", id = 10717, element = "战斗", category = Skill.Special,
      power = 60, pp = 20, accuracy = 100,
      effects = { { kind = "stat", stages = { defense = -1 }, probability = 15 } } },

    { name = "擒九域", id = 10712, element = "战斗", category = Skill.Physical,
      power = 100, pp = 15, accuracy = 0 },

    -- 恢复：恢复自身最大体力的 1/3
    { name = "神经修复", id = 20309, category = Skill.Status, pp = 10, accuracy = 0,
      target = "self",
      effects = { { kind = "heal", target = "self", ratio = 1 / 3 } } },

    -- 附加伤害：官方是"降低对方 10 点战斗时的最高体力"，
    -- 我们暂时用附加 10 点固定伤害近似（TODO: 需要"最大体力变化"的机制）
    { name = "灭生啸", id = 10718, element = "战斗", category = Skill.Special,
      power = 80, pp = 15, accuracy = 100,
      effects = { { kind = "add_damage", value = 10 } } },

    -- 连击：1 回合做 2~3 次攻击
    { name = "连环摔投", id = 10713, element = "战斗", category = Skill.Physical,
      power = 40, pp = 10, accuracy = 100,
      hits = function(skill, source, target, logic)
        return logic.rng:random(2, 3)
      end },

    -- 抵挡下 1 次对手的攻击（挂一个护盾印记）
    { name = "群影乱舞", id = 20310, category = Skill.Status, pp = 5, accuracy = 0,
      target = "self",
      effects = { { kind = "mark", mark = "shield", target = "self" } } },

    -- 强化：20% 自身速度 +1
    { name = "天罗地网", id = 10719, element = "战斗", category = Skill.Special,
      power = 110, pp = 10, accuracy = 100,
      effects = { { kind = "stat", target = "self", stages = { speed = 1 }, probability = 20 } } },

    -- 强化：自身防御 +1
    { name = "不灭斗气", id = 20311, category = Skill.Status, pp = 15, accuracy = 0,
      target = "self",
      effects = { { kind = "stat", target = "self", stages = { defense = 1 }, probability = 100 } } },

    -- 消强：消除对手能力提升状态
    { name = "日月皆伤", id = 10714, element = "战斗", category = Skill.Physical,
      power = 140, pp = 5, accuracy = 100,
      effects = { { kind = "clear_stages", side = "up" } } },

    -- 附加伤害：3 回合内每回合都能附加 30 点固定伤害（挂一个持续印记）
    { name = "末日宣告", id = 10720, element = "战斗", category = Skill.Special,
      power = 140, pp = 5, accuracy = 100,
      effects = { { kind = "mark", mark = "dot30" } } },

    -- 强化：自身攻击 +2
    { name = "返璞归真", id = 20312, category = Skill.Status, pp = 5, accuracy = 0,
      target = "self",
      effects = { { kind = "stat", target = "self", stages = { attack = 2 }, probability = 100 } } },

    -- 消强（和日月皆伤是同一个效果，只有威力不同——这就是"复用"）
    { name = "石破天惊", id = 10715, element = "战斗", category = Skill.Physical,
      power = 150, pp = 5, accuracy = 100,
      effects = { { kind = "clear_stages", side = "up" } } },

    -- 盖亚的第五技能：官方"联盟的审判"（300 威力、必中、PP 1）
    -- 同样没有特殊条件：PP 只有 1，用完就用不了了——这就是它的限制。
    { name = "联盟的审判", id = 13582, element = "战斗", category = Skill.Physical,
      power = 300, pp = 1, accuracy = 0 },

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

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
--   本文件里用 `dot30` 这个包内印记演示（见下面的 `marks`）。
-- * 特性（魂印）没抄，见 species.lua 的 TODO。

return {
  name = "standard",

  -- ============================ 包内自定义的印记 ============================
  -- 印记是**数据**：`Mark.register(key, def)` 一张表就是新印记。
  -- 包可以自己加，不用改核心——这是"异常状态和增益印记共用一个基类"的直接好处。
  marks = {
    -- 增益印记：接下来 1 回合自己的电系招式伤害翻倍（官方效果ID 42）
    -- 它演示了"增益印记也能改伤害"——和异常状态共用同一套机制，只是 mark_type 不同。
    {
      key = "charge",
      name = "充电",
      desc = "增益类印记：接下来 1 回合自己使用电系招式的伤害翻倍",
      mark_type = "buff",
      duration = 1,
      triggers = {
        [SeerTiming.DetermineDamage] = {
          priority = 0,
          on_trigger = function(trig, timing, target, pet, data)
            local mark = trig.mark
            if data.source ~= mark.pet then return false end
            if data.element ~= "电" then return false end
            data.damage = data.damage * 2
            return false
          end,
        },
      },
    },
    {
      key = "dot30",
      name = "持续创伤",
      desc = "弱化类印记：每大回合末额外受到 30 点固定伤害（末日宣告用）",
      mark_type = "weaken",
      duration = 3,
      triggers = {
        [SeerTiming.RoundEnd] = {
          priority = 0,
          on_trigger = function(trig, timing, target, pet, data)
            local mark = trig.mark
            if mark.pet == nil or mark.pet:isFainted() then return false end
            mark.logic:damage{
              target = mark.pet,
              fixed = 30,
              reason = mark.def.name,
              is_status_damage = true,
            }
            return false
          end,
        },
      },
    },
  },

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
        { kind = "power_modifier", multiplier = 2, phase = "before",
          condition = function(effect, ctx)
            return ctx.source:getHpRatio() < 0.5
          end },
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
    -- 单独一个技能位上。真想禁止某个技能使用，用 `usable = false`、或者
    -- `pet:sealSkill(name)`、或者把 PP 耗光——和它是不是第五技能无关。
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

    -- ============================ 特性（占位）============================
    -- TODO: 官方"魂印"效果还没抄（网页是 JS 渲染的，抓不到）。
    -- 这两个是演示用的占位特性，写法本身是真的：特性 = 挂在时机上的技能。

    { name = "静电庇护", category = Skill.Status,
      tags = { Skill.Ability, Skill.Compulsory }, target = "self",
      triggers = {
        [SeerTiming.RoundEnd] = {
          priority = 0,
          can_trigger = function(self, timing, target, pet, data)
            return pet:getHpRatio() < 1 / 3 and not pet:isFainted()
          end,
          on_trigger = function(self, timing, target, pet, data)
            timing.logic:recover{
              target = pet, num = math.max(1, math.floor(pet.max_hp / 8)), reason = "静电庇护",
            }
            return false
          end,
        },
      } },

    { name = "不灭战意", category = Skill.Status,
      tags = { Skill.Ability, Skill.Compulsory }, target = "self",
      triggers = {
        [SeerTiming.HpChanged] = {
          priority = 0,
          can_trigger = function(self, timing, target, pet, data)
            if data.who ~= pet or data.num >= 0 then return false end
            return pet:getHpRatio() < 0.5 and pet:getStatStage("attack") < 3
          end,
          on_trigger = function(self, timing, target, pet, data)
            timing.logic:doStatChange{ target = pet, stages = { attack = 1 }, reason = "不灭战意" }
            return false
          end,
        },
      } },
  },
}

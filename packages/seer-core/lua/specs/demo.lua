-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 示例扩展包 ============================
--
-- 这个文件同时是两样东西：
--   1. 自测/演示用的最小数据包（三只初始精灵 + 几个技能 + 一个特性）；
--   2. **怎么写 spec 的样板**——以后往里填真正的图鉴数据，照这个形状写就行。
--
-- 它展示了几种典型写法：
--   * 普通攻击技（属性 + 威力 + PP）
--   * 附带效果的攻击技（火花：10% 烧伤）
--   * 属性技（蓄能：自身特攻 +2；麻痹粉：令对手麻痹）
--   * 带使用条件的技能（背水一击：体力低于一半才可用；被封印的演示技：usable = false）
--   * 第五技能（单独一个技能位，机制上和普通技能没有区别）
--   * 特性（茂盛：挂在 HpChanged 时机上的一段钩子）
--
-- 效果类型写在哪、印记怎么定义，这份文件只给用法示例；
-- 制度本身和"新东西该加在哪"看：
--   lua/core/effect/kinds.lua     —— 内置效果类型的注册点
--   lua/core/mark/status.lua      —— 异常状态类（弱化类/控制类）
--   docs/effects-marks-status.md  —— 效果/印记/异常状态的分析文档
--
-- *** 下面所有数值都是占位数据 ***
--
-- 种族值、威力、命中率、概率……都是为了把机制跑通随手写的，**不是**赛尔号的实际
-- 数值。接入真图鉴时整份替换即可：这个文件只提供 spec，不含任何逻辑，
-- 换掉它不会影响核心的任何一行代码——这正是"把规则做成数据"的目的。

return {
  name = "demo",
  version = "0.1.0",

  -- ---------------------------- 种族（图鉴数据）----------------------------
  species = {
    {
      id = 1,
      name = "布布种子",
      elements = { "草" },
      base_stats = { hp = 45, attack = 49, defense = 65, sp_attack = 49, sp_defense = 65, speed = 45 },
      ability = "茂盛",
    },
    {
      id = 2,
      name = "小火猴",
      elements = { "火" },
      base_stats = { hp = 44, attack = 58, defense = 44, sp_attack = 58, sp_defense = 44, speed = 61 },
      ability = "茂盛",
    },
    {
      id = 3,
      name = "伊优",
      elements = { "水" },
      base_stats = { hp = 44, attack = 48, defense = 65, sp_attack = 50, sp_defense = 64, speed = 43 },
      ability = "茂盛",
    },
    {
      id = 4,
      name = "演示双属性",
      elements = { "水", "飞行" },
      base_stats = { hp = 60, attack = 50, defense = 50, sp_attack = 60, sp_defense = 55, speed = 70 },
      ability = "茂盛",
    },
  },

  -- ---------------------------- 技能 ----------------------------
  skills = {
    {
      name = "撞击",
      id = 1000,
      element = "普通",
      category = Skill.Physical,
      power = 35,
      pp = 35,
      accuracy = 100,
    },
    {
      name = "藤鞭",
      id = 1001,
      element = "草",
      category = Skill.Physical,
      power = 35,
      pp = 25,
      accuracy = 100,
    },
    {
      name = "火花",
      id = 1002,
      element = "火",
      category = Skill.Special,
      power = 40,
      pp = 25,
      accuracy = 100,
      -- 附带效果：10% 概率让目标烧伤
      effects = {
        { kind = "status", status = "burn", probability = 10 },
      },
    },
    {
      name = "水枪",
      id = 1003,
      element = "水",
      category = Skill.Special,
      power = 40,
      pp = 25,
      accuracy = 100,
    },
    {
      name = "先制突击",
      id = 1004,
      element = "普通",
      category = Skill.Physical,
      power = 40,
      pp = 20,
      accuracy = 100,
      priority = 1, -- 先手：出手顺序比速度优先
      tags = { Skill.Contact },
    },
    {
      name = "蓄能",
      id = 1005,
      category = Skill.Status,
      pp = 20,
      accuracy = 0, -- 0 / 不填 = 必中
      target = "self",
      -- 自身特攻 +2
      effects = {
        { kind = "stat", target = "self", stages = { sp_attack = 2 }, probability = 100 },
      },
    },
    {
      name = "麻痹粉",
      id = 1006,
      element = "草",
      category = Skill.Status,
      pp = 30,
      accuracy = 75, -- 属性技也会打空
      target = "enemy",
      effects = {
        { kind = "status", status = "paralysis", probability = 100 },
      },
    },
    {
      name = "剧毒之牙",
      id = 1007,
      element = "普通",
      category = Skill.Physical,
      power = 50,
      pp = 15,
      accuracy = 95,
      effects = {
        { kind = "status", status = "poison", probability = 30 },
        -- 同时给自己回一点血（吸血写法示例）
        { kind = "heal", target = "self", value = 10, probability = 100 },
      },
    },
    {
      name = "荆棘护体",
      id = 1008,
      category = Skill.Status,
      pp = 10,
      target = "self",
      -- 持续效果：接下来 3 回合受到的伤害减半。
      -- 这里演示 modifier 类型——它的钩子挂在 DetermineDamage 时机上改数值。
      effects = {
        {
          kind = "modifier",
          duration = 3,
          target = "self",
          extra = {
            timing = "DetermineDamage",
            apply = function(effect_self, data)
              -- 只挡"打在自己身上"的伤害
              if data.target ~= effect_self.target_pet then return false end
              local before = data.damage
              data.damage = math.max(1, math.floor(before * 0.5))
              return false
            end,
          },
        },
      },
    },

    -- ---------------------------- 第五技能 ----------------------------
    -- 用法（造精灵的时候单独给一个字段）：
    --   S.Pet:new{ species = "布布种子", level = 50,
    --              skills = { "撞击", "藤鞭", "蓄能", "麻痹粉" },
    --              fifth = "演示第五技·藤皇斩" }
    --
    -- 第五技能在机制上**就是一个普通技能**（同一个 Skill 类、一样有 PP、
    -- 一样走 Skill:checkUsable），区别只在于它挂在 `skill_set.fifth`
    -- 这个单独属性上、不占 4 个普通技能格——那是**摆位**上的区别，不是规则上的。
    -- 所以这里不给它写任何特殊条件。
    {
      name = "演示第五技·藤皇斩",
      id = 2001,
      element = "草",
      category = Skill.Physical,
      power = 90,
      pp = 5,
      accuracy = 100,
      desc = "演示用第五技能：和普通技能没有任何机制上的区别",
    },

    -- ---------------------------- 带使用条件的技能 ----------------------------
    -- `usable` 是技能自己的属性（不是第五技能专属的），两种写法：
    --   usable = false                 —— 这个技能现在被禁止使用（封招、剧情锁、规则禁用……）
    --   usable = function(skill, pet)  —— 要看场上情况才能决定
    -- 它和 PP 空、被封印（pet:sealSkill）是**同一个判断**的三个来源，
    -- 所以"列候选"和"真使用"永远一致，不会出现"能选但用不出来"。
    {
      name = "背水一击",
      id = 2002,
      element = "普通",
      category = Skill.Physical,
      power = 120,
      pp = 5,
      accuracy = 100,
      desc = "演示用技能：只有自身体力低于一半时才能使用",
      usable = function(skill, pet)
        return pet:getHpRatio() < 0.5
      end,
    },
    {
      name = "被封印的演示技",
      id = 2003,
      element = "普通",
      category = Skill.Physical,
      power = 999,
      pp = 10,
      accuracy = 100,
      desc = "演示用技能：写死 usable = false，永远用不出来",
      usable = false,
    },

    -- ---------------------------- 特性 ----------------------------
    -- 特性没什么特别的：它就是一个"没有威力、挂在时机上"的技能。
    -- 所以它和技能共用同一套 spec、同一套时机机制，不需要新概念。
    {
      name = "茂盛",
      category = Skill.Status,
      tags = { Skill.Ability, Skill.Compulsory },
      target = "self",
      triggers = {
        -- 时机名取自 SeerTiming（server/battle/events.lua 里登记的）。
        -- priority 越大越先被问到；can_trigger 决定要不要发动；on_trigger 是本体。
        [SeerTiming.HpChanged] = {
          -- 优先级 <= 0 = "必发效果"：排在询问类效果之后，而且**不会被拿去问玩家**。
          -- 特性是种族自带、永远生效的东西，所以用 0（written 成 1 就会每回合弹一次确认框）
          priority = 0,
          can_trigger = function(self, event, target, pet, data)
            -- 只关心"自己掉血"，而且只关心掉到三分之一以下
            if data.who == nil or data.who ~= pet then return false end
            if data.num >= 0 then return false end
            return pet:getHpRatio() < 1 / 3
          end,
          on_trigger = function(self, event, target, pet, data)
            -- 真正的实现应该在这里给一个"草系技能威力 +50%"的 modifier 效果：
            --   pet:addEffect 一个 kind = "modifier" 的效果，钩子挂 BeforeUseSkill。
            -- 演示包里只往本时机的私有数据里记一笔，够证明这条链路是通的。
            event:setSkillData(self, "bloom_triggered", true)
            Log.info(("特性[茂盛]在 %s 身上发动了"):format(pet.name))
            return false -- 返回 false = 不打断本时机
          end,
        },
      },
    },
  },
}

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ standard 包：自造效果与技能 ============================
--
-- 这份文件回答一个很实际的问题：**"新效果写在哪里？"**
--
-- 答案：**写在包里**。核心只提供"效果类型 = 插件"这套制度（`Effect.registerKind`）
-- 和一批通用效果（`lua/core/effect/kinds.lua`：伤害/回复/能力等级/印记/增伤……），
-- 具体玩法自己造的效果就注册在自己包的文件里，一行核心代码都不用改。
--
-- 所以本文件就是**样板 + 实验田**：
--   1. 注册 4 个核心没带的**新效果类型**（偷取能力等级、按体力比例造成伤害、
--      封招、抵挡致死伤害）；
--   2. 用它们造几个**自造测试技**给雷伊/盖亚用——名字前面加了「试作·」，
--      免得和上面 skills.lua 里抄来的官方技能混起来；
--   3. 顺便展示两种"寿命"的效果：
--        `instant = true`  当场算完（偷取、比例伤害）
--        `instant = false` **挂到精灵身上持续动**（封招、抵挡），进 `pet.effects` 表，
--                          回合数到点由 `on_expire` 收尾（解封、收掉抵挡）
--
-- 官方效果ID 的形状对照（为什么这些参数这么设计）：
--   33 = 消除对手能力提升状态   → 核心的 `clear_stages`
--   46 = 抵挡                    → 本文件的 `endure`（持续型效果的样板）
--   "令对手无法使用技能"         → 本文件的 `seal_skill`（配合 `Skill:checkUsable` 的封印）

return {
  name = "standard",

  -- ============================ 一、注册新效果类型 ============================
  --
  -- `Effect.registerKind(key, def)` 的 def 就三件事：
  --   validate(spec)  数据合不合法（加载期报错，别等打到一半崩）
  --   instant         当场算完，还是挂到精灵身上持续生效
  --   on_apply(effect, pet, ctx)   结算体
  --   on_expire(effect)            持续型被清除/到期时收尾
  --   triggers = { [SeerTiming.X] = {...} }   持续型的被动钩子
  effects = {

    -- ---------- 偷取能力等级（官方"偷取对手能力提升状态"的形状）----------
    --
    -- 和核心的 `clear_stages`（只消掉）只差一步：**把消掉的那些加给自己**。
    -- 这正是"效果可复用 + 只差一两个参数"的例子——但它多了"要有个受益者"，
    -- 已经不适合再用参数表达，所以单独一个 kind 更清楚。
    {
      key = "steal_stages",
      def = {
        name = "偷取能力等级",
        instant = true,
        validate = function(spec)
          local side = spec.side or "up"
          if side ~= "up" then
            return false, "steal_stages 目前只支持 side = \"up\"（偷取对方的提升）"
          end
          return true
        end,
        on_apply = function(effect, pet, ctx)
          local logic = effect.logic
          local thief = effect.source
          if logic == nil or thief == nil or thief == pet then return end

          local stolen = {}
          for _, field in ipairs(Pet.STAGE_FIELDS) do
            local stage = pet:getStatStage(field)
            if stage > 0 then
              pet:setStatStage(field, -stage)      -- 对手的这条提升归零
              thief:setStatStage(field, stage)     -- 原样加到自己身上（会自动封顶 +6）
              table.insert(stolen, { field = field, stages = stage })
            end
          end

          if #stolen > 0 then
            logic:notify{
              type = "StagesStolen",
              target = pet.seat,
              source = thief.seat,
              fields = table.map(stolen, function(s) return s.field end),
              reason = effect.name,
            }
            -- 记进 ctx，好让写法里的"偷取成功则……"接着判断
            ctx.extra = ctx.extra or {}
            ctx.extra.stolen_stages = stolen
          end
        end,
      },
    },

    -- ---------- 按体力比例造成固定伤害 ----------
    --
    -- 官方有不少"造成对方最大体力 X 分之几的伤害"的效果，形状就是这个：
    -- 按目标的一项体力值乘个比例，然后当**固定伤害**打出去
    -- （`is_status_damage = true`：不吃克制/暴击/本系加成）。
    {
      key = "hp_ratio_damage",
      def = {
        name = "按体力比例造成固定伤害",
        instant = true,
        validate = function(spec)
          if type(spec.ratio) ~= "number" or spec.ratio <= 0 or spec.ratio > 1 then
            return false, "hp_ratio_damage 需要 0 < ratio <= 1（比如 0.25 = 最大体力的 1/4）"
          end
          if spec.on == "current" then
            return false, "hp_ratio_damage 目前只支持按最大体力算（on = \"max\"）"
          end
          return true
        end,
        on_apply = function(effect, pet, ctx)
          local amount = math.max(1, math.floor(pet.max_hp * effect.ratio))
          effect.logic:damage{
            source = effect.source,
            target = pet,
            fixed = amount,
            reason = effect.name,
            is_status_damage = true,
          }
        end,
      },
    },

    -- ---------- 封招：N 回合内无法使用某个技能 ----------
    --
    -- 这是**持续型效果**的样板，也是"效果 ↔ 可用性"打通的样板：
    --   * 挂上去那一刻：调 `pet:sealSkill(name)`（上一轮做的"禁止使用技能"）
    --   * 到期/被清除：`on_expire` 里解封
    --   * 于是"列候选"和"真使用"自动都不给它用了——因为两边走的都是
    --     `Skill:checkUsable`，不需要在这里再写一遍判断。
    --
    -- 封哪个技能：写 `extra.skill = "技能名"`；不写就封**威力最大的那个**
    -- （打不出来技能时封第一个技能）。挑法必须是确定性的（同威力按技能名排），
    -- 否则同一局回放会封到不同的技能。
    {
      key = "seal_skill",
      def = {
        name = "封招",
        instant = false,
        validate = function(spec)
          if spec.duration == nil and spec.extra == nil then
            return false, "seal_skill 需要一个 duration（封几回合）"
          end
          local sk = spec.extra and spec.extra.skill
          if sk ~= nil and type(sk) ~= "string" then
            return false, "seal_skill 的 extra.skill 要写技能名（字符串）"
          end
          return true
        end,
        on_apply = function(effect, pet, ctx)
          local name = effect.extra.skill
          if name == nil then
            -- 没指定就挑"打人最疼"的那个技能
            local best = nil
            for _, sk in ipairs(pet:getAllSkills()) do
              if best == nil
                or (sk:getPower() > best:getPower())
                or (sk:getPower() == best:getPower() and sk.name < best.name) then
                best = sk
              end
            end
            name = best and best.name or nil
          end
          if name == nil then return end
          pet:sealSkill(name)
          effect.sealed_skill = name
          effect.logic:notify{
            type = "SkillSealed",
            pet = pet.seat,
            skill = name,
            reason = effect.name,
          }
        end,
        on_expire = function(effect)
          local pet = effect.target_pet
          if pet ~= nil and effect.sealed_skill ~= nil then
            pet:unsealSkill(effect.sealed_skill)
            effect.logic:notify{
              type = "SkillUnsealed",
              pet = pet.seat,
              skill = effect.sealed_skill,
              reason = effect.name,
            }
          end
        end,
      },
    },

    -- ---------- 抵挡致死伤害（官方效果ID 46 的形状）----------
    --
    -- 又一个持续型样板：这一次是**被动钩子**版本——
    -- 挂上去之后自己挂在 `DetermineDamage` 上，谁要打死我我就把伤害压到剩 1 点，
    -- 然后"用完即走"（`effect:remove`）。
    -- 它和印记的护盾是同一个套路，区别只是它不进状态栏（是机制，不是状态）。
    {
      key = "endure",
      def = {
        name = "抵挡致死伤害",
        instant = false,
        validate = function(spec)
          if spec.duration == nil then
            return false, "endure 需要一个 duration（几回合内有效）"
          end
          return true
        end,
        triggers = {
          [SeerTiming.DetermineDamage] = {
            priority = 5,   -- 高于普通减伤：这是"保命"，要先算
            on_trigger = function(trig, timing, target, pet, data)
              local effect = trig.effect
              local holder = effect.target_pet
              if holder == nil or data.target ~= holder then return false end
              if data.prevented then return false end
              -- 只会被"这一下能打死我"触发；否则留着
              if data.damage < holder.hp then return false end
              data:setDamage(math.max(1, holder.hp - 1))
              effect.logic:notify{
                type = "Endured",
                pet = holder.seat,
                hp = holder.hp,
                reason = effect.name,
              }
              effect:remove("consumed")
              return false
            end,
          },
        },
      },
    },
  },

  -- ============================ 二、用这些效果造技能 ============================
  --
  -- 这些是**自造测试技**（不是官方技能，名字统一带「试作·」前缀），
  -- 目的就是把上面 4 个效果各跑一遍；数值随口定的，别当平衡数据看。
  skills = {
    -- 偷取：官方"偷取对手能力提升状态"的用法
    { name = "试作·雷霆回响", id = 90001, element = "电", category = Skill.Special,
      power = 80, pp = 10, accuracy = 100,
      desc = "自造测试技：消除对手能力提升状态，并把这些提升加到自己身上",
      effects = { { kind = "steal_stages", side = "up" } } },

    -- 封招：持续型效果 + 可用性联动
    { name = "试作·封印之雷", id = 90002, element = "电", category = Skill.Status,
      pp = 5, accuracy = 95, target = "enemy",
      desc = "自造测试技：2 回合内令对手无法使用它威力最高的技能",
      effects = { { kind = "seal_skill", duration = 2, probability = 100 } } },

    -- 指定封哪个技能：写 extra.skill
    { name = "试作·锁喉", id = 90003, element = "战斗", category = Skill.Status,
      pp = 5, accuracy = 100, target = "enemy",
      desc = "自造测试技：3 回合内令对手无法使用「气力」",
      effects = { { kind = "seal_skill", duration = 3, extra = { skill = "气力" } } } },

    -- 比例固定伤害
    { name = "试作·逆流碎击", id = 90004, element = "战斗", category = Skill.Physical,
      power = 60, pp = 10, accuracy = 100,
      desc = "自造测试技：附加对手最大体力 1/6 的固定伤害",
      effects = { { kind = "hp_ratio_damage", ratio = 1 / 6 } } },

    -- 抵挡：挂在**自己**身上的持续效果
    { name = "试作·不屈意志", id = 90005, category = Skill.Status,
      pp = 3, accuracy = 0, target = "self",
      desc = "自造测试技：3 回合内，受到会打倒自己的伤害时保留 1 点体力（只挡一次）",
      effects = { { kind = "endure", duration = 3, target = "self" } } },
  },
}

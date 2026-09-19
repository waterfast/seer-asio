-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 王·雷伊 / 王·盖亚 技能定义 ============================
--
-- 字段全部照 biligame 技能页原文填；desc 是效果原文逐字照抄（含分号与百分号），
-- 不做改写。extra 里记"哪些部分已实现、哪些没实现"，供文档与测试对照。
--
-- 数据来源：
--   王·雷伊：技能:19731 / 技能:19732 / 技能:19733 / 技能:30122
--   王·盖亚：技能:30155 / 技能:30156 / 技能:30157 / 技能:30185
--   （https://wiki.biligame.com/seer/index.php?title=技能:<ID>&action=raw）
--
-- 命中率歧义（wiki 写"必中（95%）"）：按 Lead 判定，30122 / 30185 / 30156 取
-- accuracy = 0（必中；SeerAPI 记 must_hit = true，与"必中"一致），19733 / 30157 取 95。
-- 数据已与 docs/skill-research.md（agent-research 抓取 + SeerAPI 双向核对）交叉核对一致。
--
-- 效果实现情况（详见 docs/unimplemented-effects.md）：
--   19732 惊颤霹雳：+500 固定伤害——已实现
--   19731 金翼剑轮：免疫下 1 次受到的攻击——用 pet 局内计数模拟实现
--   30155 天威力破：伤害不足 280 则下 2 回合必致命——已实现；消回合/免疫异常未实现
--   30157 威斗天罡破：按对手负等级总和增伤——已实现；对手负等级时先制 +1 未实现
--   30185 王·联盟审判[追加]：伤害不足 300 则下次伤害 +100%——已实现；对大暗黑天长老 +50% 未实现
--   19733 寰宇雷神断：概率麻痹——未实现（核心无异常状态系统）
--   30156 极度冲刺：反转自身能力下降——未实现（BattleRoom 没有 reverse 入口）
--   30122 王·联盟审判[追加]：对大暗黑天长老 +50% 与麻痹 2 回合——未实现

---@param effects table<string, Effect>
---@return table<integer, Skill> @ 技能编号 -> 技能
local function createSkills(effects)
  local definitions = {
    -- ---------------------------- 王·雷伊 ----------------------------
    {
      id = 19733, name = "寰宇雷神断",
      category = Skill.Physical, element = "电", power = 150, pp = 5, priority = 0, accuracy = 95,
      effects = {}, -- 概率麻痹需要异常状态系统，留空
      desc = "50%使对手麻痹，自身每处于一种能力提升状态则概率提高8%",
      extra = { unimplemented = { "概率麻痹（含按能力提升状态提高概率）" } },
    },
    {
      id = 19732, name = "惊颤霹雳",
      category = Skill.Special, element = "电", power = 140, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.shock_flat },
      desc = "100%概率额外附加500点固定伤害",
      extra = { implemented = { "附加 500 固定伤害（公式后追加，不吃克制与暴击倍率）" } },
    },
    {
      id = 19731, name = "金翼剑轮",
      category = Skill.Physical, element = "电", power = 130, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.guard_grant },
      desc = "免疫下1次受到的攻击",
      extra = { implemented = { "免疫下一次受到的攻击（pet 局内计数模拟，一次攻击整体取消）" } },
    },
    {
      id = 30122, name = "王·联盟审判",
      category = Skill.Physical, element = "普通", power = 350, pp = 1, priority = 0, accuracy = 0,
      effects = {},
      desc = "对大暗黑天长老造成的伤害提高50%；35%概率使对手陷入麻痹状态2回合",
      extra = { unimplemented = { "对大暗黑天长老伤害+50%（无目标分类钩子）", "35%概率麻痹2回合（无异常状态系统）" },
        note = "追加技能，占第4格" },
    },

    -- ---------------------------- 王·盖亚 ----------------------------
    {
      id = 30157, name = "威斗天罡破",
      category = Skill.Physical, element = "战斗", power = 150, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.weidou_boost },
      desc = "对手处于能力下降状态时自身先制+1；造成的伤害提升，伤害提升的倍数等于对手能力下降等级总和乘以10%",
      extra = { implemented = { "按对手负等级总和 ×10% 增伤" },
        unimplemented = { "对手处于能力下降时自身先制+1（出手顺序在效果时机之前已排定）" } },
    },
    {
      id = 30156, name = "极度冲刺",
      category = Skill.Special, element = "战斗", power = 140, pp = 5, priority = 0, accuracy = 0,
      effects = {},
      desc = "反转自身能力下降状态",
      extra = { unimplemented = { "反转自身能力下降状态（BattleRoom 没有 reverse 入口）" } },
    },
    {
      id = 30155, name = "天威力破",
      category = Skill.Physical, element = "战斗", power = 85, pp = 20, priority = 3, accuracy = 100,
      effects = { effects.tianwei_mark },
      desc = "消除对手回合类效果，消除成功则己方免疫下1次受到的异常状态；若造成的伤害不足280，则下2回合的攻击必定致命一击",
      extra = { implemented = { "伤害不足280则下2回合的攻击必定致命一击" },
        unimplemented = { "消除对手回合类效果（无回合类效果注册表）", "消除成功则免疫下1次异常状态（无异常状态系统）" } },
    },
    {
      id = 30185, name = "王·联盟审判",
      category = Skill.Physical, element = "普通", power = 350, pp = 1, priority = 0, accuracy = 0,
      effects = { effects.lianmeng_mark },
      desc = "对大暗黑天长老造成的伤害提高50%；造成的伤害不足300则下1次攻击造成的伤害提高100%",
      extra = { implemented = { "伤害不足300则下1次攻击伤害+100%（一次性标记）" },
        unimplemented = { "对大暗黑天长老伤害+50%（无目标分类钩子）" },
        note = "追加技能，占第4格" },
    },
  }

  local skills = {}
  for _, spec in ipairs(definitions) do
    skills[spec.id] = Seer:createSkill(spec)
  end
  return skills
end

return createSkills

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 王·雷伊 / 王·盖亚 技能定义 ============================
--
-- 字段全部照 biligame 技能页原文填；desc 是效果原文逐字照抄（含分号与百分号），
-- 不做改写。extra 里记"哪些部分已实现、哪些没实现"，供文档与测试对照。
--
-- 数据来源：
--   王·雷伊：技能:19733 / 技能:24971 / 技能:19732 / 技能:24970 / 技能:19734（第五）
--   王·盖亚：技能:30157 / 技能:25184 / 技能:30156 / 技能:25183 / 技能:30158（第五）
--   参考技能：技能:19731 / 技能:30122 / 技能:30155 / 技能:30185
--   （https://wiki.biligame.com/seer/index.php?title=技能:<ID>&action=raw）
--
-- ---------------------------- 四个主要技能怎么选（本版口径）------------------------
--
-- 按用户原话「最后学会的四个技能」的**字面**读法：取学习等级最高的四个**非第五技能**。
-- 依据原始技能串（Lead 从 biligame action=raw 逐条核实）：
--
--   王·雷伊：…19731-90-1;24970-91-1;19732-92;24971-93-1;19733-94-1;30122-0-追加;19734-95-第五
--     → 19733(94) / 24971(93) / 19732(92) / 24970(91)
--   王·盖亚：…30155-71-1;25183-72-1;30156-73;25184-74-1;30157-75-1;30185-0-追加;30158-76-第五
--     → 30157(75) / 25184(74) / 30156(73) / 25183(72)
--
-- 第五技能（19734 / 30158）不占普通四格，用 Pet 的 `fifth` 字段单独挂载（见 init.lua）。
-- 上一版按「3 个本系主技能 + 追加技能」取得的那四个（19731 金翼剑轮、30122 王·联盟审判
-- [追加]、30155 天威力破、30185 王·联盟审判[追加]）**降级为参考技能**：不再占四格，
-- 但定义与效果实现全部保留，供 test_min 的确定性检查继续使用。
--
-- ---------------------------- 命中率口径 ----------------------------
--
-- wiki 里 19733 / 24971 / 24970 / 25183 / 25184 等写「必中（95%）/（100%）」，
-- SeerAPI 对应 `must_hit = true`。本包取 accuracy = 0（必中，语义等价，原始数值被忽略）。
-- 19732 / 30157 的 SeerAPI 记 `must_hit = false, accuracy = 95`，取 95。
--
-- 效果实现情况（详见 docs/unimplemented-effects.md）：
--   24971 传承王意：全属性+1 + 体力低于对手翻倍——已实现；回满血 / 免疫反弹异常——未实现
--   19734 王·万霆朝宗[第五]：伤害不出现微弱、未击败对手则全属性+1——已实现；其余未实现
--   19732 惊颤霹雳：+500 固定伤害——已实现（沿用旧实现 wang_shock_flat_500）
--   24970 万鸣齐闪：反转换作——已实现（组合近似）；260 点电系伤害——未实现
--   30157 威斗天罡破：按对手负等级总和增伤——已实现；先制+1 未实现
--   25184 不败之境：全属性+1 + 体力超过 1/2 翻倍——已实现；回合吸血、先制+2 未实现
--   30156 极度冲刺：反转换作——已实现（组合近似）
--   25183 战霸天下：三段都不可干净实现——未实现
--   30158 王·圣勇战意[第五]：伤害不出现微弱、吸取能力提升——已实现；吸 300 体力、先制+2 未实现
--   19733 寰宇雷神断：概率麻痹——未实现（核心无异常状态系统）
--   参考技能：19731 免疫一次攻击（模拟实现）、30155 伤害不足 280 必致命（已实现）、
--             30185 伤害不足 300 下次翻倍（已实现）、30122 无实现

---@param effects table<string, Effect>
---@return table<integer, Skill> @ 技能编号 -> 技能
local function createSkills(effects)
  local definitions = {
    -- ============================ 王·雷伊 ============================
    -- 四技能①（学习等级 94，最高）
    {
      id = 19733, name = "寰宇雷神断",
      category = Skill.Physical, element = "电", power = 150, pp = 5, priority = 0, accuracy = 95,
      effects = {}, -- 概率麻痹需要异常状态系统，留空
      desc = "50%使对手麻痹，自身每处于一种能力提升状态则概率提高8%",
      extra = { unimplemented = { "概率麻痹（含按能力提升状态提高概率）" },
        note = "四技能①（学习等级 94）" },
    },
    -- 四技能②（学习等级 93）
    {
      id = 24971, name = "传承王意",
      category = Skill.Status, element = "普通", power = 0, pp = 5, priority = 0, accuracy = 0,
      target = "self",
      effects = { effects.chuancheng_boost },
      desc = "全属性+1，若自身当前体力低于对手则强化效果翻倍；2回合内每回合使用技能恢复自身最大体力的1/1；5回合内免疫并反弹所有受到的异常状态",
      extra = {
        implemented = { "全属性+1（六项：攻/防/特攻/特防/速度/命中）",
          "自身当前体力低于对手时强化效果翻倍（按当前体力绝对值比较）" },
        unimplemented = { "2回合内每回合使用技能恢复自身最大体力的1/1（1/1 = 回满，每回合回满会让演示局变成不死，按用户判定不做）",
          "5回合内免疫并反弹所有受到的异常状态（无异常状态系统）" },
        note = "四技能②（学习等级 93）" },
    },
    -- 四技能③（学习等级 92）
    {
      id = 19732, name = "惊颤霹雳",
      category = Skill.Special, element = "电", power = 140, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.shock_flat },
      desc = "100%概率额外附加500点固定伤害",
      extra = { implemented = { "附加 500 固定伤害（公式后追加，不吃克制与暴击倍率）" },
        note = "四技能③（学习等级 92）" },
    },
    -- 四技能④（学习等级 91）
    {
      id = 24970, name = "万鸣齐闪",
      category = Skill.Status, element = "普通", power = 0, pp = 5, priority = 3, accuracy = 0,
      target = "self",
      effects = { effects.wanming_reverse },
      desc = "反转自身能力下降状态；直接造成260点电系伤害，自身每处于一种能力提升状态则造成的伤害提高10%",
      extra = {
        implemented = { "反转自身能力下降状态（用 changeStatStages 组合近似，见 effects.lua 注释）" },
        unimplemented = { "直接造成260点电系伤害（需要规则层固定伤害入口，logic:changeHp 是底层写血）",
          "每处于一种能力提升状态则伤害提高10%（数学已实现为 wang_wanming_stage_boost，但缺上述载体，未挂载）" },
        note = "四技能④（学习等级 91，先制 3）" },
    },
    -- 第五技能（学习等级 95）
    {
      id = 19734, name = "王·万霆朝宗",
      category = Skill.Physical, element = "电", power = 160, pp = 5, priority = 0, accuracy = 0,
      effects = { effects.fifth_no_weak, effects.wanting_survive },
      desc = "攻击时造成的伤害不会出现微弱（克制关系为微弱时都变成普通）；消除对手回合类效果，消除成功则下回合自身造成的攻击伤害额外提升100%；未击败对手则自身全属性+1；未击败对手则下回合自身所有技能先制+2",
      extra = {
        implemented = { "攻击时造成的伤害不会出现微弱（克制倍率 (0,1) 抬回 1）",
          "未击败对手则自身全属性+1（AfterAttack 判目标是否存活）" },
        unimplemented = { "消除对手回合类效果（无回合类效果注册表）",
          "消除成功则下回合攻击伤害+100%（依赖上一条的'成功'判定，且需要回合类效果系统）",
          "未击败对手则下回合自身所有技能先制+2（技能先制度是静态字段，排序在效果时机之前）" },
        note = "第五技能（不占普通四格，挂 Pet.fifth）" },
    },

    -- ============================ 王·盖亚 ============================
    -- 四技能①（学习等级 75，最高）
    {
      id = 30157, name = "威斗天罡破",
      category = Skill.Physical, element = "战斗", power = 150, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.weidou_boost },
      desc = "对手处于能力下降状态时自身先制+1；造成的伤害提升，伤害提升的倍数等于对手能力下降等级总和乘以10%",
      extra = { implemented = { "按对手负等级总和 ×10% 增伤" },
        unimplemented = { "对手处于能力下降时自身先制+1（出手顺序在效果时机之前已排定）" },
        note = "四技能①（学习等级 75）" },
    },
    -- 四技能②（学习等级 74）
    {
      id = 25184, name = "不败之境",
      category = Skill.Status, element = "普通", power = 0, pp = 5, priority = 0, accuracy = 0,
      target = "self",
      effects = { effects.bubai_boost },
      desc = "全属性+1，自身当前体力高于最大体力的1/2时强化效果翻倍；4回合内每回合使用技能吸取对手最大体力的1/3；下2回合令自身所有技能先制+2",
      extra = {
        implemented = { "全属性+1（六项：攻/防/特攻/特防/速度/命中）",
          "自身当前体力高于最大体力的1/2时强化效果翻倍（严格大于）" },
        unimplemented = { "4回合内每回合使用技能吸取对手最大体力的1/3（无回合类效果系统 + 规则层吸血入口）",
          "下2回合令自身所有技能先制+2（技能先制度是静态字段，排序在效果时机之前）" },
        note = "四技能②（学习等级 74）" },
    },
    -- 四技能③（学习等级 73）
    {
      id = 30156, name = "极度冲刺",
      category = Skill.Special, element = "战斗", power = 140, pp = 5, priority = 0, accuracy = 0,
      effects = { effects.jidu_reverse },
      desc = "反转自身能力下降状态",
      extra = { implemented = { "反转自身能力下降状态（用 changeStatStages 组合近似，见 effects.lua 注释）" },
        note = "四技能③（学习等级 73）" },
    },
    -- 四技能④（学习等级 72）
    {
      id = 25183, name = "战霸天下",
      category = Skill.Status, element = "普通", power = 0, pp = 5, priority = 0, accuracy = 0,
      target = "self",
      effects = {},
      desc = "4回合内免疫并反弹所有受到的异常状态；5回合内免疫能力下降状态；将下次受到的伤害200%反馈给对手",
      extra = {
        unimplemented = { "4回合内免疫并反弹所有受到的异常状态（无异常状态系统，也没有反弹入口）",
          "5回合内免疫能力下降状态（无回合类效果系统，也没有'免疫能力下降'查询钩子）",
          "将下次受到的伤害200%反馈给对手（无伤害反弹/反伤入口）" },
        note = "四技能④（学习等级 72）" },
    },
    -- 第五技能（学习等级 76）
    {
      id = 30158, name = "王·圣勇战意",
      category = Skill.Physical, element = "战斗", power = 160, pp = 5, priority = 0, accuracy = 0,
      effects = { effects.fifth_no_weak, effects.shengyong_steal },
      desc = "攻击时造成的伤害不会出现微弱（克制关系为微弱时都变成普通）；吸取对手能力提升状态，吸取成功则吸取对手300点体力；若对手处于能力提升状态则先制+2",
      extra = {
        implemented = { "攻击时造成的伤害不会出现微弱（克制倍率 (0,1) 抬回 1）",
          "吸取对手能力提升状态（清对手正等级 + 同额加给自身，用现有能力等级 API 组合）" },
        unimplemented = { "吸取成功则吸取对手300点体力（需要规则层固定伤害/吸血入口，logic:changeHp 是底层写血）",
          "若对手处于能力提升状态则先制+2（出手排序在效果时机之前）" },
        note = "第五技能（不占普通四格，挂 Pet.fifth）" },
    },

    -- ============================ 参考技能（不占四格，未挂到精灵上）============================
    -- 上一版作为四技能落地、本版按用户原话降级的技能：定义与效果实现全部保留，
    -- test_min 的确定性检查（免疫、+500、增伤、279/280、翻倍）继续用它们。
    {
      id = 19731, name = "金翼剑轮",
      category = Skill.Physical, element = "电", power = 130, pp = 5, priority = 0, accuracy = 95,
      effects = { effects.guard_grant },
      desc = "免疫下1次受到的攻击",
      extra = { implemented = { "免疫下一次受到的攻击（pet 局内计数模拟，一次攻击整体取消）" },
        note = "参考技能（不占四格；王·雷伊学习等级 90）" },
    },
    {
      id = 30122, name = "王·联盟审判",
      category = Skill.Physical, element = "普通", power = 350, pp = 1, priority = 0, accuracy = 0,
      effects = {},
      desc = "对大暗黑天长老造成的伤害提高50%；35%概率使对手陷入麻痹状态2回合",
      extra = { unimplemented = { "对大暗黑天长老伤害+50%（无目标分类钩子）", "35%概率麻痹2回合（无异常状态系统）" },
        note = "参考技能（王·雷伊追加技能，不占四格）" },
    },
    {
      id = 30155, name = "天威力破",
      category = Skill.Physical, element = "战斗", power = 85, pp = 20, priority = 3, accuracy = 100,
      effects = { effects.tianwei_mark },
      desc = "消除对手回合类效果，消除成功则己方免疫下1次受到的异常状态；若造成的伤害不足280，则下2回合的攻击必定致命一击",
      extra = { implemented = { "伤害不足280则下2回合的攻击必定致命一击" },
        unimplemented = { "消除对手回合类效果（无回合类效果注册表）", "消除成功则免疫下1次异常状态（无异常状态系统）" },
        note = "参考技能（不占四格；王·盖亚学习等级 71）" },
    },
    {
      id = 30185, name = "王·联盟审判",
      category = Skill.Physical, element = "普通", power = 350, pp = 1, priority = 0, accuracy = 0,
      effects = { effects.lianmeng_mark },
      desc = "对大暗黑天长老造成的伤害提高50%；造成的伤害不足300则下1次攻击造成的伤害提高100%",
      extra = { implemented = { "伤害不足300则下1次攻击伤害+100%（一次性标记）" },
        unimplemented = { "对大暗黑天长老伤害+50%（无目标分类钩子）" },
        note = "参考技能（王·盖亚追加技能，不占四格）" },
    },
  }

  local skills = {}
  for _, spec in ipairs(definitions) do
    skills[spec.id] = Seer:createSkill(spec)
  end
  return skills
end

return createSkills

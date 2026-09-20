# 战斗规则与 HP / Buff 接口

本次整理依据：效果框架讨论附件、`docs/skill-research.md` 与 `docs/latest-pets.md`。前两版已经完成对象挂载、单次 Handler、能力等级和 UseSkill；本次统一 HP 与伤害执行，并增加局内 Buff 绑定。技能文案是需求参考，不表示所有技能效果已经实现。

## 模块职责

- `GameObject.effects` 保存共享 Effect 定义；定义不得保存次数、层数、持续回合等可变局内状态。
- `GameObject.buff_instances` 保存本对象的 Buff。实例保存 `owner/source/room/state/start_round/expires_after_round`，效果定义可共享。
- `BattleRoom` 提供伤害、回血、直接改血、等级变化、Buff 添加/消耗/驱散入口。
- `GameLogic:trigger` 根据当前时机收集技能、房间、已注册对象及各自 Buff 的效果。logic 不维护所有效果的索引。
- `EffectHandler` 只排序与执行；效果通过 `ctx.owner` 获取拥有者，通过 `ctx.buff.state` 获取实例状态。
- `server/events/hp.lua` 是唯一局内 HP 写入实现。`GameLogic` 和 `GameEvent.Damage/Recover/ChangeHp` 都委托它，不保留另一套公式。

`Unit:addBuff/getBuffs` 是历史上的 Effect 挂载别名；新的运行期 Buff 使用 **`room:addBuff/getBuffs`**，没有偷偷改变旧调用的返回类型。旧 `core/mark/*` 尚未接入本流程。

## 时序与数据契约

```text
UseSkill
  BeforeSkillUse → 消耗一次 PP → 命中判定
  命中：SkillUsed → 属性技效果 / resolveAttack
  未命中：SkillMissed 通知 → 攻击技的 AttackEnd
  AfterSkillUse

resolveAttack
  BeforeAttack → AttackStart
  每击调用 damage：
    DamageParamCalculate → CriticalChanceCalculate → 致命判定
    BeforeDamageCalculate → 公式 → DamageCalculate
    AfterDamageCalculate → FinalDamageCalculate → AttackReady
    BeforeDamage
      BeforeHpChange → HP 提交 → AfterHpChange → [HpReducedToZero]
    [致命清除对应防御强化] → AfterDamage → DamageResolved
  Attack（本击确实扣血时）
  AfterAttack → AttackEnd

fixed / percent damage
  BeforeDamage → HP 变化链 → AfterDamage → DamageResolved

recover
  BeforeRecover → HP 变化链 → AfterRecover

direct changeHp
  BeforeHpChange → HP 提交 → AfterHpChange → [HpReducedToZero]
```

- 攻击类别按 Physical / Special 判断；零威力攻击仍进入伤害修正链，以支持文档中的“攻击伤害不低于 300”。Status 技能不自动造成 1 点伤害，可通过效果调用固定伤害。
- `SkillUsed` 当前定义为命中后执行；`AfterSkillUse` 可以通过 `data.missed` 区分失败。“使用即生效”和“命中才生效”不能混用；未命中仍可在 AfterSkillUse 编写收尾。
- `BeforeAttack` 取消整次攻击；公式时机、`BeforeDamage` 取消该击。`BeforeRecover` 可禁疗；`BeforeHpChange` 可拦截任何改血（例如锁血）。设置 `data.prevented=true` 或打断前置时机均会防止相应操作。
- `DamageData.damage` 是请求伤害，`actual` 是实际扣血；`RecoverData.num` 是请求回复，`actual` 是实际回复。`HpChangeData.actual` 带符号，等于本次提交的 `after-before`。
- 前置效果允许嵌套改血，提交前重新读取当前 HP；后置嵌套回血、反伤不计入原事件的 `actual`。后置数据是结果，不支持通过修改字段撤销已经提交的 HP。
- `AfterHpChange` 只在实际变化时触发；`AfterDamage/AfterRecover` 只在实际数值大于 0 时触发。有效目标上的伤害尝试即使被免疫，仍发 `DamageResolved`；已经倒下的目标在入口直接拒绝。
- HP 范围为 `[0,max_hp]`。归零即置 `fainted`，发 `HpReducedToZero` 与 `PetFainted` 通知；普通回血和直接改血均不复活。零值请求、满血回复不伪造 HP 变化。
- 来源、目标、类别在前置时机不是重定向接口；效果应修改数值或防止标记。伤害不能靠改正负号变成回血，回复也不能变成扣血。

## 规则作者如何调用

```lua
-- 技能之外的伤害也有来源、有防止时机、有实际结果。
local dealt = room:damage{
  source = attacker, target = defender, skill = skill,
  kind = "fixed", damage = 500, reason = "附加伤害", parent = triggering_data,
}

-- 百分比选哪个基数、是否取整，明确写在具体效果中。
room:damage{
  source = attacker, target = defender, kind = "percent",
  damage = math.floor(defender.max_hp / 3), reason = "百分比伤害",
}

-- 例如按实际扣血吸取；具体技能若按申请量回血，应按该技能规则另外给 num。
room:recover{ source = attacker, target = attacker, num = dealt.actual, parent = dealt }

-- 直接流失体力：只发 HP 时机，不冒充攻击或伤害。
room:changeHp{ target = defender, num = -50, source = room, reason = "体力流失" }
```

`room:damage` 默认有 skill 时视为 attack，否则 fixed；带技能来源的固定伤害必须显式指定 `kind`。fixed/percent 不自动乘克制、本系、致命或攻击增伤；它们会经过通用 `BeforeDamage`，减免效果应检查 `data.kind`。这里提供的是结算类别，尚未替所有官方效果决定独特的免疫、吸取与克制规则。

技能字段记录来源，不等于把该技能效果注入嵌套事件。只有显式传第二个参数 `{source=...,skill=...}` 才收集当前技能效果；普通附加伤害、反伤不传，避免意外再次调用触发它的效果。反伤作者仍须通过 `parent` 或实例标记排除反伤再次反伤。

`GameLogic:changeHp/recover(target,num,reason,source)` 保留数值式旧入口，返回 `actual,data`。新效果优先使用结构化 room API。

## Buff 生命周期

```lua
local heal_each_turn = Seer:createEffect{
  id = "example_regen", timing = SeerTiming.TurnEnd,
  can_trigger = function(_, ctx) return not ctx.logic:isFainted(ctx.owner) end,
  on_use = function(_, ctx)
    ctx.room:recover{ target = ctx.owner, source = ctx.buff.source,
      num = 100, reason = "持续回复" }
  end,
}
room:addBuff(pet, {
  id = "example_regen", source = caster, duration = 3, category = "turn",
  effects = { heal_each_turn }, state = {},
})
-- 「下两回合」：duration=2, start_round=logic.round+1。
-- 消除成功返回实际移除数；不影响能力等级或其它分类。
local removed = room:dispelBuffs(pet, "turn", caster)
```

- 同房间、同对象、同 id 重用会刷新为新实例并重置 `state`；旧实例失效。不同 id 共存。没有通用叠层规则；层数、护盾容量、剩余次数由效果在独立 state 内管理。纯数据 state 深复制，对象引用保留。
- `duration=N` 默认含发动当回合；开战前添加从第 1 回合开始。`TurnEnd` 和 `AfterTurnEnd` 全部结算后清理到期实例，因此顺序不会吞掉最后一次持续回复。重复调用到期清理不重复触发。
- 在 TurnEnd 等事件处理过程中才添加的 Buff 不回填当前 Handler；若要求从下一回合开始计数，明确传 `start_round=logic.round+1`。
- 省略 duration 持续到主动移除或战斗结束；category 是显式标签，不替技能猜测某个效果是否属于回合类。`dispellable=false` 不允许被 `dispelBuffs` 消除。
- `BeforeBuffAdd/AfterBuffAdd` 报告添加或刷新；`BeforeBuffRemove/AfterBuffRemove` 报告消耗与驱散。自然到期、战斗结束不发可阻止的移除前置，但仍发后置。
- 同 id 刷新不冒充被消除，只发添加结果 `reason=refresh`。移除结果区分 `dispel/consumed/expired/battle_end`。
- 当前 Handler 中已经移除的 Buff 不再执行后续效果；被移除的实例仍被临时加入自己的 `AfterBuffRemove` 队列，支持“护罩消失后……”；须检查 `ctx.data.buff == ctx.buff` 与 reason。
- 战斗结束清空已登记对象的本局 Buff，清理回调期间不接受新 Buff。天气等额外对象通过房间注册，同样可挂载；参与战斗期间应保持注册。

本次将雷神觉醒接入 Buff（三回合致命概率增加 100 个百分点，封顶 100%）。这是本项目指定扩展，不能把它当作官方雷神觉醒原始文案。王系参考技能的旧 pet 临时字段尚未全部迁移；不会被新的分类驱散 API 自动识别。

## 能力等级与公式核对的边界

六项等级为攻击、防御、特攻、特防、速度、命中，范围 `[-6,6]`；全部写入走 room。五项非命中能力目前用正等级 `(2+n)/2`、负等级 `2/(2-n)`；命中采用独立表。消强、解弱已有专用前后时机；反转只有事件契约，尚无 room 原生反转函数，王系两条技能仍用普通增量近似。

普通单击现行实现：先算 `((等级×0.4+2)×威力×攻击/防御/50+2)×本系×克制` 并向下取整，再乘 `217..255 / 255` 并取整；致命时乘抗性并取整，再乘 2。属性无效或威力为 0 时基础伤害为 0。低威力取整样例参考[新萌小山东的原始实测](https://www.bilibili.com/opus/1173979935440633860)；该文并非官方算法规范，且提到了低威力连击致命的特殊表现，当前实现未覆盖该分支。

**尚不能承诺“严格同步官方所有公式”。** 未验证完整实机精度、低威力致命特例、每段独立随机还是同次随机、套装/宝石/穿甲/固伤抗性等专用分支。当前连击仍沿用原来的逐击结算及 20 击上限；本文没有把这一实现宣称为官方连击规则。`Skill.crit_rate` 仍是本项目的额外致命值（基础 1/16，每点额外 1/16），不能直接塞 SeerAPI 的百分数 6.25。以上是明确保留的未完成项。

## 最小验证

```sh
lua tests/hp_buff_test.lua
lua tests/effect_dispatch_test.lua
lua tests/battleroom_test.lua
lua packages/seer-core/test/test_min.lua --auto 123
lua packages/seer-core/test/test_min.lua 123  # 玩家固定操作王·雷伊，手动选技能
```

没有执行全面项目测试。王系 CLI 保留已经整理的四格与第五技能；第五 PP 由核心初始化，测试不再私自补账。惊颤霹雳的 500 固伤已改成独立事件；其余缺失技能效果见迁移清单。

# 效果挂载与时机分发

本页描述当前效果框架；包 README 后续章节中的旧触发器设计不适用。

## 职责与生命周期

- `GameObject.effects` 保存对象自己的效果。`Unit`、`Pet`、`Skill`、`BattleRoom` 均继承它，天气等对象也可继承。构造时复制效果数组，`addEffect` / `removeEffect` 按引用挂卸，同一对象重复挂载同一效果不叠加。
- `BattleRoom` 保存局内信息、玩家、精灵和有序效果来源对象。它只登记对象引用，不维护全局效果索引；房间自己的效果自动参与收集。
- `GameLogic:run()` 在 `BattleStart` 前登记双方 `Unit` 及其精灵。玩家和精灵的效果事先挂在对象上，登记不会复制效果。直接调用 `trigger` 或 `doAttack` 做局部结算时，可先调用 `registerEffectSources()`；重复登记不会重复触发。
- `GameLogic:trigger(timing, target, data, action)` 是唯一时机入口。每次新建事件和 handler，读取当前挂载表，仅把 `effect:getTiming() == timing` 的效果加入候选集。
- `EffectHandler:resolve(ctx)` 按优先级降序、加入顺序升序结算 `canTrigger → cost → use`。同优先级的收集顺序为当前技能、房间、按注册顺序排列的常驻对象。

当前流程仍让双方所有存活精灵行动，所以开局登记全部精灵；本次没有引入出战/替补规则。常驻效果若只应对自己、友方或特定精灵生效，需在 `can_trigger` 检查上下文。

正在执行的 handler 是本次触发的快照：期间新增、移除效果或注销载体不改写当前队列，从下一次触发开始生效，嵌套触发也会重新收集。

## 挂载示例

以下代码在 `seer.lua` 加载后使用，`leftPet` / `rightPet` 是已创建的精灵。

```lua
local playerEffect = Effect:new{
  id = "player_turn_start",
  timing = SeerTiming.TurnStart,
  on_use = function(_, ctx)
    ctx.owner.turns_seen = (ctx.owner.turns_seen or 0) + 1
  end,
}
local left = Unit:new{ id = 1, pets = { leftPet }, effects = { playerEffect } }
local right = Unit:new{ id = 2, pets = { rightPet } }
local room = BattleRoom:new{ id = 100 }
local weather = GameObject:new{ name = "天气" }
room:addObjectEffect(weather, Effect:new{
  id = "weather_power",
  timing = SeerTiming.BeforeDamageCalculate,
  on_use = function(_, ctx)
    ctx.data.power = ctx.data.power + 10
  end,
})
room:setTag("mode", "standard")
local logic = GameLogic:new{ room = room, units = { left, right }, rng_seed = 123 }
logic:run()
```

房间效果直接调用 `room:addEffect(effect)`。普通对象可以先 `room:registerEffectSource(object)`，再自行挂卸效果；也可用 `room:addObjectEffect(object, effect)` 一次完成。`unregisterEffectSource` 停止后续收集，但不删除对象自己的效果。旧 `Unit:addBuff/getBuff/getBuffs` 兼容同一张 `effects` 表。

## 当前技能与效果上下文

`doAttack()` 创建局部 `{ source, skill }`，显式传入这次攻击的每个 `trigger`，包括伤害计算和攻击结束。它不会注册全部携带技能，也不会把当前技能保存在 logic 上；未使用的技能和后续回合不会因此获得技能效果。携带技能的常驻被动需要显式挂到玩家或精灵上。

- `ctx.source` / `ctx.target`：本次行为的来源与目标。
- `ctx.owner`：当前效果拥有者；常驻效果是挂载对象，当前技能效果是使用者。
- `ctx.effect_source`：实际挂载对象；技能效果为 `Skill`，绑定效果为 `Buff`。
- `ctx.buff`：本次绑定实例，局内状态写在 `ctx.buff.state`。
- `ctx.logic` / `ctx.room` / `ctx.timing` / `ctx.event`：执行器、局内容器、时机类与本次事件。
- `ctx.data`：当前时机数据，效果之间共享，修改伤害参数等应写入这里。
- `ctx.damage`：执行当前效果前读取的伤害兼容字段，写它不会修改结算数据。

每个效果得到独立的上下文表，嵌套触发不会覆盖外层 `owner/event`。`Effect` 定义可以共享；层数、剩余回合等局内状态放到具体挂载对象或房间，禁止写入共享技能或共享效果定义。

`on_cost` 返回 `false` 表示不执行本效果，返回 nil 仍执行。`on_use` 返回 `true` 或设置 `ctx.event.broken = true` 可中止本时机剩余队列，`trigger` 返回 `broken, event`；这不等于自动取消整个外层流程。`BeforeAttack` 的打断会阻止本次攻击。

`timing` 应使用 `SeerTiming.Xxx` 时机类，字符串名称不会匹配。旧 `skill_table`、`addTriggerSkill`、`triggerEffects` 和 `EffectHandler:trigger` 已移除。

未命中时仍分发攻击技的 `AttackEnd` 和技能的 `AfterSkillUse`，不会分发 `AfterAttack`。`UseSkill` 统一处理 PP 和命中；攻击调用独立伤害入口，回复与直接扣血也会触发 HP 时机。完整时序、Buff 生命周期与 API 见 [战斗规则](../../../docs/battle-rules.md)。

Buff 存在 `GameObject.buff_instances`，由 room 管理。普通挂载效果遵守队列快照；Buff 被消耗或驱散后，即使仍在当前快照也不再执行。唯一例外是已移除实例仍可通过 `AfterBuffRemove` 观察自己的移除结果。

## 最小验证

在仓库根目录运行：

```sh
lua5.4 tests/effect_dispatch_test.lua
lua5.4 tests/battleroom_test.lua
lua5.4 tests/hp_buff_test.lua
```

测试覆盖时机过滤、开局登记、技能作用域、双方拥有者、动态挂卸、嵌套触发、共享数据、稳定顺序、打断、未命中收尾及房间隔离。不替代全面项目测试。

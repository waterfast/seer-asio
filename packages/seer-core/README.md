# seer-core —— Lua 侧战斗核

这是**战斗大脑**：赛尔号的对战规则全在这里。对应 freekill 的 `packages/freekill-core`，
位置和目录也是照 `docs/architecture.md` §9 的规划来的。

```bash
# 单跑测试：不需要 C++、不需要客户端、不需要数据库
make test-lua
# 或者
cd packages/seer-core && lua5.4 tests/test_core.lua
```

只依赖 **Lua 5.4**（`xoshiro256**` 用了 64 位整数运算）。

---

## 1. 这个包现在有什么

| 文件 | 干什么 | 对应 freekill |
| --- | --- | --- |
| `lua/core/timing.lua` | **时机基类**（Timing）：一个"时刻"，把这一刻想插一脚的人按优先级问一遍 | `lua/core/trigger_event.lua`（TriggerEvent） |
| `lua/core/trigger_data.lua` | 时机/事件的数据对象基类：`data` 在结算链上被各个时机改来改去 | `ltk/core/events/init.lua`（TriggerData） |
| `lua/core/skill.lua` | **技能**：Skill（数值）+ TriggerSkill（时机钩子）+ SkillSkeleton（spec 工厂）+ **SkillSet（技能栏：4 个普通技能 + 第五技能）** | `ltk/core/skill*.lua` |
| `lua/core/effect/init.lua` | **效果**：Effect 类（注册表、目标解析、结算、生命周期：瞬时 / 持续两种寿命） | `ltk/core/skill_skeleton.lua` 的 effects 机制 |
| `lua/core/effect/kinds.lua` | **效果类型的注册点**：内置 12 种（伤害/回复/能力等级/印记/消强/增伤…） | 同上 |
| `lua/core/mark/init.lua` | **印记基类**：注册表、生命周期、被动触发器（`Mark.defs` / `MarkTrigger`） | 无（freekill 没有对应物） |
| `lua/core/mark/status.lua` | **异常状态类**：弱化类（WeakenStatus）/ 控制类（ControlStatus）+ 内置 7 种状态 | 无 |
| `lua/core/mark/buff.lua` | **增益印记类**（BuffMark）+ 两个通用例子（护盾 / 强化） | 无 |
| `lua/core/pet.lua` | **精灵**：PetSpecies（种族值）+ Pet（六项当前数值是**字段**，见 §3.2） | `ltk/core/general.lua` + `player.lua` |
| `lua/core/registry.lua` | 全局注册表 `Seer`：图鉴、技能、效果类型、时机、扩展包 | `ltk/core/engine.lua`（运行时叫 `Fk`） |
| `lua/server/battle/timing.lua` | 具体的**时机表**和它们的数据类（31 个时机） | `ltk/core/events/*.lua` |
| `lua/server/battle/game_event.lua` | **流程事件基类**（GameEvent）：协程事件 + 清场事件 | `lua/server/gameevent.lua` |
| `lua/server/battle/hp.lua` | **生命值流程**：ChangeHp（唯一改血的入口）/ Damage / Recover | `ltk/server/events/hp.lua` |
| `lua/server/battle/gameflow.lua` | **回合流程**：Round（一大回合）/ Turn（一次行动）/ UseSkill，以及 `logic:run()` | `ltk/server/events/gameflow.lua` |
| `lua/server/battle/logic.lua` | 战局调度器：**事件管理器** + 时机注册 + 结算门面 + 问客户端 | `lua/server/gamelogic.lua`（GameLogic） |
| `lua/server/battle/damage.lua` | 伤害公式（系数全是可改的常量） | — |
| `lua/server/battle/element.lua` | 属性克制机制 + 倍率表 | — |
| `lua/server/rpc/jsonrpc.lua` | **JSON-RPC 2.0**（整份抄自新月杀，见 §5.1） | `lua/server/rpc/jsonrpc.lua` |
| `lua/server/rpc/stdio.lua` | stdio 传输（一行一条 JSON 消息） | `lua/server/rpc/stdio.lua` |
| `lua/server/rpc/peer.lua` | 出口：`call`（发请求等答复）/ `notify` + 信号（notifyPlayers/delay/gameOver） | `lua/server/rpc/fk.lua` 的 callRpc 部分 |
| `lua/server/rpc/dispatchers.lua` | **对面能调我们的方法表**（ping/startGame/runGame/handlePlayerAction…） | `lua/server/rpc/dispatchers.lua` |
| `lua/server/rpc/entry.lua` | RPC 进程入口：载入核心 + 主循环 | `lua/server/rpc/entry.lua` |
| `lua/server/request/init.lua` | **询问机制**：Request（问谁/问什么/兜底答复/超时与取消规范化） | `lua/server/request.lua` |
| `lua/server/request/handler.lua` | **RequestHandler** 基类 + AiHandler（就地作答）+ DefaultHandler（无头降级） | `lua/core/request_handler.lua` |
| `lua/server/request/cli.lua` | **命令行处理器**：单机版（`make play`） | 无（freekill 只有 Qt 客户端） |
| `lua/server/request/rpc.lua` | **RPC 处理器**：挂起等 C++/Unity 回话 | 同 request.lua 的客户端一侧 |
| `lua/server/session.lua` | 会话：roomId → 一局对战（房间适配器 + BattleLogic + 精灵） | `lua/server/roombase.lua` 的一部分 |
| `lua/lib/json.lua` / `lua/lib/cbor.lua` | 第三方编解码库（都是 MIT，逐字节复制） | 同名文件 |
| `lua/specs/standard/` | **标准阵容**：雷伊（电系）/ 盖亚（战斗系），种族值与技能表照图鉴抄的；`effects.lua` 是"包内注册新效果"的样板 | `standard/` |
| `examples/battle_demo.lua` | 跑一局并打印战报（进程内，`make example`） | — |
| `examples/rpc_demo.lua` | 同一局，但战斗核在**子进程**里、用 JSON-RPC 驱动（`make example-rpc`） | — |
| `examples/single_player.lua` | 单机版：命令行里和 AI 打一局（`make play`），界面层可换 | — |
| `lua/seer.lua` | 载入入口：环境、全局类、加载扩展包 | `lua/freekill.lua` + `lua/fk_ex.lua` |
| `lua/specs/demo.lua` | 示例数据包（4 只精灵、9 个技能、1 个特性）**兼写法样板** | `standard/`、`standard_cards/` |
| `tests/test_core.lua` | 870 项单跑测试，同时也是一份用法说明书 | — |

---

## 2. 名词对照表（读 freekill 源码时对着看）

命名刻意对齐，但赛尔号没有"武将/手牌"，所以有几处必须换名：

| freekill | seer-core | 说明 |
| --- | --- | --- |
| `Player` | `Pet` | 参战单位。赛尔号里技能和效果挂在**精灵**身上，所以精灵就是调度里的"行动者" |
| `General`（武将） | `PetSpecies`（种族） | 静态数据（只有战斗用得上的那几项，见 §6） |
| `TriggerEvent` | **`Timing`** | 一个"时机"（改名的原因见 §4：`event` 这个词要留给 GameEvent） |
| `Skill` / `SkillSkeleton` | `Skill` / `SkillSkeleton` | 技能与它的 spec 工厂 |
| `SkillEffect` / `Card` | `Effect` | 赛尔号的"效果"是独立一等公民（挂在精灵身上、有回合数） |
| `GameEvent` | `GameEvent` | 一个"流程事件"（协程、能等、能插子事件、能被打断） |
| `Fk`（Engine 实例） | `Seer` | 全局注册表 |
| `GameLogic` | `BattleLogic` | 战局调度器（含事件管理器） |
| `logic.skill_table` | `logic.trigger_table` | 挂在时机上的不止技能（还有效果变出来的触发器） |
| `logic.current_trigger_event_id` | `logic.current_timing_id` | **时机**编号 |
| `logic.current_event_id` | `logic.current_event_id` | **流程事件**编号（两套编号分开数） |
| `room:damage/recover/changeHp` | `logic:damage/recover/changeHp` | 结算门面（freekill 混进 Room，这里放在 logic） |
| `room.current` + `.next` 环 | `logic:getActors()` 数组快照 | 见 §5 第 1 条 |

---

## 3. 核心思想：技能 = 数值 + **效果拼装**

一个技能要回答两个问题：

1. **它长什么样**（属性、威力、PP、打几下）—— 数值；
2. **它干了什么**（附加中毒、吸取、弱化、连击……）—— **一串效果**。

赛尔号的技能基本上就是这两样拼起来的，所以本项目的技能主线是 **effects 列表**：
写一张表，就是一个技能，**不走骨架、不拆子对象**。

```lua
-- 「闪电风暴」：电系特殊 90 威力，命中后 10% 让对方麻痹
{ name = "闪电风暴", element = "电", category = Skill.Special,
  power = 90, pp = 10, accuracy = 95,
  effects = { { kind = "status", status = "paralysis", probability = 10 } } }
```

**只有**需要挂在时机上的东西（主要是**特性**、以及少数持续效果）才写 `triggers`，
那时核心才建骨架、把每条钩子拆成 `#名字_序号_trig` 子对象：

```lua
{ name = "静电庇护", tags = { Skill.Ability, Skill.Compulsory },
  triggers = {
    [SeerTiming.RoundEnd] = {
      priority = 0,      -- <= 0 = 必发效果，不询问玩家
      can_trigger = function(self, timing, target, pet, data) ... end,
      on_trigger  = function(self, timing, target, pet, data) ... end,
    },
  } }
```

> 这一点和 freekill 不一样，是刻意的：freekill 那套骨架是为"一个技能横跨多个时机"
> 设计的（三国杀的技能常常如此）。赛尔号的技能绝大部分不挂时机，
> 全都走骨架只会让"一个技能 = 一堆对象"变成默认印象，白读一层。

### 3.1 效果工具箱

| kind | 干什么 | 关键字段 | 官方的对应 |
| --- | --- | --- | --- |
| `damage` | 造成伤害（固定值，不吃克制/暴击） | `value` / `element` | — |
| `heal` | 回复体力 | `value` 或 `ratio`（按最大体力比例） | 43 恢复 |
| `stat` | 能力等级变化 | `stages = { attack = 2 }`（**体力没有能力等级**） | 4 强化 / 5 弱化 |
| `mark` / `status` | 给目标**挂一个印记**（异常状态或增益印记） | `mark = "burn"` / `probability` | 10 施加异常 / 46 抵挡 |
| `clear_stages` | 消除能力等级 | `side = "up"`（消强）/ `"down"`（解弱）/ `"all"` | **33 消强 / 3 解弱** |
| `drain` | 吸取：回复"造成伤害的 ratio 倍" | `ratio`（默认 0.5） | — |
| `recoil` | 反作用力：自己挨"造成伤害的 ratio 倍" | `ratio` / `value` | — |
| `cure` | 解除异常状态（只清弱化/控制类） | `status`（不填 = 全解） | — |
| `add_damage` | 在本次伤害之外再打一笔固定伤害 | `value` | 29 / 38 / 60 附加伤害 |
| `power_modifier` | 威力倍率（**前置**效果：伤害算出来之前改威力） | `multiplier` + `condition` | 37 / 42 / 88 增伤 |
| `modifier` | 持续修正某个时机的数值 | `duration` + `extra.timing` / `extra.apply` | — |
| 连击 | 技能字段，不是效果 | `hits = 2` 或函数 | **31 连击** |

每个效果都能写的通用字段：`probability`（概率）、`condition`（附加条件）、
`target`（对谁）、`duration`（持续几回合）、`phase`（`"before"`/`"after"`）、
`then_effects`（本体生效后再接着结算一串，用来写"消除成功则令对方烧伤"）。

> 右列是**官方技能表里的"效果ID"**——也就是说"可复用的模板 + 参数"本来就是官方的做法，
> 我们只是把它落成 Lua 表。这也是为什么 `clear_stages` 是一个 kind 带 `side` 参数，
> 而不是"消强"和"解弱"两段代码。

加一种新效果类型**不用改核心**：

```lua
Effect.registerKind("steal_pp", {
  name = "吸取 PP", instant = true,
  validate = function(spec) return type(spec.value) == "number", "需要数字 value" end,
  on_apply = function(effect, pet, ctx) ... end,
})
```

### 3.2 「按结果算」的效果要读 ctx

有些效果没法只看 spec 就知道该干什么，得看"刚刚打出了什么"：

```lua
{ kind = "drain", ratio = 0.5 }                      -- 回复造成伤害的一半
{ kind = "stat", stages = { defense = -1 },
  probability = 30,
  condition = function(effect, ctx)                  -- 只在造成伤害时才附加
    return ctx.damage > 0
  end }
```

`ctx`（技能结算上下文）里有什么：`source` / `target` / `skill` / `damage`（本次累计伤害）
/ `hits`（打了几下）/ `crit` / `missed` / `extra`（效果之间传数据的小口袋）。

**连击**是技能自己的字段：`hits = 2`，或者 `hits = function(skill, source, target, logic) ... end`。
每一下都是**独立的伤害结算**（各自过一遍伤害链），所以减伤/护盾/免疫是逐下生效的；
目标中途倒下，剩下几下就不打了。

### 3.3 旧写法（spec 全表）

同一个技能也可以只写数值和效果、不写任何代码，例如：

```lua
{
  name = "火花", id = 1002, element = "火", category = Skill.Special,
  power = 40, pp = 25, accuracy = 100, priority = 0, target = "enemy",
  effects = {
    { kind = "status", status = "burn", probability = 10 },
  },
}
```

一个特性（特性没什么特别的：就是"没有威力、挂在时机上"的技能）：

```lua
{
  name = "茂盛", category = Skill.Status, tags = { Skill.Ability, Skill.Compulsory },
  target = "self",
  triggers = {
    [SeerTiming.HpChanged] = {
      priority = 1,
      can_trigger = function(self, timing, target, pet, data) ... end,  -- 要不要发动
      on_trigger  = function(self, timing, target, pet, data) ... end,  -- 发动干什么
    },
  },
}
```

### 3.1 精灵的数值：存在字段上，不是存在表里

战斗里要读"当前属性值"，直接读字段：

```lua
pet.hp          -- 当前体力
pet.max_hp      -- 最大体力（两个是分开的字段，不会搞混）
pet.attack      pet.defense      pet.sp_attack      pet.sp_defense      pet.speed
```

这几个字段是**当前生效值**：性格修正（1.1 / 0.9）和能力等级（±6）都已经算进去了。
好处是**伤害公式、出手顺序、UI 显示读的是同一个数**，不存在"某处忘了乘能力等级倍率"
这种 bug —— 那种 bug 不报错，只会让数值悄悄不对，最难查。

分两步算，两边都拿得到：

| | 是什么 | 怎么拿 |
| --- | --- | --- |
| 面板值 | 种族/个体/学习力/等级/性格都算完，**不含**能力等级 | `pet:getPanelStat("speed")` |
| 当前值 | 面板值 × 能力等级倍率 | `pet.speed`（字段本身） |

种族值（静态图鉴数据）仍然在 `species.base_stats` 这张表上——那是天生适合用表的静态数据，
而"这只精灵现在的六项数值"是会变的、每只都不同的东西。要按名字遍历六项时用
`Pet.STAT_FIELDS`（给协议/UI 用，也有 `pet:getStatSnapshot()`）。

改能力等级会**立刻**刷新字段（`pet:setStatStage("sp_attack", 2)` → `pet.sp_attack` 马上变），
所以不需要手动 `recalcStats()`，也不用记着"读的时候要乘倍率"。

### 3.2 技能栏：4 个普通技能 + 第五技能

技能和 PP 都交给 `SkillSet`（技能栏）管，第五技能是**单独一个属性**：

```lua
pet:getSkills()        -- 4 个普通技能（不含第五技能、不含特性）
pet:getFifthSkill()    -- 第五技能，没有就是 nil
pet:getAllSkills()     -- 普通技能 + 第五技能
pet:getSkill(5)        -- nil —— 第五技能不是 slots[5]，它不占普通技能格
```

**第五技能在机制上就是一个普通技能**：同一个 `Skill` 类、一样有 PP、一样走
`Skill:checkUsable`。它和普通技能的区别只是**摆在哪个技能位**（图鉴写的就是"4 + 1"，
配招和 UI 也是分开的），所以核心不因为"它是第五技能"而给它加任何规则。
不塞进 `slots[5]` 的理由是"位置"层面的：

- "哪几个是配的普通技能"在类型层面就是确定的。塞成 5 元素数组的话，每一处用到技能
  的地方都得判断"这是不是第 5 个"——只要有一处忘了（"随机挑一个技能""换掉第 2 个技能"），
  第五技能就会被当普通技能用出去；
- 整组换普通技能（`setSlots`）时不会顺手把它清掉；
- 客户端要把它单独摆一个位置，不必自己数下标。

### 3.2.1 技能能不能用：三个来源，一个判断

"技能要有可用性"这件事收敛在 `Skill:checkUsable(pet, ctx)` 一处，它有**三个来源**：

| 来源 | 写法 | 原因字符串 |
| --- | --- | --- |
| PP 用完了 | `pet:usePP(name)` / 技能栏里的 `pp` | `no_pp` |
| 被封印（禁止使用这个技能） | `pet:sealSkill("技能名")` / `sealSkills{...}` | `sealed` |
| 技能自己写了条件 | spec 里的 `usable` | `forbidden`（`usable = false`）/ `condition`（函数返回 false） |

选技能（`AskForAction` 列候选）和执行技能（`GameEvent.UseSkill` 拦截）用的是**同一个判断**，
所以不会出现"界面能选、真用被拒"。判断**带原因返回**，因为客户端要把技能摆成灰的、
还得说明为什么，而规则代码也常常想知道"是没 PP 了还是被封印了"：

```lua
{
  name = "背水一击", pp = 5, power = 120,
  usable = false,                     -- 禁止使用（剧情锁/规则禁用/封招……）
  -- 或者按场上情况判断：
  -- usable = function(skill, pet, ctx) return pet:getHpRatio() < 0.5 end
}
```

```lua
local ok, reason, text = pet:checkSkillUsable("背水一击")   -- false, "condition", "使用条件不满足"
local r = logic:useSkill{ source = pet, target = foe, skill = sk }
r.prevented, r.prevent_reason, r.prevent_text                -- true, "condition", "使用条件不满足"
```

三点实现上的注意：

- **封印记在精灵身上**，不是改 `skill.usable`：技能对象是全局共享的（图鉴里就那一份），
  改它等于把全场所有精灵的同一个技能一起封了；而"禁止你使用技能"是精灵身上的状态，
  对手封的、效果给的、回合数到了就解。API：`pet:sealSkill(name)` / `sealSkills{...}` /
  `unsealSkill(name)` / `unsealAllSkills()` / `getSealedSkills()`。
- `AskForAction` 的请求里除了 `skills`（能用的技能名）还带 `unusable = { {name, reason, text} }`，
  客户端据此把技能摆成灰的；`fifth` 字段纯粹是**摆位**提示，不是可用性规则。
- 玩家点了一个用不出来的技能时，**不会闷声不响地跳过这一回合**：
  `logic:askForAction` 把拒绝原因交回去，回合流程播一条带 `skill` / `reason` / `text` 的
  `NoAction` 事件，客户端就能提示"这个技能现在用不了"。
- 老写法把条件写在 `extra.usable` 里仍然能用（会被收到 `self.usable` 上），但新 spec 请写顶层 `usable`。

原因字符串全集在 `Skill.Unusable`（每个都有对应的 `Skill.UnusableText` 中文提示）：
`no_pet`、`no_skill`、`sealed`、`no_pp`、`forbidden`、`condition`、
`no_skill_chosen`（这回合没选技能）、`no_usable_skill`（一个能用的都没有）。

### 3.3 效果写在哪里：效果类型 = 插件（注册点有三处）

效果类型不是靠继承，而是靠**注册表**。`Effect.registerKind(key, def)` 就是全部用法，
一张说明书管四件事：`validate`（数据合法性，加载期报错）、`instant`（寿命）、
`on_apply`（结算体）、`triggers` / `on_expire`（持续型的钩子与收尾）。

| 写在哪 | 什么时候用 | 例子 |
| --- | --- | --- |
| `lua/core/effect/kinds.lua` | 通用到任何精灵都成立的效果 | 内置 12 种：`damage`/`heal`/`stat`/`drain`/`recoil`/`cure`/`mark`/`status`/`clear_stages`/`add_damage`/`power_modifier`/`modifier` |
| `lua/specs/<包名>/effects.lua` | 具体玩法自己造的效果（**不用改核心**） | 标准包的 `steal_stages`/`hp_ratio_damage`/`seal_skill`/`endure` |
| `Seer:registerEffectKind` | 运行期临时加（模式/测试） | 测试里现场注册一个再马上用 |

扩展包里的写法（摘自 `lua/specs/standard/effects.lua`）：

```lua
return {
  name = "standard",
  effects = {
    { key = "hp_ratio_damage",
      def = {
        name = "按体力比例造成固定伤害", instant = true,
        validate = function(spec) ... end,
        on_apply = function(effect, pet, ctx)
          effect.logic:damage{ target = pet, fixed = math.floor(pet.max_hp * effect.ratio),
                               reason = effect.name, is_status_damage = true }
        end,
      } },
  },
  skills = { { name = "试作·逆流碎击", effects = { { kind = "hp_ratio_damage", ratio = 1/6 } } } },
}
```

没注册的类型**当场报错**（`请先用 Effect.registerKind 注册`），不静默失效——
数据笔误在加载期就暴露。

### 3.3.1 技能效果和"身上的回合类效果"是同一个 Effect

没有任何"技能效果类 / 状态效果类"之分，区别只有**寿命**（`kind_def.instant` +
`duration`）：瞬时效果当场算完；持续效果 `install()` 装时机钩子、写进 `pet.effects` 表，
之后由 `logic:tickDurations()` 每回合驱动，到期 `remove()` 把触发器摘干净。

精灵身上因此有**两张表**，语义不同但共享同一套底层机制：

```lua
pet.marks    -- key  → Mark   ：印记/异常状态。有名字有描述、能被解毒、UI 要显示
pet.effects  -- name → Effect ：效果。纯机制（减伤/反击/抵挡/封招），不进状态栏
```

API：`pet:hasEffect / getEffects / getEffectsByKind / countEffects / removeEffectsByKind`。
遍历一律走这些方法（按名字排序返回数组），别用 `pairs(pet.effects)`——
哈希顺序会让同一局回放出现两种结果（§2.3）。

**完整分析（含"我要加 X 该改哪里"的对照表）见 [`docs/effects-marks-status.md`](../../docs/effects-marks-status.md)。**

---

### 3.4 印记：异常状态和增益印记共用一个基类

**异常状态不是一个单独的体系，它就是一种印记**——这是官方的分法：
麻痹是「控制类异常状态」，中毒/烧伤/冻伤是「弱化类异常状态」，而护盾、加速这类
增益印记除了"对谁好"之外机制一模一样（有名字、有回合数、挂上去之后自己动、能被解除）。

`lua/core/mark/` 这个文件夹里是三层：

```
Mark              基类：挂在谁身上 / 还剩几回合 / 有哪些被动钩子 / 叠层 / 序列化
├── StatusMark    异常状态基类（mark/status.lua）：类型只能是弱化类或控制类
│   ├── WeakenStatus   弱化类：默认行为从数据派生（turn_end_damage / weaken_attack）
│   └── ControlStatus  控制类：默认行为从数据派生（block_chance）
└── BuffMark      增益印记（mark/buff.lua）
```

有子类的好处很直接：**同一类状态的钩子只写一遍，具体状态只写数据**。
所以再加一个异常状态是 5 行：

```lua
Status.register("poison", { name = "中毒", class = "weaken", turn_end_damage = { 1, 8 } })
Status.register("burn",   { name = "烧伤", class = "weaken", turn_end_damage = { 1, 16 },
                            weaken_attack = { [Skill.Physical] = 0.5 } })
```

`Mark.defs` 里现在有 11 个：麻痹/睡眠/冰冻/害怕（控制类）、中毒/烧伤/冻伤（弱化类）、
护盾/强化印记（增益类），以及 standard 包自己注册的 `charge`（电系伤害翻倍）和
`dot30`（3 回合每回合 30 点固定伤害）——**包可以自己加印记，不用改核心**
（`spec.marks = { { key = ..., name = ..., mark_type = ..., triggers = {...} } }`）。

**印记和技能上的效果是怎么分工的**，这是关键：

| | 谁在动 | 干什么 |
| --- | --- | --- |
| 技能上的 `effects` | **主动** | 打伤害、改能力、**把印记挂上去**、按结果吸取…… |
| 印记上的 `effects` | 被动 | 挂上去**那一刻**立刻结算一次（比如"立刻掉 1/8 血"） |
| 印记上的 `triggers` | 被动 | 之后**每个时机**自己动（回合末掉血、行动前掐掉行动…） |

一句话：**技能负责"挂"，印记负责"之后一直管"**。于是"中毒"只写一次，
所有会造成中毒的技能都只是 `{ kind = "mark", mark = "poison", probability = 5 }`。

其它几条设计：

* `mark_type` 是**枚举**（`Mark.TYPE`：WEAKEN / CONTROL / BUFF），加一种状态 = 加一张表；
  类别行为由子类的 `applyDefaults` / `defaultTriggers` 补上，作者自己写的钩子优先。
* **可单测的查询方法**：`mark:getTurnEndDamage()`、`mark:getAttackMultiplier(category)`、
  `mark:getBlockChance()`、`mark:rollsActionBlock(logic)`——不跑一整局就能验证数值。
* **`on_attach` / `on_detach`**：触发器之外还要做的事（封招、光环）有正式位置，
  摘掉时能撤销（封招就是靠它 `sealSkill` / `unsealSkill`）。
* **实例私有数据 `mark.extra`**：`logic:applyMark{ mark = ..., extra = {...} }`，
  用来传"封住的是哪个技能"这类不可能写死在定义里的参数。
* **印记能改当前数值**：`stat_multipliers = { speed = 0.5 }`（麻痹减速就是这么写的），
  `Pet:recalcStats` 会把它算进字段，所以 `pet.speed` 永远是当前真值。
* **"解除异常状态"只清弱化/控制类**（`Mark.STATUS_TYPES`），不会顺手把护盾拆了——
  两类挂在同一个表里，但语义上分得清。
* **场地/天气**这种"不属于任何一只精灵"的东西，将来复用同一套"定义 + 触发器"机制，
  只是挂靠对象从精灵换成战局；现在先不做。

---

## 4. 两层事件：这是整套系统的骨架

**最容易搞混、也最该先搞懂的一点**：战斗里有两层事件，它们是**上下层关系**而不是继承关系。
本项目的第一版只做了下面那层，结果一遇到"结算到一半要停下来等"就傻眼了——
所以两层都得有。

```
        ┌──────────────────────────────────────────────────────────┐
        │ GameEvent（流程事件）—— "这件事怎么一步步走完"              │
        │ 协程实现。能干三件时机做不到的事：                            │
        │   · 中途停下来等（等玩家下指令、等动画播完）                    │
        │   · 插入子事件（打伤害时插"倒下"流程，走完再回来接着算）          │
        │   · 被打断（伤害被防止 → 整条链上的事件一起作废）                │
        │                                                          │
        │   round /          一大回合：双方各行动一次                   │
        │     turn /         一只精灵的一次行动                         │
        │       use-skill /  一次技能使用                              │
        │         damage /   一次伤害结算                              │
        │           change-hp   真正的体力变化（唯一改 hp 的地方）        │
        └───────────────────────┬──────────────────────────────────┘
                                │ main() 里调 logic:trigger(时机, ...)
                                ▼
        ┌──────────────────────────────────────────────────────────┐
        │ Timing（时机）—— "这一刻谁想插一脚"                          │
        │ 同步实现：按优先级问一遍就返回。31 个时机：                      │
        │   RoundStart/RoundEnd、TurnStart/TurnEnd、BeforeAction…     │
        │   BeforeUseSkill/BeforeHitCheck/PreDamage/DetermineDamage/  │
        │   Damage/Damaged/DamageFinished、BeforeHpChanged/HpChanged… │
        └──────────────────────────────────────────────────────────┘
```

为什么要分两层？因为**时机的粒度是表达力的上限，而流程事件是时间轴**：

- 没有"行动"这个流程事件，就不会有"行动开始/结束"这两个时机；
- 没有"伤害"这个流程事件，就没法表达"伤害被防止了 → 后面那串时机全都不用问"；
- 而"停下来等玩家选技能"根本没法用同步的时机系统表达——那是协程的事。

### 4.1 一次攻击实际长什么样

```
GameEvent.Round                 ← logic:startRound() 触发 RoundStart 时机
  GameEvent.Turn（先出手的那只）  ← prepare(): BeforeAction 时机（麻痹/睡眠在这里掐掉）
      TurnStart 时机
      GameEvent.UseSkill
          BeforeUseSkill 时机
          BeforeHitCheck → 判定命中 → AfterHitCheck 时机
          GameEvent.Damage                  ← 嵌套子事件
              PreDamage 时机（可以防止伤害）
              DetermineDamage 时机（克制/减伤/改成固定值都在这改数值）
              GameEvent.ChangeHp            ← 再嵌一层
                  BeforeHpChanged 时机
                  改 hp（Pet:takeDamage / heal）
                  HpChanged 时机
                  血见底 → 倒下流程（BeforePetFaint / PetFainted）
              Damage 时机
              Damaged 时机（反伤、静电在这里）
          （打空 → SkillMissed 时机，**附加效果一个都不生效**）
          技能附带的效果结算
          AfterUseSkill 时机
      TurnEnd 时机（在 Turn:clear 里）
  GameEvent.Turn（后出手的那只）
logic:endRound()                ← RoundEnd 时机 + 持续效果/异常状态回合递减
```

`Damage:exit()` 里触发 `DamageFinished`——**被打断时它不会触发**，因为被 kill 的事件
协程会被直接关掉。这是 freekill 的语义，本项目的测试专门钉住了它。

### 4.2 事件树查询（回放/复盘/规则判断的基础）

每个流程事件都有 `parent`，所以"我现在是在哪件事里面"是可以精确回答的：

```lua
local damage = logic:getCurrentEvent()          -- 当前在跑的事件
damage:findParent(GameEvent.UseSkill)           -- 这次伤害是哪次技能使用引起的
damage:findParent(GameEvent.Turn)               -- ……在哪次行动里
logic:getEventsOfScope(GameEvent.Damage, 3)     -- 本回合发生过哪几次伤害
round1:searchEvents(GameEvent.UseSkill, 10)     -- 第一回合区间内的所有技能使用
```

`searchEvents` 的区间是 `[id, end_id]`（闭区间）：`end_id` 在事件结束时由清场事件补上，
正好包住它插入的所有子事件。**事件流本身就是回放**（架构文档 §6），两层都记进
`logic.event_log`（用 `kind` 区分）。

### 4.3 RPC：和外面怎么说话（整份抄自新月杀）

`lua/server/rpc/` 是**从 freekill-core 抄过来的**，只做了几处适配（改 require 路径、
环境变量名、去掉它的 Room/Player 代理）。抄而不是自己写，是因为这一层最容易在
"边界情况"上翻车，而新月杀那一层已经在生产里磨过：

| 文件 | 作用 |
| --- | --- |
| `jsonrpc.lua` | JSON-RPC 2.0（Request/Response/Notification + 标准 error code），**整份抄**，也可以切 CBOR（`SEER_RPC_MODE=cbor`） |
| `stdio.lua` | stdio 传输：一行一条 JSON 消息 |
| `peer.lua` | 出口：`Peer.call`（发请求、等答复）/ `Peer.notify`（单向），以及架构文档 §5.4 那几个信号（notifyPlayers / notifyPlayer / delay / gameOver / log） |
| `dispatchers.lua` | 对面能调我们的方法（ping / startGame / runGame / handlePlayerAction / surrender…），返回值约定照抄新月杀：`return true, result` / `return false, "错误名", "说明"` |
| `entry.lua` | 进程入口：载入核心 → 打一条 `hello` → 主循环"读一条、处理一条" |
| `session.lua` | 会话：roomId → 一局对战（房间适配器 + BattleLogic + 精灵） |

两个细节值得记：**stdout 只能传协议**（所以日志一律走 stderr，`Log.sink` 也被换掉了），
以及 `Peer.call` 在等答复期间**照样会服务对面发来的请求**——不然两边同时想说话就会互相堵死。

### 4.4 询问机制：Request + RequestHandler（抄自 freekill-core）

"问玩家一件事"这件事本身是个模型，不是一次 `coroutine.yield`。这一层整份抄自
freekill-core 的 `lua/server/request.lua` + `lua/core/request_handler.lua`，
放在 `lua/server/request/`：

| 文件 | 作用 |
| --- | --- |
| `request/init.lua` | **Request**：问谁、问什么、等几个答复、**兜底答复**是什么、超时/取消怎么规范化。也是唯一一处定义请求长相的地方（`Request:toJson`） |
| `request/handler.lua` | **RequestHandler** 基类 + `AiHandler`（就地作答）+ `DefaultHandler`（无头降级） |
| `request/cli.lua` | **CliHandler**：单机版，把选项打到终端、读一行输入 |
| `request/rpc.lua` | **RpcHandler**：联机版，挂起把请求包发给 C++/Unity，等它回话 |

它们的分工就是一句话：**规则只管"我要问这件事"，"谁去答"由处理器决定**。

```lua
-- 单机：你读终端，对手走 AI
logic:setRequestHandler(you, S.CliHandler:new{ logic = logic })
logic:setRequestHandler(cpu, S.AiHandler:new{ logic = logic, fn = cpu_ai })
logic:start()                    -- 全程不挂起，问到你就阻塞在 io.read 上

-- 联机：两边都挂起（不指定处理器 + interactive = true 时就是这条）
logic.interactive = true
local kind = logic:start()       -- -> "request"：挂起了
kind = logic:resume{ skill = "藤鞭", target = 2 }   -- C++/Unity 把玩家的选择送回来
```

| 处理器 | 谁答 | 会不会挂起 |
| --- | --- | --- |
| `CliHandler` | 终端里敲编号（`make play`） | 不挂起（同步读一行） |
| `RpcHandler` | C++/Unity 客户端 | **挂起**，等 `logic:resume(答复)` |
| `AiHandler` / `logic.request_hook` | 一段函数（跑 AI、示例、自测） | 不挂起 |
| `DefaultHandler` | 没人时用**默认答复**（挑一个能打的技能/选第一个选项） | 不挂起 |

抄过来的几个关键设计（都是踩过坑才知道要有的）：

* **默认答复是必须的**：超时、掉线、AI 托管时流程不能卡死——所以每个参与者都能预先
  登记一个兜底答复，`Request:_finish` 负责把它填进去；
* **三种"不是答复"的值**（freekill 的魔法字符串，这里换成常量）：`""` 取消、
  `__cancel` 明确取消、`__failed_in_race` 抢答失败——收尾时统一规范化，
  规则代码只需要判"取消"和"没有答复"；
* **唤醒理由**：`logic:resume(Request.TIMER_REASON)`（`"request_timer"`）就是
  freekill 的"烧条到头"，收到就按超时处理，改用 AI/默认答复；
* **`MoveFocus`**：询问时会播一条"现在在等谁"，客户端拿它显示焦点和倒计时。

一处**有意为之的差异**：freekill 把请求同时发给所有参与者再轮询；我们的 RPC 协议目前
一次只问一个人（`logic.pending_request` 是单槽），所以问到第二个人会等第一个人答完。
语义上没变——**双方都是在任何 Turn 执行之前问完的**，"各自选技能再排先后手"这条规则
照样成立，只是客户端看到的顺序变成先后两个请求。要做成同时询问，
把 `Request:ask` 的发送循环改成"一次性发给所有人"，再把 pending 变成队列即可。

### 4.4.1 单机版：`make play`

`examples/single_player.lua` 就是在上面这套机制上跑的：你操作雷伊、电脑操作盖亚，
每轮开始会问你"这回合用什么技能"（输入编号，可加目标座位；`a` 交给 AI、`?` 帮助、`q` 退出）。

```bash
make play        # 命令行里真打一局
```

它同时是"**换成 Unity 也能跑**"的证明：那一局里两个座位的答复者就是两个不同的
`RequestHandler`（`CliHandler` + `AiHandler`），而战斗核只知道"有人会回答我"。
换成客户端时，把这两个换成 `RpcHandler` 就是联机版——回合流程、技能结算、
事件通知一行都不用改。测试里还有一组对照：**同样的答复分别走命令行和走挂起，
胜负、回合数、总伤害完全一致**（`tests/test_core.lua` 的「单机版」那一节）。

### 4.5 异常状态的"两份真相"问题怎么解决的

曾经的写法是：战局给每只精灵装几个固定处理器（`registerStatusHandlers`）去读
`Pet.statuses`，状态本身不带触发器。那样做的问题是**状态和行为分成两处**：
状态表里删了一条，处理器还照样按比例掉血 → "状态没了却每回合还在掉血"的幽灵 bug。

现在的做法是**状态自己带触发器，但只能有一个入口**：

- 印记的钩子在 `Mark:attach` 里装、在 `Mark:detach` 里**无条件摘干净**
  （`OwnedTrigger.installTable` 返回自己的触发器数组，摘的时候逐个 `removeTrigger`）；
- 挂/摘都只走 `logic:applyMark` / `logic:removeMark`，到期、被治、被清除**全是同一条路**
  （所以时机 `MarkRemoved` 和通知一定发得出去）；
- 回合数递减在 `logic:tickDurations()`：`mark:tick()` 返回 true 就 `removeMark(..., "expired")`；
- 精灵倒下/下场时 `clearMarks()`，效果那边 `clearEffects()`，同样会走 `detach` / `remove`。

于是"状态"和"它产生的触发器"永远是同一个对象的两个字段（`mark.def.triggers` 是定义、
`mark.triggers` 是装出来的实例），不存在两份真相，也就没有"漏一条路径"的可能。

---

## 5. 和 freekill 不同的几个决定（都是刻意的）

1. **参战单位用"数组快照"而不是环形链。** freekill 给每只精灵一个 `next` 串成环，
   靠 `room.current` 起头。但本项目的**嵌套执行**很频繁（一个时机里插进来的伤害流程
   又会去问一遍所有精灵），那次会重写 `next`，于是外层还没走完的那一圈就踩在一条
   被改过的链上、环接不回起点 —— **死循环，整个房间的 Lua 进程卡住**。
   换成 `logic:getActors()` 每次给一份只读快照，嵌套多少层都不互相干扰。
   顺序按座位号固定，不会从这里漏进随机性。

2. **同一优先级的触发顺序按名字排序**，而不是按注册顺序。注册顺序可能取决于 `pairs`
   的遍历（Lua 不保证），而 §2.3 要求同一局可复现——那就得让顺序只由数据本身决定。

3. **凡是要"遍历一张表然后产生顺序"的地方都排过序**：`spec.triggers` 展开、
   效果的触发器装填、`Pet:getStatusKeys()`、`getActors()`……

4. **`Timing:exec` 加了死循环闸**（`MAX_TRIGGERS_PER_PRIORITY`）。freekill 没有：
   只要 `triggerableTimes` 返回 `math.huge` 而触发者永远满足条件，那里就会死循环。

5. **先记事件流再执行**（不是执行完再记）。执行时会嵌套触发，等返回再记的话嵌套事件
   会排到父事件前面——事件流是拿来回放的，顺序必须等于发生顺序。

6. **退栈按身份，不按位置。** freekill 用 `stack:pop()`（假定"我在栈顶"）。
   但清场事件跑 `clear()` 时可能又插进来一串新事件，那时栈顶已经不是它了，
   于是它永远留在栈上（表现是"每轮 resume 一个死协程"）。改成 `stack:remove(自己)`。

7. **创建事件一律显式传 room。** freekill 用全局 `RoomInstance`。本项目单测里同时存在
   好几个战局，靠"当前战局"猜会让事件挂到**别人的**栈上，表现是"这件事像没跑一样，
   然后调度器原地打转"。所以统一写 `X:create(data, logic.room)`，并且 `pushEvent` 里钉了
   不变式断言：忘了传就立刻报错。

8. **没有移植 `Phase`（回合内阶段）。** 三国杀一个角色的回合里分判定/摸牌/出牌/弃牌，
   赛尔号没有这套结构（一个回合 = 双方各行动一次）。硬套一个 Phase 只会发明出游戏里
   不存在的概念，所以行动内部直接写在 Turn 的三个阶段（prepare/main/clear）里。

9. **`breakEvent` 的参数会被记下来**（`exec_ret`）。freekill 在这一支里把那个值丢掉了，
   于是 `breakEvent(false)` 的参数纯属写着好看。

10. **管理器循环有出口和上限**：栈空了就正常返回；循环轮数超过上限就明确报错停下，
    而不是把进程卡死。

---

## 6. 现在**没有**做什么（别以为已经能用了）

诚实清单：

- **对面还不是 C++**：RPC 层本身（JSON-RPC + stdio + 请求/通知 + 挂起恢复）已经能用，
  `make example-rpc` 就是"两个真进程 + 真管道"跑完一整局；缺的只是**把对面换成
  C++ 的 RoomThread**（架构文档 §10 的项目 6）。所以要接 C++ 时，Lua 侧基本不用动：
  照 `dispatchers.lua` 调方法、照 `peer.lua` 处理信号即可。
- **一条消息一行（NDJSON）**：`stdio.lua` 用的是"一行一条"，架构文档 §5.1 写的是
  长度前缀。两种都能用；要换的话只改 `stdio.lua`（CBOR 模式天然是自定界的）。
- **`Pet` 刻意只装战斗要用的东西**：进化链、稀有度、捕获率、性别比例、可学技能表、
  经验曲线与升级、存档序列化**都没做**（技能栏里"配招"也只有 4 个槽 + 第五技能，
  没有技能机/遗传之类）。那些是养成/图鉴/持久化的事，属于架构文档 §7
  里"C++ 管"的那一半。战斗只需要"这只精灵现在长什么样"，不需要"它将来会变成什么样"。
- **回合状态机只是"能用"的程度**：`Round`/`Turn` 已经能跑完整局（先制度 → 速度 → 座位
  排序出手），但赛尔号真实的回合里还有换精灵、用道具、逃跑，出手顺序也涉及"双方同时
  决定 + 中途换人"等细节。这些属于项目 7。
- **对手 AI 没有**：无头模式只会"挑一个能用的攻击技"。`request_hook` 是留给它的接口。
- **占位数据，必须按图鉴替换**：`Element.MULTIPLIERS`（属性克制）、
  `Mark.defs` 里的异常状态数值（麻痹 25%、中毒 1/8、烧伤 1/16 都带 TODO）、
  `Pet.natures`（性格名）、`specs/demo.lua`（种族值/威力）。
  属性克制表我有意写得短——写错一半的克制表比没有更害人。
- **伤害公式的系数**（`Damage.STAB/CRIT_MULTIPLIER/RANDOM_MIN`）形式是通行做法，
  具体数值需要和实际结算核对；核对之后只改常量，不用碰调用方。
- **"降低对方最大体力"没做**（官方「灭生啸」是"降低对方 10 点战斗时的最高体力"，
  standard 包里暂时用"附加 10 点固定伤害"近似）。
- **特性（魂印）还没抄**：官方魂印效果是 JS 渲染的，网页抓不到，得手工补；
  standard 包里那两个特性是**占位**（写法是真的，效果是编的）。
- **freekill 的 `LoseHp` / `ChangeMaxHp` 没移植**：赛尔号的规则里没有"体力流失"与
  "伤害"的分野（中毒掉血属于固定伤害），也没有战斗中改体力上限的玩法。真需要时照
  `hp.lua` 的形状加即可——加一个流程事件的代价很低，这就是这套机制的价值。

---

## 7. 怎么继续往下做

按依赖顺序，每一步都不需要动前面的代码：

1. **补图鉴数据**：往 `lua/specs/` 加包，在 `lua/specs/init.lua` 里登记文件路径。
   顺便用真数据把 `Element.MULTIPLIERS`、`Mark.defs` 里的异常状态数值、`Pet.natures` 换掉。
2. **补 RPC 传输**（项目 6）：`entry.lua` 里的 `Rpc.send` 和 `Rpc.run` 是两个唯一的改动点；
   把 `logic.interactive = true` 打开，玩家的选择就从 `logic:resume(...)` 进来。
3. **补完回合状态机**（项目 7）：换精灵、道具、逃跑；`buildTurnOrder` 里加"换人后重排"。
   需要新的阶段就照 `gameflow.lua` 加流程事件。
4. **补时机**：新玩法需要新时机时，在 `server/battle/timing.lua` 里照葫芦画瓢加一个
   数据类 + 时机类，`Seer:registerTiming` 一下，规则作者就能在 spec 里挂上去。
5. **补新的流程事件**：需要"结算到一半停下来插一段"的时候，在 `hp.lua` / `gameflow.lua`
   旁边新建一个文件，`GameEvent:subclass` 之后挂到 `GameEvent.X` 上即可。

写新东西时的两条自查：

- **要随机吗？** 必须从 `logic.rng` 拿，绝不用 `math.random`（否则回放对不上）。
- **遍历了表还产生了顺序吗？** 那就得先排序（否则不同进程可能跑出不同结果）。

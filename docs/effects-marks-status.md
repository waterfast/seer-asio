# 效果 / 印记 / 异常状态：谁是谁，写在哪

> 这份文档回答四个问题（都是写战斗核时真实卡过的地方）：
>
> 1. **effect 到底写在哪里？** —— 注册点在哪、内置的在哪、新效果加在哪；
> 2. 技能上的 effect 和"挂在精灵身上的回合类效果"**是不是同一个东西**？
> 3. 那精灵类上要不要挂一张"身上的回合类效果"的表？谁负责让它每回合动？
> 4. 异常状态（弱化类/控制类）和增益印记怎么共用一套东西？

相关文件：

| 文件 | 装什么 |
| --- | --- |
| `lua/core/effect/init.lua` | `Effect` 类：注册表、目标解析、结算、生命周期 |
| `lua/core/effect/kinds.lua` | **内置效果类型 = 效果注册点**（12 种） |
| `lua/core/mark/init.lua` | `Mark` 基类：注册表、生命周期、被动触发器 |
| `lua/core/mark/status.lua` | **异常状态类**（弱化类 / 控制类）+ 内置 7 种异常状态 |
| `lua/core/mark/buff.lua` | 增益印记类 + 两个通用例子（护盾 / 强化） |
| `lua/specs/standard/effects.lua` | **扩展包怎么加新效果**的样板（4 种）+ 自造测试技 |
| `lua/core/pet.lua` | 精灵身上那两张表：`pet.marks` / `pet.effects` |

---

## 1. 三层结构：技能是"做什么"，效果是"怎么算"，印记是"一直管"

```
   技能（Skill）          玩家点的那一下。管数值：威力/PP/命中/先制度 + 一串效果 spec
      │  effects = { { kind = "mark", mark = "paralysis", probability = 5 } }
      ▼
   效果（Effect）         技能里的每一个"后果"。分两种寿命：
      │                    · 瞬时：当场算完（伤害、回血、能力等级变化）
      │                    · 持续：挂到精灵身上，之后每个时机自己动
      ▼
   印记（Mark）           挂在精灵身上的**状态**：有名字、有描述、有回合数、
      │                    能被"解除异常状态"挑出来、要显示给玩家
      ├── 异常状态（StatusMark）
      │     ├── 弱化类（WeakenStatus）：中毒 / 烧伤 / 冻伤
      │     └── 控制类（ControlStatus）：麻痹 / 睡眠 / 冰冻 / 害怕
      └── 增益印记（BuffMark）：护盾 / 强化 / …
```

一句话概括分工：**技能负责"挂"，印记负责"之后一直管"，效果是两者共用的那块积木。**

举例——「雷祭：100% 令对手麻痹，命中 50%」：

```lua
{ name = "雷祭", category = Skill.Status, pp = 30, accuracy = 50, target = "enemy",
  effects = { { kind = "mark", mark = "paralysis", probability = 100 } } }
```

- `kind = "mark"` 是一个**效果类型**（`Effect.kinds.mark`）：它是瞬时的，做的事就一件——
  调 `logic:applyMark{...}`；
- `paralysis` 是一个**印记定义**（`Mark.defs.paralysis`）：名字、描述、类型、
  "行动前有 25% 概率动不了"（`block_chance`）、"速度减半"（`stat_multipliers`）；
- 所有会造成麻痹的技能（电击光束/放电/电闪雷鸣/瞬雷天闪/极地千鸟/雷祭……）
  都只是同一行 `{ kind = "mark", mark = "paralysis" }`，**没有一段重复代码**。

---

## 2. effect 写在哪里？——三个注册点

效果类型不是继承出来的，是**注册**出来的。`Effect.registerKind(key, def)`（`lua/core/effect/kinds.lua` 里定义了 12 次，就是这个制度的全部用法）。三个地方能注册：

### 2.1 核心内置：`lua/core/effect/kinds.lua`

通用到"任何精灵身上都成立"的效果放这里。每一条就是一张说明书：

```lua
Effect.registerKind("add_damage", {
  name = "附加固定伤害",
  instant = true,                            -- 当场结算
  validate = function(spec)                  -- 数据合法性：加载期就报笔误
    if type(spec.value) ~= "number" or spec.value <= 0 then
      return false, "add_damage 需要一个正的 value（附加多少点固定伤害）"
    end
    return true
  end,
  on_apply = function(effect, pet, ctx)      -- 结算体
    effect.logic:damage{ target = pet, fixed = effect.value,
                         reason = effect.name, is_status_damage = true }
  end,
})
```

现在内置的 12 种（`Effect.kinds_builtin` 就是这份目录，测试会校验它对得上）：

| kind | 对应官方效果 | 寿命 |
| --- | --- | --- |
| `damage` | 固定伤害 | 瞬时 |
| `heal` | 43 恢复（固定值 / 按最大体力比例） | 瞬时 |
| `stat` | 4 强化 / 5 弱化（改能力等级） | 瞬时 |
| `drain` | 吸取（按这次造成的伤害回血） | 瞬时 |
| `recoil` | 反作用力 | 瞬时 |
| `cure` | 解除异常状态 | 瞬时 |
| `mark` / `status` | 10 施加异常 / 挂任意印记（`status` 是 `mark` 的别名） | 瞬时（挂完就走） |
| `clear_stages` | 33 消强 / 3 解弱 | 瞬时 |
| `add_damage` | 29 / 38 / 60 附加伤害 | 瞬时 |
| `power_modifier` | 37 / 42 / 88 增伤（`phase = "before"`，在伤害算出来之前改威力） | 瞬时 |
| `modifier` | 任意时机的数值修正（"3 回合内受伤减半"） | **持续** |

### 2.2 扩展包自造：`lua/specs/<包名>/effects.lua`

具体玩法自己造的效果写在自己包里，**一行核心代码都不用改**。`lua/specs/standard/effects.lua` 就是样板，它注册了 4 种：

```lua
return {
  name = "standard",
  effects = {
    { key = "seal_skill",
      def = {
        name = "封招", instant = false,          -- 持续型：挂到对手身上
        validate = function(spec) ... end,
        on_apply = function(effect, pet, ctx)    -- 挂上去那一刻：封住某个技能
          pet:sealSkill(effect.extra.skill or pick_strongest(pet))
        end,
        on_expire = function(effect)             -- 到期/被清除：解封
          effect.target_pet:unsealSkill(effect.sealed_skill)
        end,
      } },
    ...
  },
  skills = { { name = "试作·封印之雷", effects = { { kind = "seal_skill", duration = 2 } } } },
}
```

| 包内新效果 | 干什么 | 顺带演示了什么 |
| --- | --- | --- |
| `steal_stages` | 偷取对手能力提升状态（对方归零、自己拿到） | "消强"只差一个受益者参数，就该单独一个 kind |
| `hp_ratio_damage` | 按最大体力比例造成固定伤害 | 固定伤害要走 `is_status_damage`（不吃克制/暴击/本系） |
| `seal_skill` | N 回合内无法使用某个技能 | **持续型效果** + 与 `Skill:checkUsable` 的封印联动 |
| `endure` | 抵挡致死伤害，保留 1 点体力 | **持续型的被动钩子**写法（挂 `DetermineDamage`，用完即走） |

### 2.3 运行期临时注册：`Seer:registerEffectKind`

规则/模式代码在开局时现场加一种也可以（测试里就这么干）：

```lua
S.Seer:registerEffectKind("测试_喊话", { name = "喊话", instant = true,
  on_apply = function(effect, pet, ctx) effect.logic:notify{ type = "Shout", text = effect.value } end })
-- 之后 { kind = "测试_喊话", value = "你好" } 就能用了
```

没注册的类型**当场报错**（`Effect 的类型 "xxx" 没有注册，请先用 Effect.registerKind 注册`），
而不是静默不生效——数据写错能立刻发现，这是刻意的。

> **"效果"和"效果类型"是两件事**：`Effect.kinds` 里的是**类型**（说明书，全局一份、加载期注册）；
> 技能 spec 里 `{ kind = ..., ... }` 是**数据**；运行时 `Effect:new(spec)` 造出来的是**实例**
> （挂在谁身上、还剩几回合、叠了几层）。三者职责不要混。

---

## 3. 技能上的 effect 与"身上的回合类 effect"：**同一个类，两种寿命**

**结论：是同一个 `Effect` 类。** 没有任何"技能效果类"和"状态效果类"之分，区别只有一个字段：
`duration`（配合 `kind_def.instant`）。

```lua
-- 写法完全一样，只是后者多了 duration
{ kind = "stat",  stages = { sp_attack = 2 } }                      -- 瞬时：+2 特攻，算完就完了
{ kind = "modifier", duration = 3, extra = { timing = "DetermineDamage", apply = ... } }
                                                                    -- 持续：挂身上 3 回合
```

`Effect:apply()` 里的分岔（`lua/core/effect/init.lua`）：

```lua
local exist = pet:getEffect(self.name)
if exist then exist:addStack()                    -- 同名重复挂 = 叠层
else
  if def.on_apply then def.on_apply(self, pet, ctx) end
  if not def.instant then
    self:install()                                -- 把 kind 的时机钩子装成触发器
    pet:addEffect(self)                           -- 写进"身上的效果"那张表
  end
end
```

| | 瞬时效果 | 持续效果（身上的回合类效果） |
| --- | --- | --- |
| `kind_def.instant` | `true` | 不写 / `false` |
| 需要 `duration` | 不需要 | 需要（或永续，由别的逻辑清除） |
| 进 `pet.effects` 表 | 不进 | 进 |
| 注册时机钩子 | 不注册 | `install()` 装成 `EffectTrigger` |
| 谁让它每回合动 | —— | `logic:tickDurations()` → `effect:tick()` |
| 怎么结束 | 当场结束 | 回合数到 0（`remove("duration")`）/ `clearEffects` / `on_expire` |

一句话：**技能效果和回合类效果是同一种积木，只是"装上去之后留不留着"不同。**

### 3.1 那为什么精灵身上是**两张**表？

```lua
pet.marks    -- key  → Mark    ：印记/异常状态。有名字、有描述、能被解毒、要显示给玩家
pet.effects  -- name → Effect  ：效果。纯机制，不进状态栏
```

看起来可以合成一张表（都是"挂在精灵身上、有回合数的东西"），但语义不一样：

- **印记是状态**："你现在中毒了" —— 玩家要看见、UI 要列出来、`logic:cureStatus` 要能精确地
  挑出"异常状态"这一类（只清弱化类/控制类，**不能顺手把护盾也拆了**）；
- **效果是机制**："这 3 回合你受到的伤害减半""被攻击时反击"—— 它不该出现在状态栏里，
  也不是"能被治好的病"。

所以分成两张表、各有一个类，但**共享同一套底层机制**：`OwnedTrigger.installTable`
（把时机钩子装成触发器）、`pet:recalcStats()`（持续倍率算进字段）、
`logic:tickDurations()`（回合末递减）三处都是两边共用的。

---

## 4. 精灵身上要不要挂一张"回合类效果"的表？——**已经挂了**

`Pet` 初始化时就摆好了两张表，配套的 API 也是齐的：

```lua
-- 印记（Mark）
pet:addMark / getMark / hasMark / hasStatus / getStatusKeys / getMarks
pet:removeMark / clearMarks

-- 效果（Effect）
pet:addEffect / getEffect / hasEffect / getEffects / getEffectsByKind
pet:removeEffect / removeEffectsByKind / clearEffects / countEffects
```

三条实现上的约定（都是踩过坑才写下的）：

1. **遍历一律走 `getEffects()` / `getMarks()`**，它们按名字排序返回**数组**；
   直接 `pairs(pet.effects)` 会让顺序取决于哈希，同一局回放就可能出现两种结果
   （架构文档 §2.3 的确定性要求）。
2. **只有 `logic` 能改动它们**：挂/摘都要走 `logic:applyMark` / `logic:removeMark`
   （要过 `BeforeMarkApply` 时机、要发通知、要处理叠层），
   效果则是 `logic:applyEffect`。原因和"体力只能从 `ChangeHp` 改"一样——
   **唯一入口才能保证时机、通知、清理不会漏**。
3. **生命周期只有一条路径**，四种结束方式最终都走同一个函数：

```
挂上：  Effect:apply → pet:addEffect       Mark:attach  → pet.marks[key] = mark
每回合：logic:tickDurations() → effect:tick() / mark:tick()
到期：  Effect:remove(reason)              logic:removeMark(pet, key, reason)
        └─ on_expire → uninstall(摘触发器) → pet:removeEffect
倒下/下场：Pet:clearEffects() / clearMarks()
```

效果和印记都会在 `remove` / `detach` 里把自己装的触发器摘干净——**不留孤儿触发器**
是这套设计最容易出错的地方（忘了摘，精灵已经死了技能还在触发）。

---

## 5. 印记类怎么写的：一个基类 + 两个类别子类

```
Mark              管"挂在谁身上、还剩几回合、有哪些被动钩子、怎么叠层、怎么序列化"
├── StatusMark    异常状态基类：isStatus() = true，类型只能是弱化类/控制类
│   ├── WeakenStatus   弱化类：默认行为由数据派生
│   │                  turn_end_damage = {1,8}   → 回合末掉最大体力的 1/8
│   │                  weaken_attack = {physical = 0.5} → 自己打出的物理伤害 ×0.5
│   └── ControlStatus  控制类：默认行为由数据派生
│                      block_chance = 25 → 每次行动 25% 被掐掉（不写 = 100%）
└── BuffMark      增益印记：stat_multipliers / triggers / effects 自己写
```

为什么要有子类，而不只是"一张表 + 一堆触发器"？因为不加子类的话，
**每加一个状态都要把同一段钩子抄一遍**：

```lua
-- 没有子类时的写法（每个状态都要抄一遍）
register("poison",  { ..., triggers = { [RoundEnd] = { on_trigger = 按1/8掉血 } } })
register("burn",    { ..., triggers = { [RoundEnd] = { on_trigger = 按1/16掉血 },
                                        [DetermineDamage] = { on_trigger = 物理减半 } } })
register("frostbite", { ..., triggers = { [RoundEnd] = { on_trigger = 按1/16掉血 } } })  -- 又抄一遍

-- 有子类之后：只写数据，钩子由 WeakenStatus.defaultTriggers 生成
Status.register("poison",    { name = "中毒",   class = "weaken", turn_end_damage = { 1, 8 } })
Status.register("burn",      { name = "烧伤",   class = "weaken", turn_end_damage = { 1, 16 },
                                 weaken_attack = { [Skill.Physical] = 0.5 } })
Status.register("frostbite", { name = "冻伤",   class = "weaken", turn_end_damage = { 1, 16 } })
```

"写好一点"具体体现在这几个地方：

1. **枚举**：`Status.KEY = { PARALYSIS = "paralysis", POISON = "poison", ... }`、
   `Status.KEY_NAME`（中文名）。代码里不散字符串字面量，加状态时先在枚举里登记。
2. **类别默认行为**：`WeakenStatus.defaultTriggers(def)` / `ControlStatus.defaultTriggers(def)`
   把"这类状态怎么动"变成从**数据**派生；作者自己写 `triggers` 时**优先**（可以覆盖默认）。
3. **可单测的查询方法**：`mark:getTurnEndDamage()`、`mark:getAttackMultiplier(category)`、
   `mark:getBlockChance()`、`mark:rollsActionBlock(logic)`——
   不跑一整局就能验证"中毒掉多少血、烧伤物理减半、麻痹几成概率动不了"。
4. **`on_attach` / `on_detach`**：有些印记挂上去要做**触发器之外**的事
   （封招要封、光环要改数值），摘掉时要撤销。这两钩子让"挂载动作"也有正式位置，
   而不用硬塞进 `effects`（那是"挂上那一刻结算一次的效果"）。
5. **实例私有数据 `mark.extra`**："封住的是哪个技能"这种参数不可能写死在定义里，
   所以 `logic:applyMark{ mark = ..., extra = { skill = "气力" } }` 可以带进实例。
6. **注册分派**：`Mark.register(key, def)` 看 `mark_type` 自动转给
   `Status.register` / `Buff.register`，所以扩展包只写 `mark_type = "weaken"` 也能拿到
   类别默认行为，不必知道有子类这回事。
7. **枚举化的实例类**：`Mark.classOf(key)` 决定用哪个子类，`logic:applyMark` 用它造实例——
   于是 `mark:getTurnEndDamage()` 这种类别方法永远在。

### 5.1 一个状态的完整链路（拿"封招"当例子，它把三条线串起来了）

```
技能「试作·封印之雷」 { effects = { { kind = "seal_skill", duration = 2 } } }
   │ ① 选技能：Skill:checkUsable —— 走 PP / 封印 / usable 三个来源
   │ ② 用技能：GameEvent.UseSkill → 命中判定 → 效果结算（before / after 两段）
   ▼
效果 seal_skill（instant = false）
   │ on_apply：挑出对手威力最高的技能（确定性排序）→ pet:sealSkill(name)
   │ 同时 pet:addEffect(self) 写进"身上的效果"表 + install 触发器
   ▼
对手那边：Skill:checkUsable(...) → false, "sealed", "技能被封印"
   │ 于是 prompt 的候选列表里没有它、unusable 列表里有它（客户端显示成灰的）
   ▼
两个大回合后：logic:tickDurations() → effect.remaining = 0 → Effect:remove("duration")
   └─ on_expire：pet:unsealSkill(name) → 又能用了
```

注意 ③ 那一步**没有一行新代码**：可用性判断只有 `Skill:checkUsable` 一份实现，
封招只是改了精灵身上的 `sealed_skills`，所以"列候选"和"真使用"自动一致。

---

## 6. 加东西之前先看这张表

| 我想加… | 改哪里 | 大概写多少 |
| --- | --- | --- |
| 一个新技能 | `lua/specs/<包>/skills.lua` 加一张表 | 5~10 行 |
| 一种新的**异常状态**（弱化类） | `Status.register(key, { class = "weaken", turn_end_damage = {1,8} })` | 5 行 |
| 一种新的**异常状态**（控制类） | `Status.register(key, { class = "control", block_chance = 30 })` | 5 行 |
| 一个**增益印记** | `Mark.register(key, { mark_type = "buff", duration = 3, triggers = {...} })`（包内 `spec.marks`） | 5~15 行 |
| 一种新的**效果类型** | 包内 `effects = { { key = ..., def = {...} } }`（核心是 `lua/core/effect/kinds.lua`） | 10~25 行 |
| 一种新的**挂在身上的回合类效果** | 同上，但 `instant = false` + `duration` + `triggers` / `on_expire` | 15~30 行 |
| 一条新的**时机**（"XX 时"） | `lua/server/battle/timing.lua`：`Seer:registerTiming(...)` + 在流程里 `logic:trigger(...)` | 10 行 + 一处调用 |

判据（什么时候用哪个）：

- 它会**显示在状态栏**、能被"解除异常状态"清掉 → **印记**（弱化类/控制类 → 异常状态）；
- 它只是**机制**（改数值、反击、抵挡、封招）→ **持续效果**，不进状态栏；
- 它**当场算完**（打伤害、回血、改能力等级）→ **瞬时效果**；
- 它能被**很多技能共用、只差参数** → 做成一个 **kind + 参数**（这就是"复用"的落点）。

---

## 7. 还没做 / 边界（免得到时候找不到）

- **场地 / 天气**：同一个"定义 + 触发器"机制，但宿主不是精灵而是**战局**（`logic`）。
  `Mark:attach(logic, pet)` 里的 `pet` 位置换成 logic 就是雏形，尚未实现。
- **属性免疫**：官方有"电系免疫麻痹"这类；应该在 `logic:applyMark` 的
  `BeforeMarkApply` 时机里加，不在印记里加（印记不该知道自己会被谁免疫）。
- **命中率 / 必中** 与异常状态的相互作用（"命中后 X% 附加"已有 `probability`，
  但"打空了不加"是流程保证的，没有单独的"命中时"钩子）。
- **最大体力变化**（"降低对方 10 点最大体力"）：`max_hp` 目前是算出来的字段，
  没有"基础值 + 修正"的分层，所以标准包里用固定伤害近似，标了 TODO。
- **PP 相关效果**（吸取 PP、封印 PP）：`SkillSet` 有 `usePP/restorePP`，
  但没有对应 kind。
- **叠层策略**：目前"同名效果叠层、不同名各自一份"，印记按 `max_stacks`。
  官方有些状态是"刷新回合而不是叠层"，需要时改 `Mark:addStack` 的分支即可。
- **异常状态数值**：麻痹 25%、中毒 1/8、烧伤 1/16 这些是从 WIKI 描述推的，
  **还没和实机逐项核对**（代码里带 TODO 的地方就是这些）。

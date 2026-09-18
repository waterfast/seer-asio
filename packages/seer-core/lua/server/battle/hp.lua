-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 生命值相关的流程事件 ============================
--
-- 本文件是 freekill-core `ltk/server/events/hp.lua` 的移植版。它回答一个问题：
-- **"掉血"这件事，是由哪几步走完的？**
--
-- freekill 把"体力变化"拆成了三层，这个拆法很值得学：
--
--   1. `Damage`（伤害）—— 一次伤害结算的完整流程：先让一堆时机改数值，
--      再落账。它**不直接改 hp**，只负责"算出该掉多少"。
--   2. `ChangeHp`（体力变化）—— **唯一**真正改 `hp` 的地方。
--      掉血、回血、固定伤害全都汇到它这里，所以"体力变化"类的事件/日志/广播
--      只需要写一遍。这也让"防止体力变化"这种效果只在一个地方就能拦住。
--   3. `Recover`（回复）—— 回复有它自己的提前量（回多少、上限截断），
--      所以单独一个流程事件，最后同样落到 ChangeHp。
--
-- 为什么非要拆成"流程事件"而不是几个函数？因为每一步之间要**插时机**，
-- 而且插入的时机有可能**打断**后面的步骤（伤害被防止 → 后面不用算了），
-- 还可能**嵌套**（回合末中毒掉血，是在"回合结束"这个流程事件里又跑了一条
-- 完整的伤害流程）。普通函数调用表达不了"插进去、走完再回来、还可能被砍掉"。
--
-- ---------------------------- 和 freekill 的差异 ----------------------------
--
--   * freekill 还有 `LoseHp`（体力流失，独立于伤害）和 `ChangeMaxHp`（体力上限）。
--     本项目先不做：赛尔号的规则里没有"体力流失"与"伤害"的分野（中毒掉血属于
--     固定伤害），也没有战斗中改体力上限的玩法。真需要时照本文件的形状加即可——
--     加一个流程事件的代价很低，这就是这套机制的价值。
--   * 伤害链上的时机一律以**受击方**为受动者（freekill 是"造成"阶段给攻击方、
--     "受到"阶段给受击方）。简化成一种更好记：攻击方想插一脚就写 `can_trigger`
--     或在效果里判断 `data.source`（烧伤减半就是这么写的）。
--   * 受击方倒下之后的"濒死求桃"流程，freekill 在 `death.lua` 里；
--     赛尔号是直接倒下，所以这里就地处理（见 `ChangeHp:main` 末尾）。

--- 体力变化的数据对象（数据类定义在 server/battle/timing.lua）
---@see HpChangedData

---@class GameEvent.ChangeHp: GameEvent
---@field public data HpChangedData
local ChangeHp = GameEvent:subclass("GameEvent.ChangeHp")

function ChangeHp:__tostring()
  return ("<ChangeHp %+d : %s #%d>"):format(self.data.num or 0, tostring(self.data.who), self.id)
end

--- 真正改 hp 的地方。**所有**掉血/回血都要经过这里。
function ChangeHp:main()
  local data = self.data
  local logic = self.room.logic
  local pet = data.who

  if data.num == nil or data.num == 0 then return false end
  if pet == nil then return false end

  -- 1) 让"体力变化前"的时机插一脚（护盾、免疫、改成别的数值都在这里）
  logic:trigger(SeerTiming.BeforeHpChanged, pet, data)
  if data.num == 0 then
    data.prevented = true
  end
  if data.prevented then
    logic:breakEvent(false)
  end

  -- 2) 落账。
  --    用 Pet:takeDamage / Pet:heal 这两个"裸操作"：截断（不超上限、不为负）
  --    和"倒地标记"都归它们管，这里不再重复一遍。
  --    换句话说：**裸操作只该被这一处调用**，别的地方直接改 hp 就是绕过
  --    整套事件系统（那样"防止体力变化"就拦不住了）。
  local before = pet.hp
  if data.num > 0 then
    pet:heal(data.num)
  else
    pet:takeDamage(-data.num)
  end
  -- 记**带符号**的真实变化量（和 data.num 同号）：掉血是负的。
  -- 用"变化前后相减"而不是取 heal/takeDamage 的返回值，是因为那两个返回的是
  -- 无符号的"变化了多少"，回血和掉血看起来一样，容易写出方向搞反的 bug。
  local actual = pet.hp - before
  data.actual = actual
  if actual == 0 and data.num ~= 0 then
    -- 一点都没变（满血回血 / 空血掉血）＝这次体力变化没有意义
    data.prevented = true
    logic:breakEvent(false)
  end

  -- 掉血的话，先把"这一下打了多少"告诉外面，**再**报体力变化、**再**判倒下。
  --
  -- 顺序为什么重要：客户端收到"受到 138 伤害"之后紧接着要把血条掉下去，
  -- 如果先报"体力变了"甚至先报"倒下了"，玩家会先看到人躺下、后看到伤害数字。
  -- 报的是**实际掉的血**（可能被上限截断/被护盾吃掉），不是"打算打多少"。
  -- （freekill 也是把伤害日志放在 ChangeHp 里发的，理由相同。）
  if data.kind == "damage" and data.damage_event ~= nil then
    local d = data.damage_event
    logic:notify{
      type = "Damage",
      source = d.source and d.source.seat or nil,
      target = pet.seat,
      damage = -actual,
      crit = d.crit or false,
      stab = d.stab or false,
      effectiveness = d.effectiveness or 1,
      element = d.element,
      reason = d.reason,
    }
  end

  logic:notify{
    type = "HpChanged",
    pet = pet.seat,
    name = pet.name,
    num = actual,
    hp = pet.hp,
    max_hp = pet.max_hp,
    reason = data.reason,
  }

  -- 3) "体力变化后"的时机（吸血、联动掉血之类）
  logic:trigger(SeerTiming.HpChanged, pet, data)

  -- 4) 掉了血又见底了 → 倒下流程。
  --    放在这里而不是放在伤害事件里：这样回血、固定伤害、任何来源的掉血
  --    都只有一条"倒下"路径（不可能出现某种伤害忘了判倒下）。
  if pet.hp < 1 and data.num < 0 and not data.prevent_dying then
    logic:onFaint(pet, data.source)
  end

  return true
end

---@class GameEvent.Damage: GameEvent
---@field public data DamageData
local Damage = GameEvent:subclass("GameEvent.Damage")

function Damage:__tostring()
  return ("<Damage %d %s -> %s #%d>"):format(
    self.data.damage or 0, tostring(self.data.source), tostring(self.data.target), self.id)
end

--- 一次伤害结算的流程。
--- 对照 freekill 的 `Damage:main`——那里的 `stages` 表就是"这条链有几步"的写法。
function Damage:main()
  local data = self.data
  local logic = self.room.logic
  local target = data.target

  if target == nil then return false end
  if data.damage < 1 then return false end
  if target:isFainted() then return false end

  -- 攻击方已经倒下了就不再结算（防止"临死反扑"式的规则漏洞）
  if data.source and data.source:isFainted() then
    data.source = nil
  end

  -- ---------- 第一阶段：改数值 ----------
  -- 顺序就是规则的一部分：先"防止"，再"定数值"。
  -- 每个阶段之后都检查一次"这次伤害是不是没了"，没了就整条链掐掉。
  local stages = {
    { SeerTiming.PreDamage, "伤害开始算（可以在这里防止伤害）" },
    { SeerTiming.DetermineDamage, "伤害数值定下来了（减半/加成/改成固定伤害）" },
  }

  for _, stage in ipairs(stages) do
    logic:trigger(stage[1], target, data)
    if data.damage < 1 then
      data.prevented = true
    end
    if data.prevented then
      logic:notify{
        type = "DamagePrevented",
        target = target.seat,
        reason = data.reason,
        amount = data.damage,
      }
      -- 打断：主循环会把本事件的协程直接 close 掉，后面的步骤和 exit 都不再执行。
      -- 所以"伤害被防止了就不该触发反伤/静电"这件事是**结构性**保证的，
      -- 不靠每个效果自己记得判断。
      logic:breakEvent(false)
    end
  end

  -- ---------- 第二阶段：落账 ----------
  -- 伤害本身不改 hp，交给 ChangeHp；这样"体力变化"只有一个入口。
  -- "打了多少""体力变了多少""倒下了"三件事也都在 ChangeHp 里按顺序通知，
  -- 所以这里只要看它成没成。
  local ok = logic:changeHp(target, -data.damage, "damage", data.reason, data)
  if not ok then
    -- 体力变化被拦住了（护盾/免疫之类）：伤害流程也到此为止
    logic:breakEvent(false)
  end
  if target:isFainted() and data.damage >= target.max_hp then
    -- 打死了也会走 ChangeHp → onFaint，这里不用重复处理
  end

  -- ---------- 第三阶段：事后 ----------
  logic:trigger(SeerTiming.Damage, target, data)
  logic:trigger(SeerTiming.Damaged, target, data)

  return true
end

--- 收尾：整条伤害链结束。
--- 对照 freekill：`Damage:exit` 里触发 `fk.DamageFinished`，
--- 还会处理铁索连环的传导伤害（赛尔号没有这个概念，所以这里只有结算完这一件事）。
function Damage:exit()
  local data = self.data
  local logic = self.room.logic
  if data.target == nil then return end
  logic:trigger(SeerTiming.DamageFinished, data.target, data)
end

function Damage:desc()
  return {
    type = "#Damage",
    event = self.class.name,
    target = self.data.target and self.data.target.seat or nil,
    source = self.data.source and self.data.source.seat or nil,
    damage = self.data.damage,
    reason = self.data.reason,
  }
end

---@class GameEvent.Recover: GameEvent
---@field public data RecoverData
local Recover = GameEvent:subclass("GameEvent.Recover")

function Recover:__tostring()
  return ("<Recover %+d : %s #%d>"):format(self.data.num or 0, tostring(self.data.target), self.id)
end

--- 已经满血就不用跑了（对照 freekill `Recover:prepare`：满了直接跳过整个事件）
function Recover:prepare()
  local pet = self.data.target
  if pet == nil then return true end
  if pet:isFainted() then return true end
  if pet.hp >= pet.max_hp then return true end
  return nil
end

function Recover:main()
  local data = self.data
  local logic = self.room.logic
  local pet = data.target

  logic:trigger(SeerTiming.BeforeRecover, pet, data)

  -- 回复要按剩余体力截断：不回超过上限，也不回成负数
  data.num = math.min(data.num or 0, pet.max_hp - pet.hp)
  if data.num < 1 then
    data.prevented = true
  end
  if data.prevented then
    logic:breakEvent(false)
  end

  logic:changeHp(pet, data.num, "recover", data.reason)

  logic:trigger(SeerTiming.Recover, pet, data)
  return true
end

GameEvent.ChangeHp = ChangeHp
GameEvent.Damage = Damage
GameEvent.Recover = Recover

return { ChangeHp = ChangeHp, Damage = Damage, Recover = Recover }

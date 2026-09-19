-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 游戏对象（GameObject）============================
--
-- 战斗中最基础的"东西"的基类：精灵（Pet）、道具、场地物件……都从它派生。
-- 它只回答两个问题：
--
--   1. 我是谁 —— id（一局战斗里唯一的标识符）
--   2. 我叫什么 —— name（显示名 / 日志名）
--
-- 为什么要单独抽出这一层：事件系统（时机 / 流程事件）里的 `target`、`source`
-- 这类"参与者"字段不该写死成某一种具体类型——伤害的来源可能是精灵，也可能是
-- 道具、天气，甚至"无来源"（固定伤害）。把它们统一标成 GameObject，事件层就
-- 不用为每一种来源各写一套类型。
--
-- 现在（重构初期）先只有 id / name 两项，等道具、场地物件落地时再往这里加
-- 它们的公共部分（比如 `owner`：属于哪一方）。
--
-- 注意：当前 Pet 还没改继承关系，暂时各自独立；下一步让 Pet 继承 GameObject 时，
-- 把 Pet 里重复的 id/name 逻辑并到这里来即可。

---@class GameObject: Object
---@field public id integer @ 一局战斗内唯一的标识符
---@field public name string @ 对象名称（精灵名 / 道具名）
GameObject = class("GameObject")

---@class GameObjectSpec
---@field public id integer @ 一局战斗内唯一的标识符
---@field public name string @ 对象名称

---@param spec GameObjectSpec
function GameObject:initialize(spec)
  spec = spec or {}
  self.id = spec.id
  self.name = spec.name
end

---@return integer
function GameObject:getId()
  return self.id
end

---@return string?
function GameObject:getName()
  return self.name
end

function GameObject:__tostring()
  return ("<GameObject #%s %s>"):format(tostring(self.id), tostring(self.name))
end

return GameObject

-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- 扩展包清单。
--
-- 这里**手写**一份文件名数组，而不是去列 lua/specs/ 目录，原因有两条：
--   1. 不依赖 lfs / io.popen，换成 Windows 或者精简版 Lua 也能跑；
--   2. 数组的顺序就是加载顺序，而加载顺序决定了注册顺序。
--      注册顺序确定，出问题时才能复现。
--
-- 加新包 = 在 lua/specs/ 下写一个 return 表的 .lua 文件，再把路径加到这里。
--
-- ---------------------------- 重构后的清单 ----------------------------
--
-- 原来这里列了四个文件（demo / effects / skills / species），重构后只剩两个：
--
--   * `demo.lua`     —— **已删除**。它整份是"旧框架用法样板"：效果类型（kind）、
--                       特性挂在旧时机上、`pet:getHpRatio()` 之类的旧 Pet API，
--                       没有一行能直接改成新 API（它演示的东西本身还没重建）。
--   * `effects.lua`  —— **已删除**。里面是"包内自定义效果类型"的实现代码
--                       （`effect.logic`、`pet:getStatStage/setStatStage`、
--                       `pet:sealSkill`、`pet:getAllSkills`），全是被删掉的 API；
--                       等效果系统重建后再按新写法重写一份。
--
-- 留下的是**纯数据**那两个，它们直接吃新 API：
--   skills.lua  —— 雷伊 / 盖亚的真实技能表（37 条），走 `Seer:createSkill`
--   species.lua —— 种族值，走 `Seer:addSpecies`
--   （技能在前、种族在后：种族表以后要按名字引用技能/特性，顺序先定下来。）

return {
  "lua/specs/standard/skills.lua",
  "lua/specs/standard/species.lua",
}

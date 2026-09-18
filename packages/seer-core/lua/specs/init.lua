-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- 扩展包清单。
--
-- 这里**手写**一份文件名数组，而不是去列 lua/specs/ 目录，原因有两条：
--   1. 不依赖 lfs / io.popen，换成 Windows 或者精简版 Lua 也能跑；
--   2. 数组的顺序就是加载顺序，而加载顺序决定了注册顺序。
--      注册顺序确定，出问题时才能复现（架构文档 §2.3）。
--
-- 加新包 = 在 lua/specs/ 下写一个 return 表的 .lua 文件，再把路径加到这里。

return {
  -- demo 是"框架用法"的样板（含各种效果的写法示例）
  "lua/specs/demo.lua",

  -- standard 是**测试用的标准阵容**：雷伊（电系）和盖亚（战斗系）。
  -- 一个包拆成几个文件写（同名会合并），所以：
  --   effects.lua —— 包内注册的新**效果类型** + 用它们的自造测试技
  --   skills.lua  —— 从图鉴抄来的官方技能表与包内印记
  --   species.lua —— 种族值（要靠名字引用技能/特性，所以排在技能之后）
  -- 先效果后技能：技能的 effect spec 在造实例时会校验类型登记过没有。
  "lua/specs/standard/effects.lua",
  "lua/specs/standard/skills.lua",
  "lua/specs/standard/species.lua",
}

# Buff 子系统

- `buff.lua`：单个绑定实例。保存拥有者、来源、效果定义引用、局内状态和持续时间。
- `controller.lua`：`BuffController`，每个房间独立持有一个。负责添加、刷新、查询、消耗、驱散、到期及整局清理。
- `init.lua`：导出 `Buff` 与 `BuffController`，由 `seer.lua` 加载。

规则作者继续使用 `room:addBuff/getBuff/getBuffs/removeBuff/dispelBuffs`。Room 仅转发给 `room.buff_controller`，不实现第二套生命周期。回合结束和战斗结束由 GameLogic 分别调用 Room 的到期/清理入口。

控制器只记录挂载过 Buff 的对象引用，不保存全局效果表。实际绑定在对象的 `buff_instances`；GameLogic 每次 trigger 经由管理器查询，再把当前时机匹配的效果交给 Handler。拥有者注销效果来源后，不再参与触发，但仍由控制器负责到期清理。

Buff 的前后事件定义保留在 `core/events/buff.lua`，由统一事件清单注册。此前未接入的 `core/mark/` 不属于这套实现。本模块的“控制器”指生命周期管理，不包含麻痹、睡眠等控制状态。

完整时序、刷新与取消语义见仓库根目录 `docs/battle-rules.md`。

# 最新精灵技能资料（近期上线精灵 6 只）

- 抓取日期：**2026-09-20**
- 数据版本：SeerAPI 公开数据集 `api-data`，commit **`428b5810`**（仓库自动更新提交于 2026-09-18；本文件抓取 `@HEAD`，即该版本）
- 来源 A（结构化数据）：[SeerAPI/api-data](https://github.com/SeerAPI/api-data)
  - 精灵：`https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/<图鉴ID>/index.json`
  - 技能：`https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/<技能ID>/index.json`
- 来源 B（图鉴原文交叉核对）：biligame 赛尔号 WIKI `action=raw`
  - 精灵页：[精灵:4944 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4944&action=raw)（ID 可替换）
  - 技能页：[技能:38530 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38530&action=raw)（ID 可替换）

## 0. 「最新精灵」的确定方式与四技能判定

### 0.1 如何挑选「近期更新」的 6 只

biligame「精灵图鉴」列表页在本次抓取期间被站点限流拦截，因此改用可核验的客观口径：

1. 取 SeerAPI `pet/index.json` 中**图鉴 ID 最大**的若干只（最新精灵编号递增）；
2. 用 `api-data` 仓库的逐文件提交历史（`GET /repos/SeerAPI/api-data/commits?path=data/v1/data/pet/<ID>/index.json`）确认**每只精灵数据首次进入数据集的时间**，作为「近期上线」的代理指标。

结果（按首次入库时间倒序）：

| 顺位 | 图鉴ID | 名称 | 属性 | 种族值总和 | api-data 首次入库日期 |
| --- | --- | --- | --- | --- | --- |
| 1 | 4944 | 克律莎 | 远古 电 | 715 | 2026-09-18 |
| 2 | 4943 | 瑞特拉尼 | 地面 | 735 | 2026-09-18 |
| 3 | 4942 | 极度冰凌·阿克希亚 | 冰 | 750 | 2026-09-11 |
| 4 | 4941 | 瑞丁 | 飞行 暗影 | 700 | 2026-09-04 |
| 5 | 4940 | 王座守卫·古亚尼斯 | 圣灵 电 | 740 | 2026-09-04 |
| 6 | 4939 | 决囚钢骨 | 机械 次元 | 720 | 2026-09-04 |

> 未核实：图鉴「精灵图鉴」页面是否有官方「近期更新」标记，以及 4944/4943 等在游戏内的正式上线日期（只核实到数据集入库日期）。

### 0.2 四技能判定依据

这批新精灵的图鉴 `技能=` 采用了完整格式 `技能ID-学习等级-分类-标记`，分类字段直接标出四格技能：

- `先手` → 先手/低耗技能
- `防御` → 防御技能
- `强化` → 强化技能
- `制敌` → 制敌/大招技能
- `第五` → 第五技能（独立一格）

例：克律莎的原始串 `10008-1;…;38530-21-先手-1;20521-25;…;29451-49-防御-1;23032-53;29452-57-强化-1;38531-61-制敌-1;38532-76-第五`。

因此本文把「最后学会的四个技能」记为：**图鉴四格标记技能（先手 / 防御 / 强化 / 制敌）**，第五技能单列。注意这些标记技能不一定在学习等级最高的位置（例如克律莎的先手技能在 21 级、瑞丁的先手技能在 21 级），与「按等级取最高的 4 个」并不等价；为便于复核，§每只精灵末尾都列出了技能串中**其余全部技能**的 ID、名称与学习等级。

效果原文优先取 biligame `技能:` 页 `{{技能|技能效果=...}}`；未抓取图鉴技能页的条目（本轮限流）取 SeerAPI `skill_effect[].info`，并同时给出图鉴链接。命中率 / 暴击概率在 SeerAPI 侧为 `accuracy` / `crit_rate`（6.25 = 1/16）。

---

## 1. 克律莎（图鉴 4944）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 克律莎 |
| 图鉴ID | 4944 |
| 属性 | 远古 电 |
| 种族值 | 体力 166 / 攻击 129 / 防御 107 / 特攻 70 / 特防 107 / 速度 136，总和 **715** |
| 性别 | 雌 |
| 图鉴状态 | `状态=首发`（图鉴原始字段） |
| 来源 | [精灵:4944 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4944&action=raw) ｜ [SeerAPI pet/4944](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4944/index.json) |

### 1.1 先手 远古雷律（38530）

- 类型 / 属性：物理攻击 / 远古 电
- 威力 / PP / 先制 / 命中率 / 暴击：85 / 20 / 3 / 97% / 1/16
- 效果ID：1139 719
- 效果原文：消除双方回合类效果并为双方附加2回合混乱，自身混乱状态解除后则恢复自身全部体力；未击败对手则70%令对手麻痹
- 来源：[技能:38530 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38530&action=raw) ｜ [SeerAPI skill/38530](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38530/index.json)

### 1.2 防御 雷鸣法象（29451）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：191 2161 776
- 效果原文：4回合内免疫并反弹所有受到的异常状态；3回合内使用技能令对手攻击-1，防御-1，特攻-1，特防-1，未触发则自身下1次攻击造成伤害提升100%；下2回合自身造成的攻击伤害翻倍
- 来源：[技能:29451 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29451&action=raw) ｜ [SeerAPI skill/29451](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29451/index.json)

### 1.3 强化 电掣剑光（29452）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：952 708 843
- 效果原文：全属性+1,若对手处于能力下降状态则效果翻倍；恢复自身500点体力，自身体力少于1/2时恢复效果翻倍；下2回合令自身所有技能先制+2（该处原文为半角逗号，照抄来源）
- 来源：[技能:29452 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29452&action=raw) ｜ [SeerAPI skill/29452](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29452/index.json)

### 1.4 制敌 迅离金闪（38531）

- 类型 / 属性：物理攻击 / 远古 电
- 威力 / PP / 先制 / 命中率 / 暴击：150 / 5 / 0 / 97% / 1/16
- 效果ID：799 50
- 效果原文：恢复自身最大体力的1/3并给对手造成等量百分比伤害，自身体力低于1/2时效果翻倍；3回合自身受到物理攻击伤害减半
- 来源：[技能:38531 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38531&action=raw) ｜ [SeerAPI skill/38531](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38531/index.json)

### 1.5 第五技能 万雷俯首令（38532）

- 类型 / 属性：物理攻击 / 远古 电
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：631 1613 882
- 效果原文：消除对手能力提升状态，消除成功下回合造成伤害提升100%；自身不处于能力提升状态则吸取对手250点体力，若先出手则额外吸取100点体力；自身每处于一种能力提升状态，此技能威力提升20
- 来源：[技能:38532 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38532&action=raw) ｜ [SeerAPI skill/38532](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38532/index.json)

### 1.6 技能串中其余技能（未计入四格）

`电光火石10008(1)`、`明亮20273(5)`、`雷电击10171(9)`、`虚弱光线20144(13)`、`雷刀10556(17)`、`沉默20521(25)`、`电磁炮10107(29)`、`电荷牵引23030(33)`、`雷霆万钧10110(37)`、`蓄电充能23031(41)`、`闪电撞击15513(45)`、`雷霆之心23032(53)`

---

## 2. 瑞特拉尼（图鉴 4943）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 瑞特拉尼 |
| 图鉴ID | 4943 |
| 属性 | 地面 |
| 种族值 | 体力 175 / 攻击 130 / 防御 118 / 特攻 70 / 特防 118 / 速度 124，总和 **735** |
| 来源 | [精灵:4943 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4943&action=raw) ｜ [SeerAPI pet/4943](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4943/index.json) |

### 2.1 先手 无想连击（38527）

- 类型 / 属性：物理攻击 / 地面
- 威力 / PP / 先制 / 命中率 / 暴击：85 / 20 / 3 / 97% / 1/16
- 效果ID：485 1104
- 效果原文：消除对手能力提升状态，消除成功则恢复自身全部体力；造成的伤害低于240则吸取对手1/3最大体力
- 来源：[技能:38527 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38527&action=raw) ｜ [SeerAPI skill/38527](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38527/index.json)

### 2.2 防御 固化石躯（29449）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 1 / 必中（95%） / 1/16
- 效果ID：191 1259 1786 679
- 效果原文：4回合内免疫并反弹所有受到的异常状态；4回合内有50%概率免疫对手攻击伤害，未触发则对手防御-2，特防-2，速度-2；3回合内若自身回合类效果被消除则对手下1次使用的攻击技能命中效果失效；3回合内对手无法通过自身技能恢复体力
- 备注：SeerAPI 该技能 `info` 字段为「待添加」，以上文案取自结构化 `skill_effect[].info`
- 来源：[技能:29449 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29449&action=raw) ｜ [SeerAPI skill/29449](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29449/index.json)

### 2.3 强化 大地融合（29450）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：1326 1065 843
- 效果原文：全属性+1，自身处于护盾状态时强化效果翻倍；4回合内每回合使用技能恢复自身最大体力的1/3并造成等量百分比伤害，恢复体力时若自身体力低于最大体力的1/3则恢复效果和百分比伤害翻倍；下2回合令自身所有技能先制+2
- 备注：SeerAPI `info` 为「待添加」，文案取自 `skill_effect[].info`
- 来源：[技能:29450 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29450&action=raw) ｜ [SeerAPI skill/29450](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29450/index.json)

### 2.4 制敌 沙石狂骨刺（38528）

- 类型 / 属性：物理攻击 / 地面
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 97% / 1/16
- 效果ID：1568 1671 1388
- 效果原文：无视护盾效果；造成的攻击伤害不低于300，若对手处于能力提升状态则造成的攻击伤害不低于600；获得300点护罩，护罩消失时使对手1回合攻击技能无效
- 备注：威力字段图鉴/数据结构均为 0（靠效果ID 1671 设定伤害下限）
- 来源：[技能:38528 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38528&action=raw) ｜ [SeerAPI skill/38528](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38528/index.json)

### 2.5 第五技能 乱石落土击（38529）

- 类型 / 属性：物理攻击 / 地面
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：1878 1925 2116
- 效果原文：消除对手回合类效果，若对手不处于回合类效果则吸取对手最大体力的1/4；吸取对手最大体力的1/4；先出手时1回合内对手体力恢复效果减少70%
- 来源：[技能:38529 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38529&action=raw) ｜ [SeerAPI skill/38529](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38529/index.json)

### 2.6 技能串中其余技能（未计入四格）

`撞击10001(1)`、`飞土20222(5)`、`尘土10142(9)`、`泥石奔腾20331(13)`、`落石10706(17)`、`地裂10121(21)`、`枯竭20855(25)`、`土龙破10516(29)`、`钻地20690(33)`、`地缚术11716(37)`、`僵硬20856(41)`、`潜伏突刺10665(45)`、`盲目攻击11717(49)`、`融入大地20857(53)`、`沙石骨刺11715(57)`、`落土飞岩11718(61)`

---

## 3. 极度冰凌·阿克希亚（图鉴 4942）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 极度冰凌·阿克希亚 |
| 图鉴ID | 4942 |
| 属性 | 冰 |
| 种族值 | 体力 172 / 攻击 70 / 防御 115 / 特攻 142 / 特防 115 / 速度 136，总和 **750** |
| 来源 | [精灵:4942 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4942&action=raw) ｜ [SeerAPI pet/4942](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4942/index.json) |

### 3.1 先手 极度·寒魄（38522）

- 类型 / 属性：特殊攻击 / 冰
- 威力 / PP / 先制 / 命中率 / 暴击：90 / 20 / 3 / 必中（97%） / 1/16
- 效果ID：1055 2568 2533
- 效果原文：消除对手能力提升状态，消除成功则下1回合令对手使用的攻击技能无效；反转自身能力下降状态，反转成功则使对手下1次属性技能无效；100%令对手冻伤，未触发则恢复自身所有技能2点PP值
- 来源：[技能:38522 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38522&action=raw) ｜ [SeerAPI skill/38522](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38522/index.json)

### 3.2 防御 冰凌·拥天（29444）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：191 1023 1003 2532
- 效果原文：4回合内免疫并反弹所有受到的异常状态；3回合内100%闪避对手攻击，若对手MISS则恢复自身最大体力的1/3；命中后100%使对手冰封，未触发则使对手全属性-1；本场战斗己方精灵每在场下受到260点伤害，汲取对手260点体力恢复至己方不在场精灵，最高不超过对手最大体力的100%
- 来源：[技能:29444 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29444&action=raw) ｜ [SeerAPI skill/29444](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29444/index.json)

### 3.3 强化 冰凌·雪舞（29445）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：433 2093 2567 843
- 效果原文：3回合内每回合攻击+1，防御+1，特攻+1，特防+1，速度+1，命中+1；4回合内使用技能吸取对手最大体力的1/3，自身体力低于1/2时效果翻倍，吸取后若对手体力未减少则2回合内对手无法恢复体力；获得3回合冰呪；下2回合令自身所有技能先制+2
- 来源：[技能:29445 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29445&action=raw) ｜ [SeerAPI skill/29445](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29445/index.json)

### 3.4 制敌 极度·冰点（38523）

- 类型 / 属性：特殊攻击 / 冰
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 1 / 1 / 0%（图鉴/结构化字段均为 0，属特殊机制技能） / 1/16
- 效果ID：2569 1101
- 效果原文：若对方存在含有“秒杀”的特性，则自身的被击败效果取消被击败要求，且每有1个含有“秒杀”的特性，此技能命中值提升100、20%的概率不消耗PP值；命中后100%秒杀对方，若MISS则自身死亡，使对手随机3个技能的PP值归零且全属性-1
- 来源：[技能:38523 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38523&action=raw) ｜ [SeerAPI skill/38523](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38523/index.json)

### 3.5 第五技能 极度·忘川（38524）

- 类型 / 属性：特殊攻击 / 冰
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：1959 1249 2105 1960 2280
- 效果原文：消除对手回合类效果，消除成功100%令对手冰封，未触发则造成的攻击伤害翻倍；造成伤害的100%恢复自身体力，若对手处于异常状态则附加等量百分比伤害；未击败对手则令对方场下阵亡的首位精灵消逝；击败对手则令自身3回合内的能力提升状态无法被消除或吸取；技能无效时，对手下回合无法主动切换精灵
- 来源：[技能:38524 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38524&action=raw) ｜ [SeerAPI skill/38524](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38524/index.json)

### 3.6 技能串中其余技能（未计入四格）

`冰之刃10200(1)`、`甩尾10201(5)`、`霜甲20056(9)`、`冰甲20057(13)`、`冷冻光线10202(17)`、`寒冰冻气10204(21)`、`破冰尾10203(25)`、`寒流20058(29)`、`玄冰箭10205(33)`、`碎冰10206(37)`、`寒冰护体20059(41)`、`凝冻冰雹10218(45)`、`冰封20060(49)`、`无极冰刃13176(53)`、`冰天雪地10208(57)`、`圣灵闪10207(61)`、`极冰风暴10209(71)`、`极度冰点10210(72)`、`冰之祝福21668(73)`、`寒光冰魄13177(74)`、`雪舞冰封21669(75)`、`寒天玄冰破13178(76)`

---

## 4. 瑞丁（图鉴 4941）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 瑞丁 |
| 图鉴ID | 4941 |
| 属性 | 飞行 暗影 |
| 种族值 | 体力 174 / 攻击 120 / 防御 100 / 特攻 70 / 特防 104 / 速度 132，总和 **700** |
| 来源 | [精灵:4941 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4941&action=raw) ｜ [SeerAPI pet/4941](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4941/index.json) |

### 4.1 先手 复读（38519）

- 类型 / 属性：物理攻击 / 飞行 暗影
- 威力 / PP / 先制 / 命中率 / 暴击：85 / 20 / 3 / 97% / 1/16
- 效果ID：1080 9
- 效果原文：连续使用时先制+1；连续使用每次威力增加10，最高威力150
- 名称差异：图鉴 `技能:38519` 写作「复读」，SeerAPI 数据集写作「复读机」；本文以图鉴原文「复读」为准
- 来源：[技能:38519 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38519&action=raw) ｜ [SeerAPI skill/38519](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38519/index.json)

### 4.2 防御 升维论（29442）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：48 1396 1475
- 效果原文：4回合内免疫所有受到的异常状态；3回合内每回合吸取对手最大体力的1/4，自身体力低于最大体力的1/4时转变为吸取对手最大体力的1/3；3回合内自身受到的固定伤害和百分比伤害减少25%
- 来源：[技能:29442 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29442&action=raw) ｜ [SeerAPI skill/29442](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29442/index.json)

### 4.3 强化 数学大厦（29443）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：877 43 843
- 效果原文：先出手时全属性+1；恢复自身最大体力的1/3；下2回合令自身所有技能先制+1
- 来源：[技能:29443 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29443&action=raw) ｜ [SeerAPI skill/29443](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29443/index.json)

### 4.4 制敌 惊人注意力（38520）

- 类型 / 属性：物理攻击 / 飞行 暗影
- 威力 / PP / 先制 / 命中率 / 暴击：150 / 5 / 0 / 97% / 1/16
- 效果ID：1429
- 效果原文：50%的概率打出致命一击，未触发则100%令对手睡眠
- 来源：[技能:38520 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38520&action=raw) ｜ [SeerAPI skill/38520](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38520/index.json)

### 4.5 第五技能 知识渗透压（38521）

- 类型 / 属性：物理攻击 / 飞行 暗影
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：2250
- 效果原文：平均自身的能力等级，然后自身每减少了1项能力的等级附加30点真实伤害，每增加了1项能力的等级令对手下次攻击造成的伤害减少10%
- 来源：[技能:38521 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38521&action=raw) ｜ [SeerAPI skill/38521](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38521/index.json)

### 4.6 技能串中其余技能（未计入四格）

`叩击10127(1)`、`果断20496(5)`、`碎星击13527(9)`、`净火繁星14045(13)`、`狂热战意20769(17)`、`星辰突变13532(25)`、`不朽战甲21021(29)`、`惊爆闪光32820(33)`、`启明祝愿26502(37)`、`次元之灵33083(41)`、`优等成绩26629(45)`、`学霸之志26630(53)`

---

## 5. 王座守卫·古亚尼斯（图鉴 4940）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 王座守卫·古亚尼斯 |
| 图鉴ID | 4940 |
| 属性 | 圣灵 电 |
| 种族值 | 体力 176 / 攻击 140 / 防御 114 / 特攻 70 / 特防 114 / 速度 126，总和 **740** |
| 来源 | [精灵:4940 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4940&action=raw) ｜ [SeerAPI pet/4940](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4940/index.json) |

### 5.1 先手 雷影轮（38516）

- 类型 / 属性：物理攻击 / 圣灵 电
- 威力 / PP / 先制 / 命中率 / 暴击：85 / 20 / 3 / 97% / 1/16
- 效果ID：794 436 1082
- 效果原文：消除对手能力提升，消除成功可以抵挡2回合内对手的攻击伤害；附加已损失体力值70%的百分比伤害；造成的伤害低于200则附加自身最大体力40%的百分比伤害
- 来源：[技能:38516 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38516&action=raw) ｜ [SeerAPI skill/38516](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38516/index.json)

### 5.2 防御 倍量磁场（29440）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：191 2492 147
- 效果原文：4回合内免疫并反弹所有受到的异常状态；消除双方的护盾、护罩效果，若消除的数额相等则对手3回合内无法主动切换精灵且属性技能无效；后出手时，50%概率使对方瘫痪
- 来源：[技能:29440 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29440&action=raw) ｜ [SeerAPI skill/29440](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29440/index.json)

### 5.3 强化 循环电弧（29441）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：1397 1909 1605 619
- 效果原文：全属性+1，自身体力低于1/2时强化效果翻倍；令自身体力等于最大体力的50%，若自身当前体力高于最大体力的50%则回合结束后额外触发一次该效果；100%令对手超频；下2回合令对手所有技能先制-2
- 来源：[技能:29441 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29441&action=raw) ｜ [SeerAPI skill/29441](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29441/index.json)

### 5.4 制敌 雷霆之壁（38517）

- 类型 / 属性：物理攻击 / 圣灵 电
- 威力 / PP / 先制 / 命中率 / 暴击：150 / 5 / 0 / 97% / 1/16
- 效果ID：773 1447
- 效果原文：若自身体力低于对手则与对手互换体力；自身体力高于最大体力的1/2时100%令对手麻痹
- 来源：[技能:38517 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38517&action=raw) ｜ [SeerAPI skill/38517](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38517/index.json)

### 5.5 第五技能 奔雷极光斩（38518）

- 类型 / 属性：物理攻击 / 圣灵 电
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：789 1041 2161
- 效果原文：消除对手回合类效果，消除成功对手下2回合受到的伤害翻倍；造成的攻击伤害若低于300则令对手下1次使用的攻击技能无效；3回合内使用技能令对手攻击-1，防御-1，特攻-1，特防-1，速度-1，命中-1，未触发则自身下2次攻击造成伤害提升100%
- 来源：[技能:38518 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38518&action=raw) ｜ [SeerAPI skill/38518](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38518/index.json)

### 5.6 技能串中其余技能（未计入四格）

`撞击10001(1)`、`发电20196(5)`、`回转10454(9)`、`电光圈10455(13)`、`折磨20013(17)`、`电光轮切37731(21)`、`电网20127(25)`、`电流撞击10106(29)`、`电磁射线10459(33)`、`倍量正电荷37732(37)`、`雷电突刺10456(41)`、`雷之枪10460(45)`、`倍量负电荷28929(49)`、`猛烈撞击10457(53)`、`超电弧37733(57)`、`高压电场28930(61)`、`奔雷极斩37734(71)`

---

## 6. 决囚钢骨（图鉴 4939）

| 基础字段 | 值 |
| --- | --- |
| 名称 | 决囚钢骨 |
| 图鉴ID | 4939 |
| 属性 | 机械 次元 |
| 种族值 | 体力 160 / 攻击 136 / 防御 125 / 特攻 70 / 特防 100 / 速度 129，总和 **720** |
| 来源 | [精灵:4939 raw](https://wiki.biligame.com/seer/index.php?title=%E7%B2%BE%E7%81%B5:4939&action=raw) ｜ [SeerAPI pet/4939](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/pet/4939/index.json) |

### 6.1 先手 搅碎（38510）

- 类型 / 属性：物理攻击 / 机械 次元
- 威力 / PP / 先制 / 命中率 / 暴击：110 / 10 / 2 / 必中（95%） / 1/16
- 效果ID：1767 1157（图鉴该页 `效果ID` 字段为空，此处取 SeerAPI）
- 效果原文：攻击时将对手的能力提升状态视为相应的能力下降状态；消除双方能力提升、下降状态，消除任意一方成功则使对手下1次施放的技能无效（包括必中技能）
- 来源：[技能:38510 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38510&action=raw) ｜ [SeerAPI skill/38510](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38510/index.json)

### 6.2 防御 十里枯监（29438）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：191 2306 570
- 效果原文：4回合内免疫并反弹所有受到的异常状态；下1次技能无效时令对手瘫痪，若为攻击技能则造成的伤害不少于200；免疫下1次对手的攻击
- 来源：[技能:29438 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29438&action=raw) ｜ [SeerAPI skill/29438](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29438/index.json)

### 6.3 强化 削山骼网（29439）

- 类型 / 属性：属性攻击 / 普通
- 威力 / PP / 先制 / 命中率 / 暴击：0 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：2193 1855 619
- 效果原文：自身不处于能力提升状态时100%令对手害怕，触发成功则3回合内对手使用技能攻击+1，防御+1，特防+1，速度-1，命中+1，未触发则2回合内令对手属性技能无效；4回合内每回合使用技能额外恢复自身最大体力的1/3，若自身不处于能力提升状态则附加对手最大体力1/3的百分比伤害；下2回合令对手所有技能先制-2
- 来源：[技能:29439 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:29439&action=raw) ｜ [SeerAPI skill/29439](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/29439/index.json)

### 6.4 制敌 狂椎散闪斩（38513）

- 类型 / 属性：物理攻击 / 机械 次元
- 威力 / PP / 先制 / 命中率 / 暴击：2 / 5 / 0 / 97% / 1/16
- 效果ID：1807 484
- 效果原文：自身处于能力下降时先制+2；连击100次，每次命中后连击数+25，最高连击200次
- 备注：威力字段图鉴/数据结构均为 2（基础连击威力），实际伤害由连击机制决定
- 来源：[技能:38513 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38513&action=raw) ｜ [SeerAPI skill/38513](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38513/index.json)

### 6.5 第五技能 幽骸锁魂阵（38514）

- 类型 / 属性：物理攻击 / 机械 次元
- 威力 / PP / 先制 / 命中率 / 暴击：160 / 5 / 0 / 必中（95%） / 1/16
- 效果ID：1734 1674 2351
- 效果原文：消除对手回合类效果，消除成功则100%令对手流血，若对手不处于回合类效果则造成的攻击伤害提升100%；2回合内每回合使用技能吸取对手最大体力的1/4，若对手未受到百分比伤害则额外附加400点真实伤害；未击败对手时令对手全属性-1，未触发则对手1回合内无法主动切换精灵
- 来源：[技能:38514 raw](https://wiki.biligame.com/seer/index.php?title=%E6%8A%80%E8%83%BD:38514&action=raw) ｜ [SeerAPI skill/38514](https://cdn.jsdelivr.net/gh/SeerAPI/api-data@HEAD/data/v1/data/skill/38514/index.json)

### 6.6 技能串中其余技能（未计入四格）

`突击10157(1)`、`加速20030(5)`、`疾速钢拳12804(9)`、`穿透光束10333(13)`、`坚韧不屈21747(17)`、`异空之光13106(25)`、`顿足20513(29)`、`流轮光斩14042(33)`、`钢铁切割18133(37)`、`隙间制动29437(41)`、`降维处决38511(45)`、`裂解坍压38512(57)`

---

## 7. 未能核实项

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 图鉴「精灵图鉴」页的官方「近期更新」标记 | **未核实** | 该列表页本轮被站点限流拦截（HTTP 567）；本文改用「图鉴 ID + api-data 首次入库日期」口径，属代理指标。 |
| 6 只精灵在游戏内的正式上线日期 | **未核实** | 只核实到 api-data 数据首次入库日期（见 §0.1 表）。 |
| 各技能图鉴 `技能:` 页的效果原文（除 38530 / 38519 / 38510 / 24120 / 20364 等已抓取页外） | 部分核实 | 其余技能的效果原文取自 SeerAPI `skill_effect[].info`（与客户端数据一致）；图鉴链接已给出可人工点开比对，但本轮未逐页抓取。 |
| 29449 / 29450 的图鉴效果原文 | **未核实** | SeerAPI 该两条记录 `info` 字段为「待添加」，本文文案取自 `skill_effect[].info`；对应的 `技能:29449` / `技能:29450` 图鉴页本轮未抓取。 |
| 38519 的名称（复读 / 复读机） | 差异已记录 | 图鉴页写「复读」，SeerAPI 写「复读机」；正文采用图鉴名并注明差异，无法从第三方来源判定哪一个为客户端实际名。 |
| 4905–4938 区间其它新精灵 | 未核实 | 本轮按入库日期只取 6 只；同批次（2026-09-04 入库）还有 4938 塞壬斯、4937 星光·雷纳多、4936 拿瓦铠甲等，未逐一展开。 |

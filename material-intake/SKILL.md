---
name: material-intake
description: 材料代办录入：把收到的材料文件夹、压缩包、截图或零散文档整理成录入台账、产出所需文书、按白名单根目录分流归档并登记归档台账。当用户说「录入一下」「处理这批材料」「归档一下」「这些材料放哪」时使用。不用于单份合同的审查修订、单份文书的起草排版或法条检索。
metadata:
  short-description: 材料收件、录入台账、分流归档与归档登记
  author: 常威律师
---

# 材料代办录入

把一堆零散材料变成「有台账、有去向、有登记」的卷宗材料。

本技能由常威律师整理编制。使用与改进意见请反馈给编制人。

本技能在 Codex、WorkBuddy（腾讯 CodeBuddy 内核）与千问办公（QwenWork）上通用：技能结构、脚本与台账格式一致，只有安装位置与 frontmatter 写法不同，见第四节。

## 适用边界

适用：材料收件与录入、批量归档、重复件查重、拍照件与扫描件识别后归档。

不适用：单份合同审查（走合同审查流程）、单份文书起草排版（走文书技能）、法条检索（走法律检索流程）。这些任务若附带归档要求，归档部分仍按本技能处理。

## 零、先读现场约定

工作区内若存在 `自动化约定.md`、`AGENTS.md`、`归档台账.md`，先读它们再动手，以现场约定为准（目录名、命名规则、去向对照可能已被本地化）。本技能提供的是缺省流程。

## 零之二、安装与首次授权：由你带用户做，不许只丢文档

用户刚装好本技能、或第一次要用日历／提醒时，**必须由你按 [references/安装与授权引导.md](references/安装与授权引导.md) 逐项引导他完成授权**。三条纪律：

1. **分阶段、一次最多两项**：装机档零授权（台账、查重、归档、登记都能用——先把这句话说清楚）→ 台账档（文件访问）→ 日程档（日历／提醒）→ 通知档（系统通知、本机订阅、钉钉）。用不到的能力不提前要权限。
2. **每项四句话**：为什么要 → 点哪里、选什么（含要勾选的应用名与权限档位）→ 能不能拒绝、拒绝后用哪条替代 → 改完跑哪条命令复检。
3. **不代点、不绕过**：系统授权只能用户本人在系统设置里点；代点、改注册表绕过、脚本模拟点击一律不做。你的职责是把话说清、路径给准、复检做掉，并把复检结果读给他听。

用户拒绝任何一项时，按引导文档第四节的降级表说明「仍能用什么」，不得让他以为不给权限就用不了。

## 一、工作区

本技能围绕一个「材料代办录入工作区」运行，缺省目录名 `00-材料代办录入`：

| 目录 | 职责 | 谁放 |
|---|---|---|
| `待处理/` | 新文件、新文件夹的入口 | 用户 |
| `代办录入/` | 工作区，每次任务一个子目录 | 助手 |
| `已处理/` | 已读取、已建卡的原件 | 助手 |
| `待归档/` | 等用户确认后归入各案的材料 | 助手 |

工作区位置、归档允许根目录、去向对照写在配置文件里，见 [references/配置与归档去向.md](references/配置与归档去向.md)。未配置时先跑 `doctor` 诊断，再 `init-config` 生成配置模板。

## 二、八步流程

1. **建任务**：在 `代办录入/` 下新建 `YYYYMMDD-任务简称/`，内含 `源文件/`、`产出/`、`录入台账.md`。
2. **收件**：把源材料复制进 `源文件/`。源在库内的，处理完原件移入 `已处理/`；源在库外（微信、桌面、下载目录）的，只读、只复制副本，原件不动。
3. **录入**：逐件读取（docx／xlsx／有文字层的 pdf 直接解析，扫描件走 OCR 或视觉识别），填写 `录入台账.md`。
4. **日程写入**：材料里凡有开庭、举证期限、上诉期、答辩期、会议、驻场等时间事项，一律落成「日历事件 + 分档提醒」——先列清单给用户确认，确认后写入，并把结果回填台账「处理记录」。macOS 直写系统日历与提醒事项；Windows 与其他系统导出日历文件导入。规则与命令见第四节与 [references/日程写入.md](references/日程写入.md)。
5. **产出**：需要生成的文书、清单、摘录放 `产出/`，文件名带日期后缀。
6. **分流**：原件移入 `已处理/`；需要入卷的移入 `待归档/`，并在对话中列出建议去向清单，等用户确认。
7. **入卷**：用户确认后按目标目录结构归位，并在 `归档台账.md` 追加一行。
8. **汇报**：来源、去向、状态、待办四项一次说清；期限类另附已写入的日程与提醒档位。

细则（命名规范、台账字段、类型枚举、摘要写法、缺页与重复件处理、汇报模板、与其他技能的配合）见 [references/工作流细则.md](references/工作流细则.md)。

## 三、硬约束

1. **不删原件**。需要删除时先列清单，经用户确认，并校验目标路径落在允许的父目录内。
2. **先查重**。归档前按 SHA256 加全库文件名搜索排查重复，疑似重复先报告再动手。
3. **不覆盖**。同名文件另存新名，不覆盖既有文件。
4. **库外只读**。库外来源的材料只读复制，不移动、不改名、不删除。
5. **白名单内写入**。归档目标必须落在配置的允许根目录内；配置为空时不得执行归档，只输出建议。
6. **涉密先脱敏**。对外分享、或调用第三方接口（OCR、视觉模型、云盘）处理客户材料前，先按脱敏规则处理客户标识；未经授权不得把客户材料上传外部服务。

## 四、工具

技能自带脚本，仅用 Python 标准库。下文的 `$SKILL` 指本技能目录，即 `SKILL.md` 所在目录，按宿主不同为：

命令里的 `python3` 在 Windows 上换成 `python`（或 `py -3`），其余参数不变。

| 宿主 | 用户级安装位置 | 项目级安装位置 |
|---|---|---|
| Codex | `~/.codex/skills/material-intake/` | 无（只用用户级） |
| WorkBuddy | `~/.workbuddy/skills/material-intake/` | `<项目>/.workbuddy/skills/material-intake/` |
| 千问办公 | `~/.qwenworkcn/skills/material-intake/` | 无（用户级；容器内为 `/root/.qwenworkcn/skills/`） |
| 常威律师 DSH（macOS 桌面版） | `~/Library/Application Support/常威律师 DSH/harness/skills/material-intake/` | 无（只用用户级） |

旧版 WorkBuddy 使用 `~/.codebuddy/skills/`，两种路径都在识别范围内；Windows 上千问办公为 `%USERPROFILE%\.qwenworkcn\skills\`。调用脚本前若不确定，先用 `ls` 确认目录存在。

DSH 上另有一处宿主前置：macOS 14 起，宿主应用申请日历／提醒事项「完全访问」时，其 `Info.plist` 必须声明 `NSCalendarsFullAccessUsageDescription` 与 `NSRemindersFullAccessUsageDescription`。缺这两个键时系统不弹窗、直接静默拒绝（后端 0.04 秒返回「未授权」），日程写入会凭空不可用。修复做法：补上两个键 → `codesign --force --sign - --preserve-metadata=identifier,entitlements,flags` 重签 → 退出并重开宿主。这属于改动他人应用包，本技能不附带自动修复脚本，须按 [references/安装与授权引导.md](references/安装与授权引导.md) 第七节，先向使用者明示改什么、如何还原，取得同意后执行。

```bash
python3 "$SKILL/scripts/material_intake.py" doctor
python3 "$SKILL/scripts/material_intake.py" init-config --out ~/.material-intake/config.json
python3 "$SKILL/scripts/material_intake.py" init --task 张某代位权开庭传票 --source "微信收到截图"
python3 "$SKILL/scripts/material_intake.py" init --task 张某代位权开庭传票 --create-workspace   # 工作区不存在时代建
python3 "$SKILL/scripts/material_intake.py" scan --src 代办录入/20260928-任务简称/源文件
python3 "$SKILL/scripts/material_intake.py" dedupe --src 某材料.pdf --root /path/to/案件库
python3 "$SKILL/scripts/material_intake.py" archive --src 产出/清单.md --dest /path/to/案件库/某案/某目录
python3 "$SKILL/scripts/material_intake.py" archive --src 产出/清单.md --dest /path/to/案件库/某案/某目录 --note "来源与状态说明" --apply
```

`archive` 缺省只预演，加 `--apply` 才真正写入；写入后自动在归档台账顶部追加一行。任何命令都不删除、不覆盖原件。

日程写入另有一个模块，同样缺省只预演（Windows 上把 `python3` 换成 `python`）：

```bash
python3 "$SKILL/scripts/schedule_write.py" doctor                     # 平台、授权、容器自检
python3 "$SKILL/scripts/schedule_write.py" plan  --json 产出/日程清单.json
python3 "$SKILL/scripts/schedule_write.py" apply --json 产出/日程清单.json     # macOS：直写日历与提醒
python3 "$SKILL/scripts/schedule_write.py" ics   --json 产出/日程清单.json --out 产出/日程清单.ics   # Windows／任意平台
python3 "$SKILL/scripts/schedule_write.py" list --days 60
python3 "$SKILL/scripts/schedule_write.py" rm --anchor LR-MI-XXXXXXXX --apply
```

<!-- win-only -->
**以下 Windows 专属通道仅在 Windows 上使用**（macOS 侧只用 EventKit 直写与 `.ics` 导出，不受影响）：

Windows 上另有本机日历后端（无需手工导入、可读回与撤销）：

```powershell
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_calendar.ps1" doctor
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_calendar.ps1" apply -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_calendar.ps1" list -Days 60
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_calendar.ps1" rm -Anchor LR-MI-XXXXXXXX -Apply
```

它直接写 Windows 系统日历存储，输入同一份 `日程清单.json`，锚点算法与 `schedule_write.py` 一致，两条通道混用不产生重复条目。用法、对应关系与限制见 [references/本机日历接入（Windows）.md](references/本机日历接入（Windows）.md)。

```powershell
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" doctor
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" install              # 每机一次，注册通知身份
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" selftest -DelaySeconds 40
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" apply -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" list
powershell -ExecutionPolicy Bypass -File "$SKILL\scripts\win_remind.ps1" clear -Anchor LR-MI-XXXXXXXX -Apply
```

用法、限制与验证记录见 [references/通知提醒接入（Windows）.md](references/通知提醒接入（Windows）.md)。

另有两项 Windows 专属扩展通道：**本机日历订阅**（`calendar_feed.ps1` ＋ `serve_feed.py`，把各任务 `产出\日程清单.ics` 合并成 `http://127.0.0.1:8799/agenda.ics` 供桌面日历客户端订阅；`install` 注册开机自启计划任务）与**钉钉**（`dingtalk_remind.ps1` 机器人 webhook 到点推手机钉钉，或 `dws`／`dws-core` 写钉钉日历与待办）。两点必须先讲明：① 钉钉通道**会出网**，日程标题与时间会上传钉钉服务器，标题含案号、法院、当事人时属案件信息外发，**涉密案件改用系统通知或 `.ics`**；② 凭据（机器人 webhook token 存 `%USERPROFILE%\.material-intake\dingtalk.json`；CLI 登录存 `%USERPROFILE%\.dws\`）只在本机保存，**不随包分发**，对外分发时接收方需自备授权。命令、已知坑与五通道取舍见 [references/日历订阅与钉钉接入（Windows）.md](references/日历订阅与钉钉接入（Windows）.md)。

<!-- /win-only -->

## 五、汇报四要素

- **来源**：材料从哪来、什么形式、共几件。
- **去向**：逐件给出目标路径，未确认的写「待确认」。
- **状态**：已录入／已归档／已登记／待补材料。
- **待办**：需要用户决策或补充的事项，按紧急度排序。

## 六、环境与外部依赖

文档解析、OCR、视觉识别、正式文书排版、法条核验仍属外接能力，各自可选、按需自备。清单与注意事项见 [references/依赖与注意事项.md](references/依赖与注意事项.md)。

运行环境：Windows 侧需 **Windows 11 及以上**（本机日历后端按此验证）；macOS 侧需 **macOS 14 及以上**（日历后端二进制最低系统版本 14.0）；Python 3.9 及以上。

需要授权或会改动系统的十三处（日历、提醒事项、文件与文件夹、宿主沙箱可写范围、Windows 日历访问、PowerShell 执行策略、Gatekeeper、SmartScreen、宿主库外读取确认、Windows 通知总开关、提醒身份注册、本机日历订阅服务、钉钉通道）及各处的放行路径与拒绝后果，见 [references/依赖与注意事项.md](references/依赖与注意事项.md) 第六节；分阶段引导话术见 [references/安装与授权引导.md](references/安装与授权引导.md)。缺任何一项都不会静默失败：脚本会给出放行路径或直接拒绝执行。

其中两处属于系统改动，执行前必须先向使用者明示改什么、影响谁、怎么回退，得到同意再动：Windows 通知总开关（打开后所有应用通知都会弹）、提醒身份注册（写注册表项与开始菜单快捷方式，可完整回退）。

日程写入的三条底线（写在模块里，不要绕过）：

1. 只操作备注末行带「来福ID: <锚点>」的条目，绝不触碰手工创建的事件与提醒。
2. 同一锚点先查后写，反复执行不产生重复条目。
3. 缺省只预演，`--apply` 才落盘；撤销同样先预演。

各宿主与写入权限有关的差异，动手前先确认：

- Codex：归档目标须落在配置的 `allowed_roots` 内，配置为空时归档被拒绝。
- WorkBuddy：除本技能的白名单校验外，宿主自身还有沙箱写入范围。归档到工作区以外（例如案件库在另一个盘符或目录树）时，需先在 WorkBuddy 设置里放行该目录，否则脚本会被宿主拦截。
- 千问办公：实测宿主可写入工作区以外的白名单目录（2026-09-28 验证）；首次归档到新目录仍建议先预演、再拿一条小件试写。
<!-- win-only -->
<!-- /win-only -->
- 各宿主共同的日历坑：macOS 允许把权限授成「仅写入」。此时写入会成功，但读取与删除全被拒绝，防重复与按锚点撤销会同时失效。`doctor` 会实测读权限，读不了就报 `ok:false` 并拒绝 `apply`；「日历授权：已授权」不等于能读，以结论行为准。

<!-- win-only -->
**Windows 日历提醒的前置条件（重要，不要承诺做不到的事）**：

<!-- /win-only -->

# material-intake · 材料代办录入技能

把一堆零散的案卷材料，变成「有台账、有去向、有登记」的卷宗。

一个跨宿主的 AI 助手技能（Agent Skill），适用于 Codex、WorkBuddy、千问办公（QwenWork）、DSH 桌面版。技能本体全部在本机运行：收件、查重、录入台账、分流归档、归档登记，以及把材料里的期限写成日历事件与分档提醒。

> **免责声明**
> 本项目为常威律师（[@changwei-law](https://github.com/changwei-law)）的个人开源项目，不代表任何律师事务所，亦不构成法律意见。
> 使用者应自行核验其在本地的适用性，并对所处理材料的保密与合规负责。处理涉密材料前，请先按所在机构的保密规则脱敏。

---

## 一、它解决什么问题

办案材料往往以文件夹、压缩包、截图、零散文档的形式涌进来。手工整理的痛点是三件事：**记不清收过什么、不知道归到哪、归档没留痕**。本技能把这三件事固定成流程与台账：

| 能力 | 说明 |
|---|---|
| 收件与查重 | 按 SHA256 与全库文件名排查重复件，疑似重复先报告再动手 |
| 录入台账 | 逐件读取（docx／xlsx／有文字层 PDF 直接解析，扫描件走 OCR），按固定字段登记 |
| 分流归档 | 按配置的允许根目录与去向对照表归位，不覆盖、不删原件、库外来源只读 |
| 归档登记 | 每次归档追加一行台账，可回溯、可复查 |
| 日程写入 | 开庭、举证期限、上诉期、答辩期、会议、驻场等时间事项一律落成「日历事件 + 分档提醒」，先出清单待确认再写入 |
| 五通道提醒 | macOS 直写系统日历与提醒事项；Windows 直写本机日历、系统通知、日历订阅、钉钉机器人 |

## 二、八步流程

1. **建任务** — 在 `代办录入/` 下建 `YYYYMMDD-任务简称/`，含 `源文件/`、`产出/`、`录入台账.md`
2. **收件** — 源材料复制进 `源文件/`；库内来源处理完原件移入 `已处理/`，库外来源只读
3. **录入** — 逐件读取并填写 `录入台账.md`
4. **日程写入** — 先列清单给用户确认，确认后写入日历与提醒，结果回填台账
5. **产出** — 生成的文书、清单、摘录放 `产出/`，文件名带日期后缀
6. **分流** — 需入卷的移入 `待归档/`，并列出建议去向清单等确认
7. **入卷** — 确认后按目标目录结构归位，并在 `归档台账.md` 追加一行
8. **汇报** — 来源、去向、状态、待办四项一次说清

工作区目录、归档允许根目录与去向对照全部写在配置文件里，不写死在脚本中。技能默认读现场已有的 `自动化约定.md`、`AGENTS.md`、`归档台账.md`，以现场约定为准。

## 三、安装

技能就是 `material-intake/` 这个目录。把整个目录复制到你所用的宿主技能目录下即可：

| 宿主 | 安装位置 |
|---|---|
| Codex | `~/.codex/skills/material-intake/` |
| WorkBuddy | `~/.workbuddy/skills/material-intake/`（旧版 `~/.codebuddy/skills/`） |
| 千问办公（QwenWork） | `~/.qwenworkcn/skills/material-intake/` |
| DSH 桌面版 | 应用数据目录下的 `harness/skills/material-intake/` |

Windows 上对应 `%USERPROFILE%\` 下的同名目录。装好后运行配置初始化：

```bash
python3 material-intake/scripts/material_intake.py doctor        # 体检：宿主、依赖、权限、配置
python3 material-intake/scripts/material_intake.py init-config   # 生成配置模板
```

首次使用日历或提醒功能时，**必须由使用者本人在系统设置里授权**，技能不会代点、不会绕过：

- macOS：系统设置 → 隐私与安全性 → 日历／提醒事项，勾选当前宿主应用，权限档位选**「完全访问」**。只给「仅写入」会导致读取被拒，查重与按锚点撤销同时失效，脚本会直接拒绝写入。
- Windows：系统要求 Windows 11 及以上、Windows PowerShell 5.1。日历订阅与钉钉通道需另行安装，见 `material-intake/references/` 下对应文档。

## 四、依赖与已知限制

- **Python 3**：三个脚本（`material_intake.py`、`schedule_write.py`、`serve_feed.py`）仅用标准库，无需 pip 安装。
- **macOS 日程后端**：`material-intake/bin/lr_ek` 是调用 EventKit 的命令行工具，仓库内附源码 `lr_ek.swift`。随包二进制为 **Apple Silicon（arm64）** 架构，Intel Mac 请自行编译：

  ```bash
  swiftc -O material-intake/bin/lr_ek.swift -o material-intake/bin/lr_ek
  ```

  之所以不用 AppleScript：macOS 的 AppleScript 通道无法删除周期性事件（实测静默失败），EventKit 可以。条目识别一律靠备注末行的锚点「来福ID: &lt;anchor&gt;」整行精确匹配，不使用模糊包含，避免误伤同名条目。
- **Windows**：桌面日历、系统通知、日历订阅与钉钉四个后端均为 PowerShell 脚本，实测环境为 Windows 11（10.0.26200）。Windows 10 及更早版本上的 WinRT 日历存储接口行为未经验证，`doctor` 会给出提示。
- **通知身份**：Windows 系统通知使用 `MaterialIntake.Reminder` 作为 AppUserModelId。

## 五、隐私与数据

- 除钉钉通道外，**全部处理在本机完成**，不上传任何材料内容。
- **钉钉通道会出网**：日程标题与时间会上传钉钉服务器。标题含案号、法院、当事人时属案件信息外发，涉密案件请改用系统通知或本机日历订阅。
- 凭据只存本机、不随包分发：钉钉机器人 webhook token 存 `%USERPROFILE%\.material-intake\dingtalk.json`，日历订阅服务仅监听 `127.0.0.1`。
- 仓库不含任何真实案件材料、当事人信息或凭据；`assets/config.example.json` 中的路径均为占位符。

## 六、目录结构

```
material-intake/
├── SKILL.md                        技能说明与主流程
├── assets/                         配置与台账模板
├── bin/lr_ek, lr_ek.swift          macOS EventKit 后端（二进制 + 源码）
├── references/                     工作流细则、安装授权引导、各通道接入说明
└── scripts/                        Python 与 PowerShell 实现
```

## 七、许可

[MIT License](LICENSE) © 2026 常威律师

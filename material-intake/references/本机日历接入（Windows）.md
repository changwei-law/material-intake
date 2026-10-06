# 本机日历接入（Windows）

本文件说明 Windows 侧直写本机日历的后端 `scripts/win_calendar.ps1`。该后端由常威律师在 Windows 11 实机验证后并入母本（2026-09-28），署名：常威律师。

**系统要求：Windows 11 及以上。** 已验证环境为 Windows 11（10.0.26200）＋ Windows PowerShell 5.1。Windows 10 及更早版本上 WinRT 日历存储接口的行为未经验证；`doctor` 会打印检测到的系统版本，低于 Windows 11 时给出提示。

## 一、为什么需要这个后端

补上第三个后端 `win_calendar.ps1`：直接写 Windows 系统日历存储（`Windows.ApplicationModel.Appointments`），条目进入本机日历，无需手工导入。三者的取舍见本文第七节。

## 二、可用性自检

```powershell
powershell -ExecutionPolicy Bypass -File scripts\win_calendar.ps1 doctor
```

自检报告平台、PowerShell 版本、系统日历存储中的日历清单与写入目标。实测环境：Windows 11（10.0.26200）＋Windows PowerShell 5.1，系统日历存储可用，含 1 个可写日历「日历」。

## 三、命令

```powershell
$W = "$SKILL\scripts\win_calendar.ps1"   # $SKILL = 本技能目录

powershell -ExecutionPolicy Bypass -File $W doctor
powershell -ExecutionPolicy Bypass -File $W plan  -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $W apply -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $W apply -Json 产出\日程清单.json -NoTiers   # 只写主条目
powershell -ExecutionPolicy Bypass -File $W list  -Days 60
powershell -ExecutionPolicy Bypass -File $W rm    -Anchor LR-MI-XXXXXXXX            # 预演
powershell -ExecutionPolicy Bypass -File $W rm    -Anchor LR-MI-XXXXXXXX -Apply     # 删除
powershell -ExecutionPolicy Bypass -File $W rm    -Prefix LR-MI-                    # 批量预演
```

输入清单与 `schedule_write.py` 完全相同，可直接复用同一份 `日程清单.json`。`plan` 与 `rm` 缺省只预演，`apply` 才落盘。

## 四、与 EventKit 后端的对应关系

| macOS（EventKit） | 本机日历（WinRT） |
|---|---|
| 日历事件 | 约会条目，开庭／期限／驻场／会议占用日历，待办标记为空闲 |
| 提醒事项里的各档位 | 各档位各写一条 15 分钟的空闲条目，标题带 `【T-7】`「【当天】」前缀 |
| 事件的提醒 | 主条目设「当天」档位提醒，档位条目本身不重复提醒 |

时间规则沿用原包：T-7／T-3／T-1 落当日 09:00，当天落 07:30，事件早于 07:30 时改为开始前 90 分钟，过期档位自动跳过。

## 五、锚点与安全

- 锚点算法与 `schedule_write.py` 逐字段一致：`kind|label|case_no|parties|title|iso(原始 start)` 取 SHA1 前 8 位大写，加前缀 `LR-MI-`；label 缺省按类型补全，时间按五种格式解析后标准化。两条通道对同一条日程得到同一锚点，混用不产生重复条目。
- 每条正文末行写「来福ID: 锚点」；写入前先按锚点查重，命中即更新，重复执行不新增。
- `rm` 只删除正文锚点匹配的条目；`-Anchor` 时连同同名档位（锚点 `-Tn`）一并删除；锚点格式非法直接拒绝。
- 缺省只预演；不触碰手工创建的事件。

## 六、已知限制

2. WinRT 接口对系统日历存储的写入权限随 Windows 版本变化，换机器后先跑一次 `doctor`。
3. 系统日历存储只支持每条一个提醒；多档位靠独立条目体现，且不占忙（`BusyStatus=Free`）。
4. 脚本是 UTF-8 with BOM。PowerShell 5.1 对无 BOM 的 `.ps1` 按 GBK 解析，中文会报语法错误；包内已带 BOM，构建脚本每次打包也会自动补，不要手工另存为「UTF-8 无 BOM」。

## 七、Windows 通道总览（五条）

| 通道 | 前置条件 | 读回与撤销 | 适合场景 |
|---|---|---|---|
| `.ics` 导出导入 | 无 | 在日历客户端里按「来福ID:」搜索删除 | 任意 Windows 环境，最通用；需人工一步导入，手机可直接打开加入 |
| `win_calendar.ps1` | 系统日历存储可写（跑 `doctor` 确认） | 自带 `list` 与 `rm -Anchor`，可读回、可撤销 | 结构化留痕与跨通道幂等校验；界面上看不到条目 |
| `calendar_feed.ps1`（本机日历订阅） | 回环服务与计划任务（`install` 注册） | `status` 查状态；改日程后重新 `publish` | 桌面日历客户端（Thunderbird 等）里看得见；只监听 127.0.0.1 |
| `dingtalk_remind.ps1`／`dws`（钉钉） | 自备钉钉机器人或组织账号 | `list`／`clear -Anchor` | 手机钉钉提醒与钉钉日历；**会出网**，涉密案件勿用 |


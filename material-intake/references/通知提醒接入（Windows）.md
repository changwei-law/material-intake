# 通知提醒接入（Windows，本地增补）

本文件说明 Windows 侧把日程清单的档位排成系统通知的后端 `scripts/win_remind.ps1`。本件为常威律师在 Windows 11 实机排查后新增，非原包内容。

## 一、解决什么问题

期限要真正"到点提醒"，必须有一条不依赖日历应用的通道。本机实测：

1. Windows 11 的任务栏日历弹窗只显示月历与通知中心，没有第三方日程列表区；写进系统日历存储的条目在那里看不到。
3. `win_calendar.ps1` 能把条目写进系统日历存储并可读回、可撤销，但该存储在系统界面上没有显示位置。

因此补第三块：`win_remind.ps1` 把各提醒档位直接排成 Windows 系统通知，到点由系统通知平台弹出，落在右下角通知区。

## 二、命令

```powershell
$R = "$SKILL\scripts\win_remind.ps1"   # $SKILL = 本技能目录

powershell -ExecutionPolicy Bypass -File $R doctor                  # 通知身份、开关、待发条数
powershell -ExecutionPolicy Bypass -File $R install                 # 注册通知身份（每台机器一次）
powershell -ExecutionPolicy Bypass -File $R selftest -DelaySeconds 40   # 排一条自检通知，确认真能弹
powershell -ExecutionPolicy Bypass -File $R plan  -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $R apply -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $R list
powershell -ExecutionPolicy Bypass -File $R clear -Anchor LR-MI-XXXXXXXX -Apply
powershell -ExecutionPolicy Bypass -File $R clear -Prefix LR-MI- -Apply
```

清单格式、锚点算法、档位规则与 `schedule_write.py`、`win_calendar.ps1` 完全一致，同一份 `日程清单.json` 三处通用。`plan` 与 `clear` 缺省只预演。

## 三、四个必踩的坑（均已实测）

   - 打开方式：`设置 → 系统 → 通知` 打开总开关，或运行 `win_remind.ps1 enable-notifications`。
   - 改注册表后**必须重启用户通知服务**（`WpnUserService_*`）才会生效；不重启，平台仍按旧状态拒收。
2. **通知身份要注册**。直接借用 PowerShell 自带的 AUMID 发送会被丢弃。`install` 会在开始菜单建一个带 `AppUserModelID` 的快捷方式（材料代办录入提醒），并写入 `HKCU\SOFTWARE\Classes\AppUserModelId`。卸载用 `uninstall`。
3. **定时通知不能排到过去的时间**。排到已过时点会抛异常，脚本对已过档位按"跳过"处理（与日历条目不同，日历可以补建过去的条目）。
4. **`.ps1` 必须带 UTF-8 BOM**，与包内其余 PowerShell 脚本一致。

## 四、怎么验证通知真的发出去了

`win_remind.ps1 selftest` 排一条 40 秒后的通知；之后除了肉眼看右下角，还可用系统通知历史库核对：

```powershell
Copy-Item "$env:LOCALAPPDATA\Microsoft\Windows\Notifications\wpndatabase.db*" <临时目录>
# 用 sqlite 打开副本，查 Notification 表最近几行的 HandlerId 与 ArrivalTime
```

注意该库是 **WAL 模式**，只拷主库文件会漏掉最近写入，必须把 `-wal`、`-shm` 一并拷走，否则会误判"没有投递"。

本工具的通知身份在历史库中的 `HandlerId` 对应 `NotificationHandler.PrimaryId = MaterialIntake.Reminder`。

## 五、与本机日历、`.ics` 的分工

| 通道 | 能做什么 | 不能做什么 |
|---|---|---|
| `win_remind.ps1` | 到点弹系统通知，落在右下角通知区，可列队、可按锚点撤销 | 不占日历；机器关机时不弹 |
| `win_calendar.ps1` | 写入系统日历存储，可读回、可撤销、可幂等更新 | 系统界面上没有显示位置 |

建议：材料里的期限三件事一起做——通知档位用本后端保证"到点弹"；需要进日历的用 `.ics`；系统日历存储作为结构化留痕。

## 六、已知限制

1. 关机或休眠期间到点不弹；开机后是否补弹由系统通知平台决定，不做保证。
2. 通知的显示受专注助手（免打扰）影响。
3. 通知身份是"桌面应用"类型，桌面上会留下一个开始菜单快捷方式；这是 Windows 允许非打包程序发通知的前提。
4. 提醒档位条目与日历条目共用 `LR-MI-` 锚点，撤销时按锚点精确匹配，不触碰其他应用的通知。

# 日历订阅与钉钉接入（Windows 专用）

本文件只涉及 Windows 侧的两条扩展通道：**本机日历订阅**与**钉钉提醒／日历**。macOS 侧不使用这两条，包内对应脚本在 macOS 上不参与运行。

## 一、先说清三件事（重要）

1. **这两条通道会改动系统或出网**，与前面几条通道不同：
   - 本机日历订阅：`install` 注册**开机自启计划任务**，并常驻一个**只监听 127.0.0.1 的本地 HTTP 服务**；
   - 钉钉通道：把日程内容**上传到钉钉服务器**，并注册到点触发的计划任务。
2. **钉钉通道涉密提示**：上传内容含日程标题与时间，而标题按本工作流的命名规则包含案号、法院、当事人（如`开庭｜（2026）浙0000民初000号·某某`）。涉密或不宜出网的案件，改用系统通知或 `.ics` 通道；必须走钉钉时先用代号命名。
3. **凭据不随包分发**：
   - 钉钉机器人 webhook 的 `access_token` 等于凭据，保存在 `%USERPROFILE%\.material-intake\dingtalk.json`；
   - 钉钉工作台 CLI 的登录凭据在 `%USERPROFILE%\.dws\`。
   - 两者都是用户级、本机保存；**不要写进文档、聊天或压缩包**。对外分发本技能包时不含这些凭据，接收方需自备授权。

## 二、本机日历订阅（`calendar_feed.ps1` + `serve_feed.py`）

把各任务 `产出\日程清单.ics` 合并成一份 `agenda.ics`，用 `http://127.0.0.1:8799/agenda.ics` 提供给桌面日历客户端（如 Thunderbird）订阅；日程更新后重新 `publish`，客户端按自己的刷新周期自动拉取。

```powershell
$F = "$SKILL\scripts\calendar_feed.ps1"
powershell -ExecutionPolicy Bypass -File $F status
powershell -ExecutionPolicy Bypass -File $F publish -Root "<任务根目录>"      # 合并并重建 agenda.ics
powershell -ExecutionPolicy Bypass -File $F install -Root "<任务根目录>"      # 注册开机自启 + 启动服务
powershell -ExecutionPolicy Bypass -File $F uninstall                        # 删任务 + 停服务
```

可选参数：`-Port`（默认 8799）、`-FeedDir`（默认 `%USERPROFILE%\.material-intake\calendar-feed`）、`-Python`（默认从 PATH 找）。

要点：

- 服务**只监听回环地址**，不对外网开放；`serve_feed.py` 会把客户端拉取记录写进订阅目录的 `访问日志.txt`。
- `install` 会注册名为「材料代办录入-日历订阅」的计划任务（登录时启动）；`uninstall` 可整条撤掉。
- 客户端侧订阅一次即可，之后由客户端按刷新周期自动拉取。

## 三、钉钉提醒（`dingtalk_remind.ps1`，自定义机器人）

把日程清单的各提醒档位注册成 Windows 计划任务，到点由本机向**钉钉自定义机器人**推送一条消息，手机钉钉即收到提醒。不需要公网地址，也不需要企业管理员——**但需要你所在的钉钉群允许添加机器人**：组织内通常要群主或管理员添加，组织若对群机器人做了安全设置限制还需管理员放行；自建组织（自己即主管理员）不受此限。走不通时改用系统通知或 `.ics`；涉密案件本就应避开钉钉。

```powershell
$D = "$SKILL\scripts\dingtalk_remind.ps1"
powershell -ExecutionPolicy Bypass -File $D config -Webhook "https://oapi.dingtalk.com/robot/send?access_token=***" [-Secret "SEC***"]
powershell -ExecutionPolicy Bypass -File $D test
powershell -ExecutionPolicy Bypass -File $D plan  -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $D apply -Json 产出\日程清单.json
powershell -ExecutionPolicy Bypass -File $D list
powershell -ExecutionPolicy Bypass -File $D clear -Anchor LR-MI-XXXXXXXX -Apply
```

要点：

- 走的是机器人 webhook，**不写钉钉日历**，只推消息到手机；要写钉钉日历与待办见第四节。
- 锚点与其它通道一致，`clear -Anchor` 按锚点撤销；`plan` 缺省只预演。
- 若机器人开了「加签」，`config` 时用 `-Secret` 存密钥，脚本会自动计算签名。

## 四、钉钉日历与待办（钉钉工作台 CLI，dws）

> **`dws`／`dws-core` 本体不随本包分发**：它是宿主自带的运行时（在千问办公／WorkBuddy 各自安装目录下，约 42 MB；千问办公侧为 `resources\bin\dws-core-windows-amd64.exe`）。接收方需具备其一——① 装有用 `dws` 的宿主；② 或自行安装：`npm i -g dingtalk-workspace-cli --registry=https://registry.npmmirror.com`（官方源在国内很慢）。装好后**自行完成一次钉钉授权**（`dws auth login`），凭据存本机 `%USERPROFILE%\.dws\`，多宿主共用。

需要把日程写进**钉钉自己的日历与待办**时，用钉钉工作台 CLI（WorkBuddy 侧为 `dws`，千问办公侧为内置 `dws-core`），两端共用同一份用户级凭据 `%USERPROFILE%\.dws\`：

```powershell
dws auth status                                        # 核对组织与用户
dws calendar +create --title "开庭｜…" --start "2026-09-30T15:30:00+08:00" --end "2026-09-30T17:30:00+08:00" --timezone "Asia/Shanghai" --location "…" --desc "…来福ID: LR-MI-…" --yes
dws todo +remind --task "【T-1】开庭｜…（来福ID: LR-MI-…-T1）" --at "2026-09-29T09:00:00+08:00" --yes
dws calendar +agenda --start "2026-09-30T00:00:00+08:00" --end "2026-10-01T00:00:00+08:00" --format json   # 写后读回核对
dws todo +get-my-tasks --format json
```

已知坑（实测记录，复用即可）：

1. `calendar +create` **写后读回会误报** `写后读回缺少字段 timeZone`（事件其实创建成功）；判定成功与否必须用 `calendar +agenda` 读回核对。
2. **非交互环境必须显式加 `--yes`**，连 `--dry-run` 也不例外，否则报 `confirmation_required`。
3. npm 官方源在国内很慢；安装 CLI 用 `--registry=https://registry.npmmirror.com`。
4. 需要**自己有权限的钉钉组织**：用他人组织（如所在单位）须**管理员放行**——管理员在管理后台把你配为具备开发者权限的子管理员，或你提交审批单由管理员批准；也可以**自建一个组织**（钉钉客户端 → 组织架构 → 创建或加入企业/团队），自己即主管理员，无需他人审批。多组织并存时用 `--profile` 指定。
5. 钉钉侧内容同样出网，涉密案件按第一节的提示处理。

## 五、Windows 通道总览（五条）

| 通道 | 到点提醒 | 日历可见 | 是否出网 | 需要人工 |
|---|---|---|---|---|
| 系统通知 `win_remind.ps1` | ✅ 右下角通知 | — | 否 | 不需要 |
| 本机日历订阅 `calendar_feed.ps1` | ✅ 由客户端提醒 | ✅ 电脑端日历 | 否（仅回环） | 每次 `publish`（可脚本化） |
| 钉钉提醒 `dingtalk_remind.ps1` | ✅ 手机钉钉 | — | **是** | 不需要 |
| 钉钉日历与待办（dws） | ✅ 钉钉待办 | ✅ 钉钉日历 | **是** | 不需要 |
| `.ics` 导入 | ✅ 由客户端提醒 | ✅ 任意客户端 | 否 | 需导入一次；手机可直接打开 |
| `win_calendar.ps1`（本机日历存储） | — | 界面上看不到 | 否 | 结构化留痕与跨通道幂等校验 |

选择建议：涉密案件走系统通知＋`.ics`；日常案件可用钉钉，方便手机提醒；需要电脑端日历界面时用本机日历订阅（Thunderbird 等）。

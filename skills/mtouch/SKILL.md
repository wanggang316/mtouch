---
name: mtouch
description: 用 mtouch 操作 macOS 应用——感知界面、执行动作、验证结果,并可留下可审计的执行证据。当任务需要驱动 GUI 应用(点击、输入、读取界面文字、跨应用搬运内容、UI 自动化测试)时使用。若 mtouch 尚未安装,本技能会引导完成安装与授权。
---

# mtouch：操作 macOS 应用

## Overview

mtouch 是一个 CLI，让 agent 通过 macOS 无障碍接口驱动任意应用。核心循环是
**感知 → 操作 → 验证**：`snapshot` 读出界面元素树，`act` 执行动作并**返回 AX diff
作为该动作自身的证据**，`wait` 提供显式的同步原语（任何地方都没有 `sleep`）。

本技能负责三件事：**确认可用**（未安装则引导安装、未授权则引导授权）、**加载权威用法**
（mtouch 自带的操作说明，随二进制更新，永不过时）、以及**任务编排与失败处置**。

具体命令语法不在本文件中重复——`mtouch <command> --help` 与二进制自带说明才是权威来源。

## When to Use

- 需要点击、输入、读取某个 macOS 应用的界面
- 跨应用搬运内容（读出一处、写入另一处）
- GUI 自动化测试，尤其是需要留下执行证据的场景
- 需要等待界面就绪或等待流式内容输出完毕

**不适用**：能用 API、命令行或直接读文件完成的事。驱动 GUI 永远是最后手段——更慢、更脆弱。
先问一句：这件事有没有非 GUI 的做法。

## Process

### Step 1：确认 mtouch 可用

```bash
command -v mtouch && mtouch doctor
```

按结果分支：

| 结果 | 处置 |
|---|---|
| 命令存在且 doctor exit 0 | 进入 Step 2 |
| 命令不存在 | 引导安装（下方） |
| doctor 报告缺少授权 | 引导授权（Step 2） |

**引导安装。** 优先 Homebrew：

```bash
brew install wanggang316/tap/mtouch
```

无 Homebrew 时用发布产物（Apple Silicon）：

```bash
VER=$(curl -fsSL https://api.github.com/repos/wanggang316/mtouch/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
curl -fsSL -O "https://github.com/wanggang316/mtouch/releases/download/${VER}/mtouch-${VER}-macos-arm64.tar.gz"
tar xzf "mtouch-${VER}-macos-arm64.tar.gz"
sudo cp "mtouch-${VER}-macos-arm64/mtouch" /usr/local/bin/
```

Intel 机器需从源码构建（`swift build`，需 Swift 6 / Xcode 16+）。

安装涉及改动用户系统，**动手前先说明你要装什么、装到哪里，并取得同意**。`sudo` 一步尤其如此。

### Step 2：确认授权

```bash
mtouch doctor
```

`Accessibility` 是**必需**授权；`screenshot` / `record` 另需 `Screen Recording`。

关键事实：**macOS 把授权绑定在"调用 mtouch 的那个终端程序"上,而不是 mtouch 本身。**
所以要在「系统设置 → 隐私与安全性 → 辅助功能」里勾选**你的终端**（Terminal、iTerm、
VS Code 等），不是找 mtouch。这一点几乎每个人第一次都会搞错。

授权需要用户在图形界面里操作,**你无法代劳**。给出确切路径,请用户完成后再继续,
然后用 `mtouch doctor` 复查。任何命令返回 **exit 2** 都意味着授权缺失。

### Step 3：加载权威用法

mtouch 把完整操作说明内嵌在二进制里，随版本更新：

```bash
mtouch init --client claude --print   # 打印它会做什么 + 完整说明，不做任何改动
```

`--print` 必须配合 `--client`（单独给 `--print` 是用法错误，exit 64）。上面这条会连同说明
全文一起渲染。注意 `--client mcp-json --print` 只输出 MCP 配置片段、**不含说明文本**；
想在不涉及任何客户端的前提下取说明，加 `--out`：

```bash
mtouch init --client mcp-json --print --out /dev/null   # 仍然什么都不写
```

若当前 agent 客户端支持 MCP，可一次性接入（10 个工具，输出与 CLI 逐字节一致）：

```bash
mtouch init --client claude
```

`mtouch init` 无参数时只列出选项、不改动任何东西；重复运行安全（已存在的注册会保留，
内容不同的会报告而非静默覆盖）。

具体某条命令的语法，永远查 `mtouch <command> --help`，不要凭记忆。

### Step 4：规划任务

动手前先定三件事：

**① 怎么定位元素。**

| 场景 | 用法 |
|---|---|
| 脚本化流程、元素特征已知 | `act ... --of '<criteria>'` —— 不需要快照，没有会失效的 ref |
| 元素可能还没出现 | 追加 `--wait <duration>` |
| 需要先看看界面长什么样 | `snapshot` 拿 ref，再 `act <ref>` |
| 应用的无障碍树不可用 | `act menu "File>Save"` 菜单路径 |
| 连菜单都没有 | `screenshot` 看图，坐标操作兜底 |

**② 怎么等待。** 绝不用 `sleep`。元素出现用 `--appears`；**内容还在流式输出或动画中用
`--stable`**——这条最容易被忘记，而漏掉它会让你拿到半截结果且**退出码仍是 0**。

**③ 怎么验证。** 在 mtouch 无法伪造的边界上验证。产出文件的任务就检查**磁盘上的文件内容**，
而不是只看 diff——diff 只能证明"请求发出了"。

### Step 5：执行并按退出码处置

每条命令都要**直接测退出码**：

```bash
mtouch act press --of 'button "Save"' --app <id>; echo $?
```

**绝不要用管道测**——`cmd | head` 返回的是 `head` 的状态，会把失败读成成功。

| 退出码 | 含义 | 处置 |
|---|---|---|
| 0 | 成功 | 检查返回的 diff 是否符合预期 |
| 1 | 运行失败 | 读诊断；**目标应用已死**时会明确提示重启 |
| 2 | 缺授权 | 回 Step 2 |
| 3 | ref 失效 | 重新 `snapshot` 再试，别盲目重试 |
| 4 | 等待超时 | 读诊断：是"从未出现"还是"匹配到多个"——两者的修正方向不同 |
| 5 | 安全输入激活 | 有密码框在前台；请用户处理 |
| 64 | 用法错误 | 你的调用写错了，诊断会指出具体问题 |

**诊断信息是给你读的控制信号,不是日志。** 它会告诉你看到了什么、下一步该跑什么命令。

**注意 diff 的可信度标记。** `verified: false`（未取 diff）、`deliveryConfirmed: false`
（投递未确认）、`settled: false`（界面仍在变化）——出现任一标记时，不要把 diff 当作事实，
重新 `snapshot` 读当前状态。

### Step 6：需要证据时

任务需要留痕（自动化测试、需要向人交代）时：

```bash
RUN=~/runs/<task>
mtouch record start --run-dir "$RUN" --max-duration 600s
MTOUCH_RUN_DIR=$RUN MTOUCH_RUN_CAPTURE=1 mtouch act ...   # 每步都带上
mtouch record stop --run-dir "$RUN"
mtouch report "$RUN"          # → report.html，离线可开
```

**证据包会录下屏幕上的一切**，且轨迹日志只在**失败**记录里脱敏——一次成功的
`act type <密码>` 是明文。要把证据包交给别人前，用 `mtouch report --redact`。

## 常见陷阱

- **同一 bundle id 有多个进程**（浏览器多 profile 等）→ mtouch 会拒绝并列出候选 pid，
  用 `--pid` 指定。不要以为它会自己挑对。
- **模态保存/打开对话框**会阻塞该应用的无障碍服务，`snapshot`/`act` 正确地拒绝执行。
  此时用 `act key --no-verify` / `act type --no-verify` 驱动，并**显式导航到目标目录**
  （`cmd+shift+g`），不要指望对话框记住的位置。
- **`(no changes)` 不等于失败**——无障碍树不可见的应用里，成功的动作也可能没有 diff。
  以退出码为准，并在真实边界上验证。
- **前台是共享资源**。多个流程同时驱动不同应用会互相抢焦点。能用 AX 通道
  （`set-value`、`act menu`）就别用键盘。
- **锁屏状态下行为不同**：至少有一个应用在锁屏时会让真实窗口在无障碍层不可达。

## Verification

- [ ] `mtouch doctor` 报告所需授权齐全（`screenshot`/`record` 才需要 Screen Recording）
- [ ] 每条命令的退出码是**直接**测的，不经管道
- [ ] 所有同步点都是显式 `wait`，没有 `sleep`
- [ ] 流式或动画内容用了 `--stable` 而非 `--appears`
- [ ] 结果在 mtouch 无法伪造的边界上验证过（文件内容、独立读回）
- [ ] 出现 `verified`/`deliveryConfirmed`/`settled` 标记时没有把 diff 当事实
- [ ] 若产出证据包且要外发，已按需 `--redact`

## 延伸

| | |
|---|---|
| `mtouch <command> --help` | 命令语法的权威来源 |
| `mtouch init --client claude --print` | 完整操作说明（内嵌于二进制，随版本更新） |
| [docs/agent-guide.md](../../docs/agent-guide.md) | 实战指南：驱动无障碍不可见的应用、应答模态面板 |
| [docs/platform-notes.md](../../docs/platform-notes.md) | macOS 行为的硬知识，每条都带实测数据 |

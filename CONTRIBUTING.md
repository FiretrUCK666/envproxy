# 贡献指南

欢迎提问题、报缺陷、改代码。先看你是哪一种：只想问个问题看第一节；想动手改看第三节。

## 提问与反馈

到仓库的 Issues 区提出：`https://github.com/FiretrUCK666/envproxy/issues`

为了让问题能被定位，请一并附上：

- 你用的版本（`git log -1 --format=%H` 的提交号，或“官网文件夹某月版本”）
- 运行环境（Windows 10/11 或 macOS 版本；翻墙软件名字）
- `4-查看状态` 的完整输出（`win`/`mac` 下同名文件，**原样粘贴，不要转述**）
- `monitor/monitor.log` 最近的相关行（只记状态变化，不含隐私）
- 最小复现步骤（如果问题能稳定重现）

请先搜索已有的 Issue，避免重复。

## 报告缺陷

一个可用的缺陷报告包含四件事：期望发生什么、实际发生什么、怎么复现、在什么环境上。

EnvProxy 特有的两条：如果问题只在“断开不断内核/节点抖动”时出现，把翻墙软件的
确切操作写出来（点的断开还是退的软件）；变量反复横跳类问题附上节点是否稳定的说明。
它往往就是根因所在（见 `README` 第六节）。

## 提出改动

1. 先开一个 Issue 说明你想改什么、为什么。涉及行为变化或新增依赖的，先在 Issue 里
   讨论清楚再动手，避免写完才发现方向不对。
2. 把仓库弄到你自己的账号下，在分支上开发：
   - **没有本仓库写权限**（大多数情况）：先 **fork** 一份到你自己的账号，克隆 fork
     出来的那份，在它上面开发；
   - **有写权限**（协作者）：直接从主干拉一个分支即可。
3. 跑完提交前门禁（见下），全绿再提交。
4. 提交拉取请求，说明改了什么、为什么、怎么验证的。

**不要往本仓库推主干，也不要打版本标签或发布制品**——那些由维护者执行。没有写权限时
你本来也推不动主干，但请注意别把改动提在自己的 fork 主干上就算了事：那样维护者看不到，
**必须开拉取请求**才会被处理。

## 开发环境

零依赖，不用安装任何东西：

```sh
# 获取代码
git clone https://github.com/FiretrUCK666/envproxy.git
cd envproxy

# 改完自检（与 CI 跑的是同一批）
bash -n mac/envproxy.sh mac/locator.sh mac/install.sh mac/stop.sh mac/uninstall.sh mac/status.sh mac/update.sh
```

`win\envproxy.ps1` 的语法检查在 Windows 本机用 PowerShell 语法解析跑（`Parser::ParseFile`，见 `AGENTS.md`
构建与验证节第 2 条）；改完 Windows 进 `win` 双击 `4-查看状态`、Mac 跑 `bash mac/status.sh` 确认行为。

## 提交前门禁

改完必须全绿才算完成。按顺序：

```sh
# sh 语法（macOS/Git-Bash；CI 同款）
bash -n mac/envproxy.sh mac/locator.sh mac/install.sh mac/stop.sh mac/uninstall.sh mac/status.sh mac/update.sh
# ps1 语法（Windows 本机 PowerShell；CI 同款）
# 状态冒烟：Windows 进 win 双击 4-查看状态（Mac 跑 bash mac/status.sh），输出与预期一致
# 核心改动追加：进 win 双击 1-安装 重载，看一轮状态翻转
```

这里的命令与 `AGENTS.md` 构建与验证节保持一致，改一处时同步另一处。

## 硬性规范

对贡献者同样成立的几条（**完整规范以 `AGENTS.md` 为准**）：

- `win\envproxy.ps1` 永远 UTF-8 **带 BOM** 保存，`mac\envproxy.sh` 永远 LF **无 BOM**保存，
  改一侧不许顺手“统一”另一侧；
- 只用系统自带命令，不引入 Python/Node/第三方模块；
- 不写死端口、进程名、路径，新增适配只向端口表/进程名特征追加；
- 包装壳（`.cmd`/`.command`/小 `.sh`）不许长逻辑；
- 提交信息与文档**不要使用 emoji**。

## 提交信息

一句话说明这次改了什么。中文或英文都可以，但**不要使用 emoji**。一次实质改动一个
提交，不要把无关改动混在一起。

## 许可

提交贡献即表示你同意以本项目的许可证发布你的贡献（见 `LICENSE`，MIT）。

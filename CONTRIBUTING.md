# 贡献指南

欢迎提问题、报缺陷、改代码。先看你是哪一种：只想问个问题看第一节；想动手改看第三节。

## 提问与反馈

到 [Issues](https://github.com/FiretrUCK666/envproxy/issues) 提出，请先搜索已有的 Issue，避免重复。

为了让问题能被定位，请一并附上：

- 你用的版本（打开菜单选"查看状态"，把里面"本地版本"那一行贴上来；也可以直接看根目录的 `VERSION` 文件）
- 运行环境（Windows 10/11 或 macOS 版本；翻墙软件名字）
- 菜单"查看状态"的完整输出（**原样粘贴，不要转述**）
- `monitor/monitor.log` 最近的相关行（只记状态变化，不含隐私）
- 最小复现步骤（如果问题能稳定重现）

## 报告缺陷

一个可用的缺陷报告包含四件事：期望发生什么、实际发生什么、怎么复现、在什么环境上。

EnvProxy 特有的两条：如果问题只在“断开不断内核/节点抖动”时出现，把翻墙软件的
确切操作写出来（点的断开还是退的软件）；变量反复横跳类问题附上节点是否稳定的说明。
它往往就是根因所在（见 `README` 第六节）。

## 提出改动

1. 先开一个 Issue 说明你想改什么、为什么。涉及行为变化或新增依赖的，先在 Issue 里
   讨论清楚再动手，避免写完才发现方向不对。
2. 在分支上改，然后开拉取请求：
   - **没有本仓库写权限**（大多数情况）：先 **fork** 到你自己的账号，克隆 fork 出来的
     那份，在分支上开发，推回你自己的 fork，再从那个分支开拉取请求；
   - **有写权限**（协作者）：直接从主干拉一个分支即可；
   - **只改文字**（错别字、文档表述）：在网页上点开文件、点铅笔图标改完提交即可，
     GitHub 会替你建好分支与拉取请求——这条路跑不了下面的提交前门禁，别用它改脚本。
3. 跑完提交前门禁（见下），全绿再提交。
4. 提交拉取请求，说明改了什么、为什么、怎么验证的。

第一次提拉取请求、或不确定 fork 怎么用，看 GitHub 官方的[参与项目](https://docs.github.com/zh/get-started/exploring-projects-on-github/contributing-to-a-project)
（复刻到拉取请求的完整步骤）。fork 落后于正本时，在自己 fork 的页面上点 **Sync fork**
更新即可。

**不要往本仓库推主干，也不要打版本标签或发布制品**——那些由维护者执行。没有写权限时
你本来也推不动主干，但请注意别把改动提在自己的 fork 主干上就算了事：那样维护者看不到，
**必须开拉取请求**才会被处理。

## 开发环境

零依赖，不用安装任何东西：

```sh
# 获取代码
git clone https://github.com/FiretrUCK666/envproxy.git
cd envproxy

# 改完自检（与 CI 同款；门禁的权威定义只有一处：.github/workflows/check.yml）
bash -n mac/*.sh mac/lib/*.sh
```

`win\` 下每个 `.ps1`（入口与 `lib\` 里的库）的语法检查在 Windows 本机用 PowerShell 语法解析跑
（`Parser::ParseFile`，见 `AGENTS.md` 的构建与验证节）；改完行为后 Windows 打开菜单选"查看状态"、
Mac 跑 `bash mac/envproxy.sh status` 确认。

**开发副本与安装包副本的区别**：对外分发的是安装包（Release 里的 `EnvProxy.zip`（Windows）/ `EnvProxy.tar.gz`（macOS），由 `git archive`
从标签产出，装什么由 `.gitattributes` 的 `export-ignore` 声明）。本仓库自带 `.git`，属于**开发副本**：
更新入口（菜单"检查更新" / `bash mac/envproxy.sh update`）认得这一点，只报版本、不改动任何文件，同步上游用
`git pull`。要验证更新逻辑，把安装包解压到别处当安装副本，在那里面点检查更新——不要指望在本仓库里
跑出覆盖效果，那是设计如此。

## 提交前门禁

改完必须全绿才算完成。按顺序：

```sh
# 门禁 1：sh 语法（CI 同款）
bash -n mac/*.sh mac/lib/*.sh
# 门禁 2：ps1 语法（本机 PowerShell 5.1；CI 在 ubuntu 用 pwsh 7、在 windows 用 5.1 各解析一遍）
# 门禁 10：功能自检（纯函数 + hook/归属/注入回收/快照，沙箱跑，不碰用户文件）
pwsh -NoProfile -File tests/test-win-pure.ps1
bash mac/envproxy.sh self-test
# 其余门禁见 .github/workflows/check.yml（权威定义只有那一处），
#   本地要单跑某一条，就把那一步的脚本原样粘进 PowerShell。
# 状态冒烟：Windows 打开菜单选"查看状态"（Mac 跑 bash mac/envproxy.sh status），输出与预期一致
# 核心改动追加：打开菜单选"安装 / 修复"重载，看一轮状态翻转
```

这里的说明与 `AGENTS.md` 构建与验证节指向同一处权威（`check.yml`）；门禁有增减时只改 CI 与 `AGENTS.md`，
本文件不复制门禁清单（上面那两行只是最常用的本地命令，不是门禁目录）。

## 硬性规范

对贡献者同样成立的几条（**完整规范以 `AGENTS.md` 为准**）：

- `win\` 下每个 `.ps1`（入口与 `lib\` 里的库）永远 UTF-8 **带 BOM** 保存，`mac\` 下每个 `.sh`
  永远 LF **无 BOM** 保存，改一侧不许顺手“统一”另一侧；
- 只用系统自带命令，不引入 Python/Node/第三方模块；
- 不写死端口、进程名、路径，新增适配只向端口表/进程名特征追加；
- 包装壳（`.cmd`/`.command`/小 `.sh`）不许长逻辑；
- 提交信息与文档**不要使用 emoji**。

## 提交信息

提交信息用英文 ASCII，一句话说明这次改了什么（避免中文经 shell）。一次实质改动一个
提交，不要把无关改动混在一起。

## 许可

提交贡献即表示你同意以本项目的许可证发布你的贡献（见 `LICENSE`，MIT）。

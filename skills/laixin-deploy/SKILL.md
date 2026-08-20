---
name: laixin-deploy
description: 来信平台生产发布卡——把 main 部署到 laixin.net.cn 生产服务器时使用。核心原则:部署失败与部署成功长得一模一样,每一步都要有能区分两者的判据。防已发生过的失败:生产陈旧 5 天无人发现、不推裸仓导致 deploy.sh 成功却零更新、以 root 跑 git 报 dubious ownership、拿 /healthz 200 当发布成功的判据。Use when the user asks to 更新服务器/发布/上线/部署/deploy 来信平台, or after a 片 merges and needs to reach production. 触发词:部署、发布、更新服务器、上线、deploy、生产、laixin.net.cn。
---

# 来信 · 生产发布卡

> **唯一原则:部署失败与部署成功,长得一模一样。**
> 服务照常 200、页面照常打开、日巡照常全绿 —— 这三件事在"部署成功"和"根本没部署上"两种情况下**完全一致**。⇒ **每一步都必须有能区分两者的判据**,⛔ 用"看起来正常"当判据。
>
> **本卡管命令、顺序、授权闸门**;**判据的理由与案底**在 `~/Obsidian/项目入口/来信平台/知识库/4-开发层/来信平台-运维手册.md` §四之二,**部署脚本细则**在仓库 `docs/deploy.md`。⛔ 三处互相复制正文,各引对方。

## 〇、授权:部署是**黄级**,⛔ 自动执行

阿里云项目 `AGENTS.md` 分级(绿=查状态自动做 / 黄=改动可逆先说再做 / 红=不做):
- **部署属黄级** ⇒ **动手前把「这次带多少变更 + 回滚代价」摆给创始人,得到明确「做」再动**;
- ⚠️ **「创始人问了一个问题」≠「授权执行」**;「更新一下服务器」是意向,**具体那一次动手仍要当次确认**;
- **执行主体已裁定**(阿里云 log 2026-08-14 决策3):**AI 窗口**经本机代理直连,⛔ 推给创始人手敲(他不熟服务器)。

## 一、连接(实测可用,2026-08-19 复验)

```bash
ssh -J wyinmac-vps-gateway -i ~/.ssh/aliyun-laixin-ed25519 root@121.196.192.44
```
- 安全组 22 只放行代理出口 `67.230.165.28`(即 `wyinmac-vps-gateway`)⇒ **必须走 `-J`**,直连会被挡;
- 主机密钥已在 `known_hosts`;非交互加 `-o BatchMode=yes -o ConnectTimeout=15`。

**生产事实**:阿里云 ECS `i-bp16su7e8xjslqjkhgk3`(杭州)· Ubuntu 24.04 · **Python 3.12.3**(验收环境必须同 minor)· SQLite · 代码 `/opt/laixin`(属主 `laixin`)· 服务 `laixin-api` / `laixin-web` / `caddy`。

## 二、⛔ 三个"看起来成功"的陷阱(全部实撞过)

1. **服务器 origin 不是 GitHub,是本机裸仓 `/srv/git/laixin.git`** —— `deploy.sh` 只做 `git fetch origin` + `git pull --ff-only` ⇒ **不先推,脚本会一路成功而什么都没更新**;
2. **`/opt/laixin` 属主是 `laixin`** —— 以 root 跑 `git -C /opt/laixin ...` **直接报错** `fatal: detected dubious ownership`。**所有 git 查询必须 `sudo -u laixin`**。⚠️ 反过来:**应用本身以 `laixin` 身份运行,所以它在启动时跑 git 是可行的**,别把 root 的限制外推到应用;
3. **`/healthz` 返回常量 `{"status":"ok"}`,`version` 硬编码** ⇒ **它只证明进程活着,⛔ 当发布成功的判据**。(发布指纹端点是已登记的工程候选;在它落地前,判据只能是第四节那两条外部命令。)

## 二之二、🔴 部署前置:生产配置校验(2026-08-19 实撞,**唯一真正拦住部署的东西**)

新代码在 `app/config.py` `validate_settings()` 里有**生产启动硬校验**,**任一条不满足,`deploy.sh` 在 [5/6] 迁移步直接 `RuntimeError` 停下**——⚠️ **这不是"灰度前置",是"部署前置"**:它拦的不是开张,是部署本身。

**⇒ 部署前先跑这一条**(切到目标 commit、装完后端依赖后,⛔ 等构建跑完才发现):
```bash
sudo -u laixin bash -c 'cd /opt/laixin; set -a; . /etc/laixin/laixin.env; set +a; .venv/bin/python -c "from app.config import settings; print(settings.manual_payment_guidance_state)"'
```
配置文件 `/etc/laixin/laixin.env`(root:laixin 0640,**两个服务都用它做 `EnvironmentFile`**)。改前先 `cp -a` 备份。
⚠️ **每次带新代码上线都可能新增校验项** —— 生产 env 是历史时刻写的,**新校验对它一律是"缺项"**。⇒ **凡跨多日的发布,把这一步当必做,别当例外。**

## 三、流程

### 前置(在本机)
1. **确认封版目标** —— 问 dispatch 要 main 的 hash,**记下来**(第四节要用);⛔ 凭印象;
2. **待合 0、无在飞片会改到本次射程** —— 问 dispatch,⛔ 自己猜;
3. **看这次带多少** —— `git log --oneline <生产HEAD>..main | wc -l` 与 `git diff --name-only <生产HEAD> main -- alembic/versions/`。**变更量与迁移数决定风险等级,也是给创始人的确认材料**;
4. **备份并验证可恢复** —— 部署方案 D6 把**恢复演练**列为硬判据。⛔ 跳过:10 个迁移一次跑而没有可回滚的备份 = 裸奔。**实测可用的一行**(SQLite 在线安全备份,⛔ 直接 `cp` 活库):
   ```bash
   sudo -u laixin sqlite3 /var/lib/laixin/laixin.db ".backup /var/backups/laixin/predeploy-<目标hash>.db"
   ```
   另有每小时 launchd 自动备份在 `/var/backups/laixin/`,但**部署前要自己打一份带目标 hash 的**——出事时你要知道"回到哪一版之前"。

5. ⚠️ **凡要改 `/etc/laixin/laixin.env`,先 `cp -a` 备份**(`laixin.env.bak-<时刻>`)。它是 root:laixin 0640、**两个服务共用的 `EnvironmentFile`**,写坏了两个服务一起起不来。

### 推代码
```bash
git push ssh://root@121.196.192.44/srv/git/laixin.git main   # 需经代理;裸仓属主与 push 身份不同时,服务器上先 git config --global --add safe.directory /srv/git/laixin.git
```

### 部署(在服务器)
```bash
sudo -u laixin /opt/laixin/deploy.sh
sudo systemctl restart caddy
```
脚本六步:校验 `/etc/laixin/laixin.env` → 拉码 → 后端依赖 → 前端依赖 → 前端构建 → 迁移 → 重启两服务。**任一步失败即停,不留半完成态。**

## 四、⭐ 验证(本卡存在的理由)

**⛔ 只看脚本退出码** —— "脚本跑完了" ≠ "服务换代了"。

```bash
sudo -u laixin git -C /opt/laixin rev-parse --short HEAD     # 必须 == 前置第1步记下的 hash
systemctl show laixin-api -p ActiveEnterTimestamp            # 必须晚于本次部署开始时刻
systemctl show laixin-web -p ActiveEnterTimestamp            # 同上
```

⚠️ **两条缺一不可,因为两种失败都表现为"一切正常"**:
- 只核 HEAD ⇒ **代码拉到了但服务没重启**(旧进程跑旧代码);
- 只核重启时刻 ⇒ **服务重启了但拉取失败**(重启的还是旧代码)。

**再加一条行为判据**:**走一次真正调后端的动作**(登录发码 / 加入 / 下单任一)。前两条证明"新代码在磁盘上且进程是新起的",**只有这条证明"站点真的能用"**。

> 🔴 **⛔ 用 `curl <首页> == 200` 当行为判据**(2026-08-19 实撞,代价=创始人替我发现):首页与登录页都是**静态渲染,根本不调 API**。那次部署三条判据**全绿**——HEAD 对、服务重启了、公网 200——**而站点是废的**:前端打包时 `NEXT_PUBLIC_API_URL` 未设,`api.ts` 逐字 `process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000"` ⇒ **浏览器去请求用户自己机器的 8000 端口**,任何后端动作都 `Failed to fetch`。
> ⚠️ **该缺陷自 2026-08-14 首次部署就存在,5 天无人发现——因为生产 `users=0`,从没有人真正用过。**「没人用」会让任何"可用性判据"都长期显绿。
> ⇒ **判据必须是端到端的**:`curl 200` 证明的是"Web 服务器活着",不是"应用能用"。**两者之间隔着整个前后端连接。**

> 📌 **配套前置(加进「二之二 部署前置」一起跑)**:构建期变量 `NEXT_PUBLIC_*` 是**编译进产物**的,改了必须**重新构建**才生效。部署后可直接验:
> ```bash
> grep -rl "localhost:8000" /opt/laixin/frontend/.next/static | wc -l   # 应 0
> grep -rl "laixin.net.cn" /opt/laixin/frontend/.next/static | wc -l    # 应 >0(对照组)
> ```

**若本次含对外承诺相关改动**:回运维手册 §一 值守表核对——**改了文案没改值守 = 承诺空转**。

## 五、回滚

**任一条判据不达标 ⇒ 先回滚,⛔ 在生产上现场调试**(违反运维手册 §四 变更纪律)。步骤见 `docs/deploy.md` §3;要点:
- 指定上一个**已验证**提交重发:`DEPLOY_REVISION=<hash> ./deploy.sh`;
- **迁移能否降级以该版本的 alembic `downgrade` 说明为准**,⛔ 猜降级命令;不确定就**先恢复数据库备份**;
- 回滚后**停在该已验证提交**,⛔ 紧接 `git switch main`(两服务 `Restart=always`,意外重启会重新加载工作区)。

## 六、已发生过的失败(照此避坑)

| 失败 | 教训 |
|---|---|
| **生产停在 08-14 首次部署,5 天没更新、367 个提交没上线,而没有任何人发现**(2026-08-19 核出) | 没有发布指纹时,"没部署上"**不会自己暴露**。⇒ 每次发布**必须留下 main hash 与部署时刻的记录**,下次核对有锚 |
| 第一版核对清单写 `git -C /opt/laixin rev-parse`,**以 root 跑必然报错** | 命令要在**真实身份下实跑过**再写进卡;"看起来对的命令"和"跑得通的命令"是两回事 |
| 第一版清单**漏了推裸仓这一步**,当时以为服务器拉 GitHub | ⛔ 用本机的 `git remote -v` 推断服务器的拉取源;**服务器的事实只能在服务器上测** |
| 把 root 的 `dubious ownership` 外推成"⛔ 依赖运行时有 git" | **一次观测的成立条件(身份=root),不能当所有身份的约束** |
| **`sudo -u laixin -E` 直接炸**:`-E` 保留 root 环境(含 `HOME=/root`),`npm ci` 写不进缓存目录而失败;⚠️ **而 `npm ci` 先删后装,失败即清空 `node_modules`** ⇒ 服务一重启就起不来 | 传变量用 `sudo -u laixin env VAR=x <cmd>`,**⛔ `-E`**。⚠️ 更通用的一条:**"失败了"和"失败并破坏了现场"是两回事**,先删后装的工具属后者,失败必须当场修复不能搁置 |
| **探针 `pgrep -f "deploy.sh"` 抓到自己的命令行**,误报"仍在跑"(同日三次) | 用 `pgrep -f "[d]eploy.sh"`;**凡按命令行文本找进程,先想自己算不算命中** |
| 🔴 **括号技巧也没防住(第二层,同日第四次)**:`until ! pgrep -f "/opt/laixin/[d]eploy.sh"` 的**同一条命令行里另有一段真实字符串** `nohup setsid sudo -u laixin /opt/laixin/deploy.sh` ⇒ **被自己的模式命中,循环永不退出**;部署 14:21 已完成,监控空转到 14:33 才被发现 | **括号技巧只防"模式字符串自身",防不了"同命令行的其他部分"**。⇒ 等待外部进程一律**⛔ 按命令行文本判**,改判**可靠信号**:①记下 PID 用 `kill -0 <pid>`;②让被等的进程**写完成标记**(`&& touch /tmp/done`),等标记文件;③用日志 mtime 停止增长 加 末行含完成词。**"进程还在不在"要问系统,别问文本。** |
| **运维手册日巡第 1 条 `https://laixin.net.cn/healthz` 从写下就不可能通过** —— Caddyfile 里根本没有 healthz 路由,公网访问恒 404(API 内网 `127.0.0.1:8000/healthz` 才是 200) | **判据写下时要真跑一次**;"看起来该有的路由"不等于配了 |
| 部署失败后留下 **磁盘=新代码、进程=旧代码** 的中间态,而两服务 `Restart=always` ⇒ **任何重启都会加载新代码并卡在同一校验上,站点挂掉** | **fail-stop 不等于 fail-safe**:脚本安全停下,现场仍可能是带雷的。⇒ 失败后**必须立刻决定"补配置往前"还是"回滚往后"**,⛔ 搁置 |

## 七、发布后

0. **V0.1 收尾项·ICP 备案状态核实(2026-08-20 方案窗口第十六任落,V0.1 封盘清单件;销号后本条转常规巡检语境)**:在**生产服务器上**跑 `curl -s -o /dev/null -w "%{http_code}" https://laixin.net.cn`,得 200 即销号并在部署记录里贴原始行。⚠️ 派工方本机侧已先测得 200,但那是**本机 curl 非服务器侧**(本机出网可能走专线,与大陆阻断判定不同源)⇒ 只作强旁证,**销号以服务器侧读数为准**;非 200 则按运维手册备案节处置并报创始人。
1. **记录**:本次 main hash、部署时刻、变更量与迁移数 —— 写进 `laixin-lane log`(窗口=方案窗口)与运维手册对应节;
2. **告知创始人可以开始走查/使用**,并把第四节第三条(手点一条本次改到的路径)的实测结果一并给他;
3. **发布后 24h 内**按运维手册 §二 日巡清单看一遍(卡单、待发验证码、待核验付款、工单)。

4. 🔴 **让用户强制刷新** —— 前端一旦重建,浏览器缓存里仍是旧 JS。**用户会继续看到和修复前一模一样的错误**,然后告诉你"还是不行"。⇒ 通知里必须带一句「**先 `Cmd+Shift+R` 强制刷新**」,否则你会去查一个已经修好的 bug。

5. **首次部署到空库后,还要跑一次 admin 引导**(`users=0` 时必做,否则**没有人能做付款核验**——那是走查第一单的硬闸门):
   ```bash
   sudo -u laixin bash -c 'cd /opt/laixin; set -a; . /etc/laixin/laixin.env; set +a; BOOTSTRAP_ADMIN_PHONE=<手机号> .venv/bin/python scripts/bootstrap_prod.py'
   ```
   它建轻账号+提 admin+建类目,**幂等**(回显 `account_created/admin_promoted/categories_created`)。

6. ⚠️ **手工验证码通道下,第一个人登不进去** —— `VERIFICATION_CHANNEL=manual` 时流程是「用户请求 → admin 后台看待发码 → 人工发」,而**第一个 admin 要登录才能看后台** ⇒ 死循环(且灰度前置明写"注册者不可自取核查",这是**有意设计**)。⇒ **由部署执行者从库里取**:
   ```bash
   sudo -u laixin sqlite3 -header -column /var/lib/laixin/laixin.db \
     "select manual_code, purpose, datetime(expires_at) from verification_codes where phone='<号>' order by created_at desc limit 1;"
   ```
   ⚠️ **有效期约 5 分钟**,取到立刻给。**表里 0 行 = 请求根本没到后端**,别去猜码,去查前端(见第四节那条 `NEXT_PUBLIC_API_URL`)。

## 八、正常耗时基线(**知道正常值才能识别异常**)

| 动作 | 实测 |
|---|---|
| 全量部署(新代码,370 提交规模) | **~44 秒** |
| 回滚到旧版(小得多的代码) | **~33 秒** |
| 仅前端重建(改 `NEXT_PUBLIC_*` 后) | **~40 秒** |

⇒ **超过 2 分钟没动静,先怀疑自己的监控,别怀疑部署。** 本卡记录的那次"卡 13 分钟",部署其实 38 秒就完了,卡住的是探针(见第六节 `pgrep` 两条)。**判断卡没卡用日志 mtime,⛔ 用进程存在性。**

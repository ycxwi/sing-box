# sing-box（零配置构建）

基于 [sing-box](https://github.com/SagerNet/sing-box) v1.14.4 的构建，增加**零配置启动模式**：
一条命令拉起 TUIC + mTLS + 自动证书（ACME）服务，不用手写配置文件。

## 一键安装

### 带参数（非交互）

```sh
curl -fsSL https://raw.githubusercontent.com/ycxwi/sing-box/main/install.sh | sudo sh -s <domain> [port]
```

### 不带参数（首次交互询问域名/端口）

```sh
curl -fsSL -o /tmp/sing-box-install.sh https://raw.githubusercontent.com/ycxwi/sing-box/main/install.sh && sudo sh /tmp/sing-box-install.sh
```

安装完成后会把终端交给 `sing-box`，由它依次询问 `Domain` 与 `Port`。

> 为甚么交互用法不能管道？`curl | sh` 时脚本的 stdin 是管道，交互提问会拿不到终端输入。所以无参用法必须先把脚本存成文件再执行（上面这条已经这样做了）。

### 仓库内直跑

```sh
sudo sh install.sh            # 交互询问
sudo sh install.sh <domain> [port]   # 参数直给
```

| 参数 | 说明 |
|---|---|
| `<domain>` | 必填。需解析到本机，且 **TCP 80** 可达（ACME HTTP-01 验证） |
| `[port]` | 可选，默认 `443`。TUIC 入口端口（UDP） |

安装器会：下载预编译二进制 → 校验 gzip 完整性 → 装到 `/usr/local/bin/sing-box` → 生成配置 → 注册并启动 systemd 服务。

## 使用

### 首次启动（无参数 → 交互询问）

```sh
sudo sing-box
```

依次询问 `Domain` 与 `Port`（默认 443）。

### 带参数（创建 / 覆盖域名与端口）

```sh
sudo sing-box <domain> [port]
```

覆盖时**保留 uuid 与客户端 CA**，只改域名/端口——已分发的客户端证书继续有效。

### 再次无参数（复用既有配置）

```sh
sudo sing-box
```

### 四种组合

| 场景 | 命令 | 行为 |
|---|---|---|
| 首次 + 无参 | `sing-box` | 交互询问域名/端口，生成配置与客户端 CA |
| 首次 + 有参 | `sing-box <domain> <port>` | 直接用参数生成 |
| 非首次 + 无参 | `sing-box` | 复用已有配置 |
| 非首次 + 有参 | `sing-box <domain> <port>` | 覆盖域名/端口（uuid 与 CA 不变） |

## 服务管理

首次执行会安装并启用 systemd 服务 `sing-box-quick`（开机自启 + 崩溃自动重启）。

```sh
systemctl status sing-box-quick
journalctl -u sing-box-quick -f
systemctl stop sing-box-quick
systemctl start sing-box-quick
```

## 客户端（OpenWrt / iStoreOS 软路由）

### 一键安装

```sh
curl -fsSL -o /tmp/sing-box-client.sh https://raw.githubusercontent.com/ycxwi/sing-box/main/client-install.sh
sudo sh /tmp/sing-box-client.sh <server> <port> <uuid> <password> <cert> <key> [socks-port] [server-name]
```

| 参数 | 说明 |
|---|---|
| `<server>` | 服务端地址（域名或 IP；连 IP 时用下面的 `server-name` 提供证书域名） |
| `<port>` | 服务端 TUIC 端口（UDP） |
| `<uuid>` / `<password>` | 服务端首次启动打印的值 |
| `<cert>` / `<key>` | 客户端证书与私钥（从服务端 `/etc/sing-box/client.pem` / `client.key` 拷来） |
| `[socks-port]` | 本节点 socks5 端口；省略 = 自动分配（从 `1081` 起取首个空闲） |
| `[server-name]` | TLS SNI / 证书校验名，默认 = `server`。服务端证书签给域名时必须填域名 |

安装结果：二进制 `/usr/bin/sbox-client`（**静态编译，musl libc 可用**）、节点配置 `/etc/sbox-client/nodes/<name>.json`（+ 同名 `.pem`/`.key`）、procd 服务 `sbox-client`（开机自启，每个节点一个实例）、socks5 监听 `127.0.0.1:<socks-port>`。

> 软路由是 musl libc，**必须用静态版二进制**（`sing-box-linux-amd64-static.gz`）。安装器已自动选择，无需手动指定。

> 服务托管依赖 procd，仅 OpenWrt/iStoreOS 具备。其它发行版（Debian/Ubuntu 等）上脚本会显式跳过托管并打印手动启动命令（`sbox-client run -c /etc/sbox-client/nodes/<name>.json`），不会另写 systemd 单元。

### 离线安装（软路由无外网时）

```sh
# 在能上网的机器上取静态二进制，拷到路由器
scp sing-box-linux-amd64-static.gz root@<router>:/tmp/
ssh root@<router> 'gunzip -c /tmp/sing-box-linux-amd64-static.gz > /tmp/sbox-static'
# 用 SB_BINARY 跳过下载
ssh root@<router> 'SB_BINARY=/tmp/sbox-static sh /tmp/sing-box-client.sh <server> <port> <uuid> <password> <cert> <key> 1081'
```

### 接入 PassWall2

客户端只出 socks5，由 PassWall2 消费：

| 字段 | 值 |
|---|---|
| 节点类型 | Socks |
| 地址 | `127.0.0.1` |
| 端口 | 该节点的 `<socks-port>` |

然后把该节点设为**分流组的默认出口**（不要改全局节点，否则会连带切断本机对外访问）。

### 多节点

再加一个节点 = 再跑一次安装器（换一份证书与参数），已有节点不受影响：

```sh
# 有参方式：第二个节点
sudo sh client-install.sh <server2> <port2> <uuid2> <password2> client2.pem client2.key 1082 <domain2>

# 或者用第二份一次性包（无参方式，端口自动分配）
cd /tmp/certs2 && sudo sh client-install.sh
```

| 行为 | 说明 |
|---|---|
| 节点名 | 域名里的非字母数字换成下划线（`tok.example.com` → `tok_example_com`） |
| 端口分配 | 自动从 `1081` 起取首个空闲；显式传端口则校验不与其它节点冲突 |
| 同名重装 | 视为更新该节点，沿用原端口，其它节点不受影响 |
| 删除节点 | 删掉 `nodes/<name>.json/.pem/.key` 后 `/etc/init.d/sbox-client restart` |
| 进程模型 | 每个节点一个独立 sing-box 进程（procd 多实例），互不影响 |

PassWall2 里每个节点各建一个 Socks 节点（端口对应），在分流组里选用哪个。

> 每个节点的证书只对**签发它的那台服务器**有效（各服务器 CA 独立）。换服务器要拿对应该服务器的包，不能拿 A 的证书连 B。

### 节点管理页（LuCI）

软路由上可加一个 LuCI 页统一管理节点（独立小应用，**不改 PassWall2**）：

```sh
scp -r luci/controller/sbox.lua root@<router>:/usr/lib/lua/luci/controller/
scp -r luci/view/sbox/nodes.htm root@<router>:/usr/lib/lua/luci/view/sbox/
scp client-install.sh root@<router>:/usr/bin/sbox-client-install
ssh root@<router> 'chmod 755 /usr/lib/lua/luci/controller/sbox.lua /usr/bin/sbox-client-install; rm -f /tmp/luci-indexcache*; /etc/init.d/uhttpd restart'
```

入口：**服务 → Sing-Box 节点**

| 能力 | 说明 |
|---|---|
| 列表 | 读 `/etc/sbox-client/nodes/*.json`，显示域名/远端端口/socks 端口/在线状态（判据=该 socks 端口在 `/proc/net/tcp` 处于 LISTEN） |
| 新增 | 上传一次性包的三件（`client.json`/`client.pem`/`client.key`），复用 `client-install.sh`，自动分配端口 |
| 删除 | 删 `nodes/<name>.*` 并重启服务 |
| 从链接安装 | 把服务端打印的一次性链接粘进来，路由器自己下载+解包+安装（见下） |
| 同步 | 增删时自动维护 PassWall2 的 socks 节点（`remarks = sbox-<name>`），不用手填 |
| 启停 | 按节点手动禁用/启用：禁用后该节点进程停止、socks 端口释放，其余节点照常跑 |

> 页面需要 LuCI 登录（同源 session），不提供任何免登录入口。

手动启停的实现：禁用 = 在 `/etc/sbox-client/disabled/<name>` 建一个空标记文件，然后 `restart`；init 脚本扫 `nodes/*.json` 时跳过有标记的节点，procd 就不再为它建实例。启用 = 删标记再 `restart`。
不改 json 是因为 sing-box 对配置字段是严格解析，未知字段会直接报错。

> `restart` 会重建全部实例（其余节点中断 1-2 秒）。禁用的节点在 PassWall2 里那条 socks 节点仍然存在，选它会连不通——这是预期：停用的节点本就不该被选中。

安装链接从哪来：

| 场景 | 获取方式 | 输出 |
|---|---|---|
| 首次安装完成 | 证书签好（约 10s）后看日志或文件：`journalctl -u sing-box-quick \| grep install link` 或 `cat /etc/sing-box/install-url.txt` | `https://<domain>:8000/<token>` |
| 给新设备签发 | 服务端 `sudo sh sign-client.sh` | 同上，外加证书信息与参数 |

链接特性：HTTPS、30 分钟内有效、**只能下一次**（首次下载后文件即删）。路由器侧只接受 `https://` 开头的链接，字符白名单校验后再拼命令。

### 客户端证书从哪来

服务端首次启动会在 `/etc/sing-box/client.pem` 与 `client.key` 生成首张客户端证书：

```sh
scp root@<server>:/etc/sing-box/client.pem /tmp/
scp root@<server>:/etc/sing-box/client.key /tmp/
scp /tmp/client.pem root@<router>:/tmp/
scp /tmp/client.key root@<router>:/tmp/
```

**加设备**：在**服务端**直接跑签发脚本（无参数，自动命名与落盘）：

```sh
sudo sh sign-client.sh
```

输出到 `/etc/sing-box/clients/client-<时间戳>.pem` + `.key`，并打印两种交付方式：

| 方式 | 说明 |
|---|---|
| **一次性 HTTPS 下载** | `https://<server-domain>:8000/<token>` — 30 分内有效、**只能下一次**、下载即删；走 ACME 同一张真证书，私钥不经明文链路 |
| scp | 传统方式，走 SSH 加密链路 |

设备侧（包内已带初始化参数，**无需再传参**）：

```sh
curl -fsS -o /tmp/c.tgz <一次性URL>
mkdir -p /tmp/certs && tar xzf /tmp/c.tgz -C /tmp/certs
cd /tmp/certs && sudo sh client-install.sh      # 无参：直接读同目录 client.json
```

包内容固定为三件：

| 文件 | 说明 |
|---|---|
| `client.pem` | 客户端证书 |
| `client.key` | 客户端私钥 |
| **`client.json`** | **完整客户端配置：server/port/uuid/password + 证书路径**（`/etc/sbox-client/`） |

> 分发服务只在服务端以 systemd 服务运行时启动（监听 `:8000` HTTPS，端口可用 `SING_BOX_CERT_PORT` 覆盖、TTL 可用 `SING_BOX_CERT_TTL` 覆盖）。它只响应存在且未过期的 token，成功发送后立即删除文件。同名（同一秒）重复签会被拒绝，避免覆盖已分发证书。

### 客户端管理

```sh
/etc/init.d/sbox-client status
/etc/init.d/sbox-client restart
logread -f | grep sbox-client
```

## 客户端配置

服务启动后终端会打印客户端参数：

```text
server=<domain>  port=<port>  uuid=<uuid>  password=<password>
alpn=h3   tls.server_name=<domain>
client_certificate=/etc/sing-box/client.pem
client_key=/etc/sing-box/client.key
```

客户端需支持 **TUIC v5 + mTLS**（sing-box / mihomo 等均可）。

**加设备**：用同一个 CA（`/etc/sing-box/client-ca.pem` + `client-ca.key`）再签一张客户端证书即可，服务端无需改动。

## 文件布局

| 路径 | 内容 |
|---|---|
| `/etc/sing-box/config.json` | 生成的运行配置 |
| `/etc/sing-box/quick-state.json` | 域名 / 端口 / uuid / password |
| `/etc/sing-box/client-ca.pem` `.key` | 客户端 CA（签发新设备用，**私钥注意保管**） |
| `/etc/sing-box/client.pem` `.key` | 首张客户端证书 |
| `/etc/sing-box/acme/` | ACME 证书缓存（自动续期） |
| `/etc/systemd/system/sing-box-quick.service` | systemd 服务 |

## 安全边界

- **入站只有一个**：TUIC @ 指定端口（默认 UDP 443），不启任何其它入站
- **认证**：uuid + password **且强制客户端证书**（mTLS `require-and-verify`）
- **证书**：ACME 自动申请与续期；HTTP-01 与 TLS-ALPN-01 两种挑战同时登记，由 CA 按可达性选择
- **无兜底逻辑**：配置错误、证书申请失败、服务安装失败一律显式报错退出

## 与上游的关系

本仓是 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) v1.14.4（上游 commit `c005f35`）的副本，只改两处：

- 新增 `cmd/sing-box/cmd_quick.go` —— 零配置模式（交互/参数、配置生成、CA 与客户端证书、systemd 服务安装）
- `cmd/sing-box/cmd.go` —— 给 root command 挂 `Args: MaximumNArgs(2)` 与 `RunE: runQuickStart`

其余代码与上游一致。License 同上游（GPL-3.0）。
# sing-box（零配置构建）

基于 [sing-box](https://github.com/SagerNet/sing-box) v1.14.4 的构建，增加**零配置启动模式**：
一条命令拉起 TUIC + mTLS + 自动证书（ACME）服务，不用手写配置文件。

## 一键安装

```sh
curl -fsSL https://raw.githubusercontent.com/ycxwi/sing-box/main/install.sh | sudo sh -s <domain> [port]
```

在仓库目录内等价于：

```sh
sudo sh install.sh <domain> [port]
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
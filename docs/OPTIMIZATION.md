# Mihomo 内核评估与优化路线图

> **文档性质**：Living document（持续更新）
> **评估基线**：`Alpha` `b6a15182`（2026-10-26）；稳定参考 `Meta` v1.19.33（`3f27ef39`，2026-10-21）
> **最近更新**：2026-10-26
> **适用范围**：`Meta` / `Alpha` 分支的代理内核；不包含 `main` 分支的星穹铁道 Python 模型
> **维护方式**：见文末「维护指南」。行号基于评估基线，后续提交后可能偏移。

## 目录

- [0. 阅读前须知](#0-阅读前须知)
- [1. 项目现状](#1-项目现状)
- [2. 与主流内核对比](#2-与主流内核对比)
- [3. 优化清单](#3-优化清单)
- [4. 路线图](#4-路线图)
- [5. 验证与基准](#5-验证与基准)
- [6. 已修复问题记录](#6-已修复问题记录)
- [7. 参考](#7-参考)
- [8. 维护指南](#8-维护指南)

---

## 0. 阅读前须知

### 0.1 分支说明

这个仓库的默认分支 `main` 是星穹铁道的 Python Pydantic 模型（最后提交 2025-02），而代理内核代码位于：

- `Meta`：稳定分支，当前 v1.19.33
- `Alpha`：开发分支，当前 `b6a15182`（2026-10-26），更新更快
- `main`：与代理内核无关，不要用 `main` 的代码年龄判断内核年龄

### 0.2 结论摘要

- mihomo **不是**“好几年前的老项目”。代理内核近一年有约 780 次提交，协议覆盖和 GUI 生态仍然很强。
- 真正的技术债是 **Clash 时代架构**：全局单例、YAML 配置、线性规则引擎、庞大的兼容层。
- 最值得优先投入的不是继续加协议，而是：
  1. **安全升级**（Go/x-net/x-text 漏洞）
  2. **并发正确性**（HealthCheck 数据竞争）
  3. **日志/可观测性**
  4. **规则匹配缓存与 DNS 热路径**
- 不建议整体重写。mihomo 的护城河是 Clash 兼容性和生态，重写会丢掉这些优势。

---

## 1. 项目现状

### 1.1 版本与活跃度

| 指标 | 数值 |
|---|---|
| 评估基线 | `Alpha` `b6a15182`（2026-10-26） |
| `Meta` 版本 | v1.19.33（2026-10-21） |
| 近一年 `Meta` 提交数 | 约 778 |
| 近一年 `Alpha` 提交数 | 约 786 |
| Go 文件数 | 984 |
| Go 代码行数 | 约 16.8 万（非测试 13.3 万，测试 3.5 万） |
| 依赖模块数 | 178 |
| 包数量 | 186 |
| 测试文件数 | 127 |

### 1.2 优势

1. **协议覆盖极广**：SS/SS2022、SSR、VMess、VLESS、Reality、Trojan、Snell、TUIC v4/v5、Hysteria/Hysteria2、AnyTLS、ShadowTLS、ShadowQUIC、WireGuard、Tailscale、ZeroTier、EasyTier、OpenVPN、SSH、Mieru、Sudoku、TrustTunnel、MASQUE、XHTTP 等。
2. **Clash 生态是护城河**：YAML 订阅、`proxy-providers`、`rule-providers`、Clash API、Dashboard，以及 Clash Verge Rev、Mihomo Party、FlClash、CMFA 等客户端。
3. **TUN 并不落后**：底层使用 `sing-tun`，支持 gvisor/system/mixed/mips、GSO；最近把默认 TUN 栈切到 mips。
4. **DNS 能力已经较完整**：DoH/DoT/DoQ、ECS、fake-ip、`respect-rules`、`nameserver-policy` 都有。
5. **性能基础设施不错**：自定义 `xsync`、`atomic`、buffer pool、succinct trie、ARC/LRU 缓存，说明作者对性能有持续投入。

### 1.3 短板

1. **安全维护被 Go 1.20 兼容策略锁死**（最严重）。
2. **并发正确性有隐患**：HealthCheck 存在已确认的数据竞争。
3. **可观测性弱**：只有 JSON API 和 debug pprof，没有 Prometheus/OpenTelemetry。
4. **核心路径测试覆盖低**：`adapter`、`dns`、`tunnel`、`rules` 主包覆盖率为 0%。
5. **架构偏单体**：全局 `tunnel` 状态、线性规则扫描、超大配置文件，长期维护成本高。

---

## 2. 与主流内核对比

| 维度 | mihomo | sing-box | Xray-core | dae |
|---|---|---|---|---|
| 定位 | Clash 兼容内核 + GUI 生态 | 通用代理平台 | 协议/传输创新，服务端强 | Linux eBPF 透明代理 |
| 配置 | YAML（Clash 格式） | JSON | JSON | dae 语法 |
| 协议广度 | 极广 | 广 | VLESS/XTLS/Reality/XHTTP 强 | 主流协议 |
| DNS | fake-ip/redir-host、DoH/DoT/DoQ、ECS、respect-rules | 独立 DNS 路由、DoH/DoT/DoQ/HTTP3、optimistic cache、strategy 更细 | DNS 分流 | 高级 DNS |
| TUN/数据面 | sing-tun、多栈、GSO | sing-tun 新栈、auto_redirect、multi-queue | TUN | eBPF，直接绕过代理进程 |
| 可观测性 | JSON API + pprof | Clash API / V2Ray API | stats API | 有限 |
| 生态 | Clash Verge / Party / FlClash / CMFA | 官方客户端 / NekoBox / Hiddify | v2rayN / Happ 等 | 较小 |
| 适合 | 桌面、客户端、机场订阅 | 服务端、新协议、复杂 DNS | 服务端、抗封锁 | Linux 软路由 |

### 2.1 对比结论

- **sing-box**：架构更现代，DNS 规则和 `auto_redirect` 更强，配置 JSON 更严格；但配置变动频繁，Clash 生态不如 mihomo。
- **Xray-core**：Reality/XTLS/XHTTP 等协议和传输创新领先，服务端生态强；客户端/订阅生态不如 mihomo。
- **dae**：Linux eBPF 数据面性能最好，适合纯 Linux 网关；跨平台和 GUI 生态弱。
- **mihomo**：赢在 Clash 兼容性、订阅/规则/Provider 生态和 GUI 覆盖；性能和架构不是第一，但足够用。

### 2.2 常见误区

- “mihomo 不支持 DoQ”：本仓库有 `dns/doq.go`，已支持。
- “两者性能差一倍”：第三方测试给出的量级通常是 sing-box 吞吐高 10–20%、内存低 30–50%，且测试条件有限；两者都使用 `sing-tun`，普通家庭带宽下差距不明显。
- “main 分支是内核”：`main` 是 HSR Python 模型，代理代码在 `Meta`/`Alpha`。

---

## 3. 优化清单

状态说明：

- `TODO`：待处理
- `DOING`：进行中
- `DONE`：已完成
- `WONTFIX`：评估后不做

### P0：安全

#### SEC-01 Go 1.20 兼容策略阻塞安全升级

**现状**

- `go.mod:3` 为 `go 1.20`
- 锁定 `golang.org/x/net v0.35.0`、`golang.org/x/text v0.22.0`、`golang.org/x/crypto v0.33.0`
- `govulncheck ./...` 报告 13 个可达漏洞

**关键漏洞示例**

| 漏洞 | 模块 | 当前版本 | 修复版本 | 说明 |
|---|---|---|---|---|
| GO-2025-3503 | x/net | v0.35.0 | v0.36.0 | HTTP Proxy IPv6 Zone ID 绕过 |
| GO-2026-4918 | x/net | v0.35.0 | v0.53.0 | HTTP/2 无限循环 |
| GO-2026-5026 | x/net | v0.35.0 | v0.55.0 | IDNA Punycode 校验问题 |
| GO-2026-5970 | x/text | v0.22.0 | v0.39.0 | 无效输入导致无限循环 |
| GO-2026-6617/6603/6610/6611/6612 | x/net | v0.35.0 | v0.60.0 | HTTP/2 崩溃、内存耗尽、CPU 消耗等 |
| stdlib（Go 1.26.8） | stdlib | 1.26.8 | 1.26.9 / 1.26.10 | 以实际构建工具链为准 |

> 修复版本要求 Go 1.23/1.25/1.26.9+，因此 **Go 1.20 兼容策略是根因**。

**影响**

- 使用旧工具链构建的二进制会暴露已知漏洞。
- 无法直接升级到安全版本，形成长期安全债。

**建议**

1. 发布构建统一使用 **Go 1.26.10+**。
2. 将 Windows 7/老 macOS 构建拆到独立 `legacy` 分支或独立通道，不要阻塞主分支。
3. CI 增加 `govulncheck` 和依赖更新机器人（Dependabot/Renovate）。
4. 短期先升级到 Go 1.20 能用的最高安全版本，并评估剩余风险。

**验收标准**

- `govulncheck ./...` 无 reachable vulnerability（或仅剩有明确缓解说明的条目）。
- 发布二进制使用最新 Go patch 构建。

**状态**：`TODO`

---

#### SEC-02 内核自更新没有校验和/签名

**现状**

`component/updater/update_core.go`：

- `:199` `download()` 下载新内核
- `:236` 直接写入文件
- 之后替换可执行文件并重启

全程只依赖 HTTPS，没有校验 `checksums.txt` 或 cosign 签名。

**影响**

- GitHub 账号/发布资产被攻破时，可下发任意可执行文件。
- 中间人攻击需要有效证书，但供应链风险仍然存在。

**建议**

1. 下载后校验发布资产中的 `checksums.txt`（SHA256）。
2. 有条件时增加 cosign/SLSA 验证。
3. 校验失败时拒绝更新并记录错误。

**验收标准**

- 篡改后的包会被拒绝。
- 更新流程有校验失败的单测。

**状态**：`TODO`

---

#### SEC-03 External Controller 的 secret 是可选的

**现状**

`hub/route/server.go:120`：

```go
if secret != "" {
    r.Use(authentication(secret))
}
```

默认 controller 为空（不监听）是安全的；但用户写成 `0.0.0.0:9090` 且不设 secret 时完全暴露。

**建议**

1. 监听非 loopback 地址时强制要求 secret，或至少打印醒目 warning。
2. 文档中明确“不要在没有 secret 的情况下暴露 controller”。
3. 可选：首次启动自动生成随机 secret 并写入配置。

**验收标准**

- 非 loopback + 空 secret 时启动日志有明确警告或直接拒绝。
- 文档更新。

**状态**：`TODO`

---

### P1：正确性与性能

#### COR-01 HealthCheck 存在数据竞争（已复现）

**现状**

`adapter/provider/healthcheck.go`：

- `setProxies()` 直接写 `hc.proxies`（第 64–65 行）
- `check()` 并发读 `hc.proxies`（第 123–124、171 行）
- `extra` map 在 `registerHealthCheckTask()` 中加锁写，但 `check()` 第 139 行无锁读

临时并发测试运行 `go test -race` 输出：

```text
WARNING: DATA RACE
Write at ... healthcheck.go:65
Previous read at ... healthcheck.go:124
```

**影响**

- 数据竞争可能导致读到不一致的 slice header。
- 极端情况下触发 concurrent map read/write panic。
- `-race` 下测试不稳定。

**建议**

1. 用 `RWMutex` 保护 `proxies`、`extra`、`interval`。
2. 或在 `check()` 开头对 `proxies`/`extra` 做快照，后续只读快照。
3. 为 HealthCheck 增加长期保留的并发测试。

**验收标准**

- 并发 `setProxies` + `check` 在 `-race` 下无告警。
- 健康检查行为不变。

**状态**：`TODO`

---

#### PERF-01 `GroupBase.URLTest` 对每个节点无限制起 goroutine

**现状**

`adapter/outboundgroup/groupbase.go:237-257`：

- 每个 proxy 一个 goroutine
- 没有并发上限

`HealthCheck` 已经使用 `errgroup.SetLimit(10)`（`adapter/provider/healthcheck.go:132`）。

**影响**

- 500+ 节点时一次“测试全部”会同时发起几百个连接。
- 容易打满 socket、拉高 CPU，延迟结果互相干扰。

**建议**

1. 复用 `errgroup.SetLimit(10)` 或可配置工作池。
2. 限制值可按 `len(proxies)` / CPU 数自适应。
3. 保持结果 map 写入安全（当前已有 mutex，可改为 channel 收集）。

**验收标准**

- 1000 节点 URLTest 不出现连接风暴。
- 测试结果与并发受限前一致（允许合理误差）。

**状态**：`TODO`

---

#### PERF-02 日志热路径在过滤前就格式化并发送

**现状**

`log/log.go:37-40`：

```go
func Infoln(format string, v ...any) {
    event := newLog(INFO, format, v...)
    logCh <- event
    print(event)
}
```

`newLog` 无条件 `fmt.Sprintf`；`logCh` 是无缓冲 channel；`print` 才检查日志级别。

**微基准（i5-13600KF）**

| 场景 | 耗时 | 分配 |
|---|---|---|
| INFO 实际输出 | 2861 ns/op | 794 B/op，18 allocs/op |
| 级别过滤到 ERROR | 230 ns/op | 80 B/op，1 alloc/op |

**影响**

- 默认级别是 INFO，每条 TCP 连接都会走这条路径。
- 即使设置 warning/error，仍然要格式化 + channel 发送。

**建议**

1. 在 `Infoln/Warnln/Errorln/Debugln` 入口先判断 `level`，不满足直接 return。
2. `logCh` 改为带缓冲；满了丢弃或采样，不要阻塞数据面。
3. 对连接日志做采样，或默认降到 warning。
4. 考虑结构化日志（zap/slog）和字段化输出。

**验收标准**

- 关闭 INFO 后日志调用接近零分配。
- 高连接率下日志不成为瓶颈。

**状态**：`TODO`

---

#### PERF-03 规则引擎仍是线性扫描，没有匹配缓存

**现状**

`tunnel/tunnel.go:663` 对规则逐条 `rule.Match`，直到命中。

- domain rule-provider 内部使用 `DomainSet`，性能不错：`Has` 约 106–110 ns/op，0 alloc。
- 但顶层几千条规则仍然是 O(n) 扫描。

**基准数据**

| 策略 | 耗时 | 分配 |
|---|---|---|
| `DomainSet.Has` | 106–110 ns/op | 0 alloc |
| `DomainMap.Lookup` | 180–290 ns/op | 1 alloc |
| map 策略 | 60–170 ns/op | 0 alloc |

**建议**

1. 按 `host + ruleProvider version` 做 LRU 匹配缓存；规则集更新时失效。
2. 把连续的 `DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD` 规则合并成 trie/AC 自动机。
3. 对 `IP-CIDR` / `GEOIP` 保持 `no-resolve` 优化，避免无谓 DNS。
4. 小规则集优先用 map 策略；大规则集用 trie。

**验收标准**

- 5000+ 规则下匹配延迟明显下降。
- 规则顺序语义保持不变。

**状态**：`TODO`

---

#### PERF-04 DNS 的 A/AAAA 查询有优化空间

**现状**

`dns/resolver.go:77-108` 的 `LookupIP`：

- 每次起一个 AAAA goroutine
- 最多等待 `ipv6-timeout`（默认 100ms）
- `Resolver.ipv6` 字段在第 40 行定义、598 行赋值，但没有被读取
- 真正决定是否禁用 IPv6 的是全局 `resolver.DisableIPv6`

**影响**

- IPv4-only 环境可能白等 100ms。
- 每个 DNS 查询多一个 goroutine 和 channel。

**建议**

1. `LookupIP` 根据 `DisableIPv6` / `ipv6` 跳过 AAAA。
2. 考虑先查 A，只有 A 失败或需要 IPv6 时再查 AAAA。
3. 对 `ExchangeContext` 超时后的后台缓存刷新加并发上限，避免唯一域名造成 goroutine 膨胀。

**验收标准**

- `ipv6: false` 时不再发起 AAAA 查询。
- DNS 解析延迟下降，行为兼容。

**状态**：`TODO`

---

#### PERF-05 fake-ip 持久化模式的全局锁 + bbolt 每次读写

**现状**

`component/fakeip/pool.go:43` 的 `Lookup` 全程持有 `p.mux`，持久化 store 会走 bbolt 的 `DB.View` / `DB.Batch`。

**影响**

- `profile.store-fake-ip: true` 时，每次 DNS fake-ip 查询都可能触发磁盘事务。
- 高 QPS 下全局锁 + bbolt 是明显瓶颈。

**建议**

1. 内存里加一层 LRU/分片缓存。
2. bbolt 写入改为异步批量。
3. 或按 IP 段分片锁。

**验收标准**

- 持久化模式下 fake-ip 查询不直接阻塞在磁盘事务上。
- 重启后映射仍能恢复。

**状态**：`TODO`

---

#### PERF-06 rematch 在配置读锁内做 Dial

**现状**

`tunnel/tunnel.go:655` 持有 `configMux.RLock()`，`:698` 在 rematch 分支执行 `rematchProxy.DialContext(...)`。

**影响**

- Dial 可能阻塞，期间配置热重载被卡住。

**建议**

1. 把 Dial 移到锁外。
2. 拿到结果后重新加锁匹配。
3. 对 rematch 链增加超时/循环检测（已有 cycle 检测，可复用）。

**验收标准**

- 配置热重载不被 rematch Dial 阻塞。
- rematch 行为不变。

**状态**：`TODO`

---

#### PERF-07 每连接一个 crypto/rand UUID

**现状**

`tunnel/statistic/tracker.go:119` 每个 TCP 连接生成 UUID v4，底层是 `crypto/rand.Read`。

**建议**

1. 用原子计数器 + 进程前缀生成连接 ID。
2. API 只需要唯一即可，不要求 UUID 格式。
3. 如需兼容现有 API，可保留 UUID 字段但用更快生成器。

**验收标准**

- 高连接率下连接建立开销下降。
- API 兼容。

**状态**：`TODO`

---

#### PERF-08 UDP 队列固定容量

**现状**

`tunnel/tunnel.go`：

- `queueCapacity = 64`
- `senderCapacity = 128`
- UDP worker 数 = max(4, GOMAXPROCS)

**影响**

- 高 UDP 吞吐/突发时可能丢包。
- 不同设备（路由器/手机/PC）最优值不同。

**建议**

1. 暴露 UDP 队列长度/worker 数配置。
2. 增加丢包统计指标。
3. 根据 GOMAXPROCS 和内存自适应默认值。

**验收标准**

- 可配置；默认值不退化。
- 有丢包监控。

**状态**：`TODO`

---

### P2：可观测性与工程化

#### OBS-01 缺少指标和追踪

**现状**

- 只有 `/traffic`、`/memory`、`/connections` 等 JSON API
- debug 模式有 pprof
- 没有 Prometheus `/metrics`
- 没有 OpenTelemetry trace

**建议**

1. 增加轻量 `/metrics`（Prometheus 格式）。
2. 至少暴露：连接数、上下行字节、DNS cache hit/miss、规则命中分布、URLTest 成功/失败/延迟、goroutine 数、堆内存。
3. 可选：OTel trace、结构化日志。

**验收标准**

- 默认配置下 `/metrics` 可用（或通过配置开启）。
- Dashboard 可接入。

**状态**：`TODO`

---

#### CI-01 CI 没有 lint / 漏洞扫描，且 lint 配置已过期

**现状**

- `.github/workflows/test.yml` 只跑 `go test`
- 没有 lint、`govulncheck`、依赖检查
- `.golangci.yaml` 是旧版 schema
- 当前 `golangci-lint 2.11.4` 报：

```text
Error: can't load config: unsupported version of the configuration
```

**建议**

1. 固定 golangci-lint 版本。
2. 升级配置到 v2 格式（`version: "2"`，`linters.settings`）。
3. 增加独立 lint job 和 `govulncheck` job。
4. 增加 `go mod tidy` 检查。

**验收标准**

- PR 上能看到 lint / govulncheck 结果。
- 配置不再报 schema 错误。

**状态**：`TODO`

---

#### TEST-01 核心路径测试覆盖不足

**现状**

`go test ./...` 全量通过，`go vet ./...` 通过，但覆盖率不均衡：

| 包 | 覆盖率 |
|---|---|
| `component/trie` | 85.3% |
| `component/fakeip` | 80.8% |
| `adapter/provider` | 65.4% |
| `adapter` | 0% |
| `dns` | 0% |
| `tunnel` | 0% |
| `rules` | 0% |

**建议**

1. 补规则匹配（domain/ip/rule-set/逻辑规则）的 golden test。
2. 补 DNS 缓存、fake-ip、fallback 的单元测试。
3. 补 URLTest / HealthCheck 的并发与契约测试。
4. 配置文件解析加 fuzz test。
5. CI 增加覆盖率阈值（先按包设置，避免一次性卡死）。

**验收标准**

- 核心包覆盖率逐步提升。
- 新 bug 有对应回归测试。

**状态**：`TODO`

---

#### MAINT-01 单体大文件和配置兼容层

**现状**

- `adapter/provider/override_expr.go` 3032 行
- `config/config.go` 1980 行
- `transport/openvpn/client.go` 1783 行
- `docs/config.yaml` 2000+ 行

**建议**

1. 把 override 表达式、配置解析、协议实现拆成独立包。
2. 配置文档用 JSON Schema 生成，CI 校验示例配置。
3. 为配置项增加弃用周期和迁移提示。

**验收标准**

- 新贡献者能在合理时间内定位代码。
- 配置错误在启动前被发现。

**状态**：`TODO`

---

#### REL-01 发布与供应链

**现状**

- 构建矩阵覆盖 Go 1.20–1.26、几十种 OS/ARCH，维护成本高。
- 有 `checksums.txt`，但没有 SBOM、cosign 签名、可复现构建说明。

**建议**

1. Syft 生成 SBOM。
2. cosign 签名发布资产。
3. 发布说明给出验证命令。
4. 把 Go 1.20/老系统构建移到 legacy 通道。
5. 固定 GitHub Actions 版本/commit SHA。

**验收标准**

- 每个 release 有 SBOM 和签名。
- 用户可以验证下载文件。

**状态**：`TODO`

---

### P3：架构与功能方向

#### ARCH-01 模块化/依赖注入不如 sing-box

**现状**

- 全局 `tunnel` 状态
- `C.RuleMatchHelper` 回调式 resolve/find-process
- 协议实现与核心耦合较深

**建议**

1. 把 `tunnel` 的全局状态收敛到一个 `Router` 结构体，显式注入。
2. 把 `ResolveIP` / `FindProcess` 回调改成可组合的 action。
3. 新代码优先使用依赖注入，老代码保持兼容。

**验收标准**

- 核心路由可用 fake 依赖做单测。
- 新功能不再增加全局状态。

**状态**：`TODO`

---

#### ARCH-02 Linux 数据面可以更大胆

**现状**

- 主要使用 TUN/iptables/tproxy
- dae 使用 eBPF；sing-box 有 `auto_redirect`

**建议**

1. 短期在文档中明确：Linux 软路由/网关场景可优先考虑 dae 或 sing-box `auto_redirect`。
2. 中长期评估接入 nftables `auto_redirect` 或 eBPF 直连旁路。
3. 这是大工程，优先级低于安全和并发。

**验收标准**

- Linux 高吞吐场景有明确推荐路径。
- 如实现，有性能对比数据。

**状态**：`TODO`

---

#### PROTO-01 协议稳定性比继续堆协议更重要

**现状**

- 协议广度已经足够。
- 社区反馈中 Hysteria2/TUIC 的稳定性仍是相对短板。

**建议**

1. 优先修握手、重连、多路复用、UDP 行为。
2. 建立协议互通测试矩阵（可参考 `test/` 和 `listener/inbound/*_test.go`）。
3. 新协议先以实验性标记进入，稳定后再默认推荐。

**验收标准**

- 协议回归测试覆盖主要路径。
- 线上问题有可复现用例。

**状态**：`TODO`

---

## 4. 路线图

### 4.1 1–2 周（低风险、高收益）

| ID | 事项 | 状态 |
|---|---|---|
| SEC-01 | 发布构建升到 Go 1.26.10+，CI 加 `govulncheck` | TODO |
| COR-01 | 修复 HealthCheck 数据竞争 | TODO |
| PERF-01 | URLTest 加并发上限 | TODO |
| PERF-02 | 日志入口按级别短路，`logCh` 加缓冲 | TODO |
| SEC-02 | 内核更新校验 `checksums.txt` | TODO |
| SEC-03 | 非 loopback controller 强制 secret 或警告 | TODO |

### 4.2 1–2 月

| ID | 事项 | 状态 |
|---|---|---|
| PERF-03 | 规则匹配缓存 + domain 规则合并 | TODO |
| PERF-04 | DNS A/AAAA 策略与后台刷新限流 | TODO |
| PERF-05 | fake-ip 内存缓存 + bbolt 批量写 | TODO |
| OBS-01 | `/metrics` + 结构化日志 | TODO |
| CI-01 | lint / 覆盖率 / SBOM / cosign 接入 CI | TODO |
| MAINT-01 | 拆分 `override_expr.go`、`config.go` | TODO |

### 4.3 长期

| ID | 事项 | 状态 |
|---|---|---|
| ARCH-01 | Router 依赖注入、action-based 规则 | TODO |
| ARCH-02 | Linux nftables/eBPF 数据面评估 | TODO |
| PROTO-01 | 协议稳定性与互通测试矩阵 | TODO |
| REL-01 | legacy 构建通道与主分支解耦 | TODO |

---

## 5. 验证与基准

### 5.1 全量测试与静态检查

```bash
SKIP_INTEROP_TEST=1 go test ./...
go vet ./...
govulncheck ./...
```

评估基线结果：

- `go test ./...`：通过
- `go vet ./...`：通过
- `govulncheck ./...`：13 个可达漏洞（x/net、x/text、stdlib）

### 5.2 Domain trie 基准

```bash
go test -run '^$' \
  -bench 'BenchmarkDomain(Set|Map)(Has|Lookup|Build)$' \
  -benchmem ./component/trie
```

关键结果：

- `DomainSet.Has`：约 106–110 ns/op，0 alloc
- `DomainMap.Lookup`：约 180–290 ns/op，1 alloc
- map 策略：约 60–170 ns/op，0 alloc

### 5.3 日志微基准

临时 benchmark 思路：

```go
package log

import "testing"

func BenchmarkLogInfolnTmp(b *testing.B) {
    for i := 0; i < b.N; i++ {
        Infoln("[TCP] 127.0.0.1:12345 --> example.com:443 match RuleSet(proxy) using Proxy[Node]")
    }
}
```

运行：

```bash
go test -run '^$' -bench BenchmarkLogInfolnTmp -benchtime=200000x ./log
```

结果（i5-13600KF）：

- INFO 实际输出：2861 ns/op，794 B/op，18 allocs/op
- 级别过滤到 ERROR：230 ns/op，80 B/op，1 alloc/op

### 5.4 空闲内存

```bash
./mihomo -d /tmp/mihomo -f config.yaml &
pid=$!
sleep 2
ps -o pid=,rss=,vsz=,nlwp= -p "$pid"
kill "$pid"
```

最小 direct 配置实测：RSS 约 23 MB。带大量规则/连接时会明显上升。

### 5.5 HealthCheck 数据竞争复现

临时测试（勿提交）：

```go
package provider

import (
    "sync"
    "testing"

    C "github.com/metacubex/mihomo/constant"
)

func TestHealthCheckSetProxiesRaceTmp(t *testing.T) {
    hc := &HealthCheck{proxies: []C.Proxy{}}
    var wg sync.WaitGroup
    wg.Add(2)
    go func() {
        defer wg.Done()
        for i := 0; i < 10000; i++ {
            hc.setProxies([]C.Proxy{})
        }
    }()
    go func() {
        defer wg.Done()
        for i := 0; i < 10000; i++ {
            hc.check()
        }
    }()
    wg.Wait()
}
```

运行：

```bash
go test -race -run TestHealthCheckSetProxiesRaceTmp ./adapter/provider
```

结果：`WARNING: DATA RACE`，位置 `healthcheck.go:65` 和 `healthcheck.go:124`。

> 建议把这个测试改造成长期保留的回归测试，而不是临时测试。

---

## 6. 已修复问题记录

### BUG-01 URLTest 亚毫秒成功被报告为失败

- **现象**：节点测速成功，但 `/proxies/{name}/delay` 返回 503，UI 右上角报错。
- **根因**：`adapter/adapter.go` 把耗时截断为毫秒，亚毫秒成功得到 `delay=0`；调用方把 0 当作失败。
- **修复**：测量完成后把 0 规整为 1ms；失败仍返回 0 / not alive。
- **上游**：`Meta` v1.19.33 已包含（`df1b07af`，原合入 `Alpha`）。
- **本地**：`fix/urltest-submillisecond-delay` 分支原有回移提交已在同步上游时自动去重。
- **状态**：`DONE`

---

## 7. 参考

- [sing-box Internals: Architecture Overview](https://singbox-internals.hidandelion.com/architecture/overview.html)
- [sing-box TUN 文档](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [sing-box DNS 文档](https://sing-box.sagernet.org/configuration/dns/)
- [Xray-core README](https://github.com/XTLS/Xray-core)
- [dae README](https://github.com/daeuniverse/dae)
- [sing-box vs Mihomo 2026 对比](https://www.chonglangbiji.com/protocols/sing-box-vs-mihomo-kernel-performance-memory-protocol-may-2026/)
- [V2EX: mihomo vs sing-box 使用体验](https://hk.v2ex.com/t/1149486)
- [mihomo issue #2764：IP 规则导致高 CPU（DNS 环）](https://github.com/MetaCubeX/mihomo/issues/2764)
- [mihomo issue #1782：OOM/内存讨论](https://github.com/MetaCubeX/mihomo/issues/1782)
- [Clash Verge Rev #7117：内核内存问题](https://github.com/clash-verge-rev/clash-verge-rev/issues/7117)

---

## 8. 维护指南

### 8.1 更新频率

- 每个 `Meta` 版本发布后更新一次。
- 安全漏洞、重大性能改动、架构调整后立即更新。
- 建议每季度做一次完整复核。

### 8.2 更新检查清单

1. 确认评估基线分支/提交/版本。
2. 重新运行 `go test ./...`、`go vet ./...`、`govulncheck ./...`。
3. 重新运行 Domain trie 和日志基准，记录机器信息。
4. 检查 P0/P1 项是否已修复，更新状态。
5. 新增问题按 `SEC/COR/PERF/OBS/CI/TEST/MAINT/REL/ARCH/PROTO` 编号。
6. 更新「已修复问题记录」。
7. 更新「最近更新」日期。

### 8.3 状态图例

| 状态 | 含义 |
|---|---|
| `TODO` | 待处理 |
| `DOING` | 进行中 |
| `DONE` | 已完成 |
| `WONTFIX` | 评估后不做 |

### 8.4 写作约定

- 每个优化项必须包含：现状、影响、建议、验收标准、状态。
- 代码引用使用 `文件:行号`，并注明基于哪个提交。
- 性能数据必须注明测试机器和命令。
- 第三方结论必须注明来源，并区分“代码事实”和“社区经验”。
- 不要直接复制网上的过时结论；以当前仓库代码为准。

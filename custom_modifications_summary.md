# Mihomo 自定义修改清单（FlClash 安卓版移植用）

> 将此文档交给 AI，对 FlClash 集成的 Mihomo 内核执行相同修改。
> 共修改 **3 个文件**，涉及 **13 处改动**。

---

## 修改总览

| 修改类别 | 目的 |
|---------|------|
| `sync.RWMutex` 线程安全 | 防止并发读写 `selected` / `fastNode` 时 data race |
| `fast()` 节点选择算法改进 | 区分"存活但慢"和"完全挂掉"节点，避免切到超时节点 |
| 全死亡异步健康检查 | URLTest / Fallback 所有节点无响应时主动触发检测，加快恢复 |
| `healthCheck()` 预热 | 健康检查完成后**立即**重新选出最优节点 |
| `URLTest()` 缓存重置 | 手动测速后**立刻**生效，不等下次请求 |
| 节点切换断连 | 自动切换节点时关闭旧连接，使流量立即走新节点 |
| `SetLimit(100)` | 提高健康检查并发度，减少检测总耗时 |
| `singleDo` 超时同步 | 与测速 timeout 保持一致，避免写死 1 秒 |

---

## 文件 1: `adapter/outboundgroup/urltest.go`

### 1.1 结构体添加 `sync.RWMutex`

```diff
 type URLTest struct {
     *GroupBase
+    stateMux       sync.RWMutex
     selected       string
```

### 1.2 `ForceSet()` 使用 Mutex 保护写入

```diff
 func (u *URLTest) ForceSet(name string) {
+    u.stateMux.Lock()
     u.selected = name
+    u.stateMux.Unlock()
     u.fastSingle.Reset()
 }
```

### 1.3 替换 `fast()` 方法（核心改动）

上游的 `fast()` 使用单次遍历找最小延迟，不区分存活/超时。替换为以下完整实现：

```go
func (u *URLTest) fast(touch bool) C.Proxy {
    elm, _, shared := u.fastSingle.Do(func() (C.Proxy, error) {
        proxies := u.GetProxies(touch)
        selected, fastNode := u.snapshotState()

        // 优先使用手动选定节点
        if selected != "" {
            for _, proxy := range proxies {
                if !proxy.AliveForTestUrl(u.testUrl) {
                    continue
                }
                if proxy.Name() == selected {
                    u.setFastNode(proxy)
                    return proxy, nil
                }
            }
        }

        var (
            fast         C.Proxy
            fastDelay    uint16
            hasAliveFast bool
            fastNotExist = true
        )

        for _, proxy := range proxies {
            if fastNode != nil && proxy.Name() == fastNode.Name() {
                fastNotExist = false
            }
            if !proxy.AliveForTestUrl(u.testUrl) {
                continue
            }
            delay := proxy.LastDelayForTestUrl(u.testUrl)
            if !hasAliveFast || delay < fastDelay {
                fast = proxy
                fastDelay = delay
                hasAliveFast = true
            }
        }

        // 有存活节点时，只在差距超过容差时才换
        if hasAliveFast {
            if fastNode == nil || fastNotExist || !fastNode.AliveForTestUrl(u.testUrl) || fastNode.LastDelayForTestUrl(u.testUrl) > fastDelay+u.tolerance {
                fastNode = fast
            }
        } else if fastNode == nil || fastNotExist || !fastNode.AliveForTestUrl(u.testUrl) {
            fastNode = proxies[0]
            // 全死亡 → 异步健康检查
            go u.healthCheck()
        }

        u.setFastNode(fastNode)
        return fastNode, nil
    })
    if shared && touch {
        u.Touch()
    }
    return elm
}
```

### 1.4 新增三个线程安全辅助方法

```go
func (u *URLTest) snapshotState() (string, C.Proxy) {
    u.stateMux.RLock()
    defer u.stateMux.RUnlock()
    return u.selected, u.fastNode
}

func (u *URLTest) getSelected() string {
    u.stateMux.RLock()
    defer u.stateMux.RUnlock()
    return u.selected
}

func (u *URLTest) setFastNode(proxy C.Proxy) {
    u.stateMux.Lock()
    old := u.fastNode
    u.fastNode = proxy
    u.stateMux.Unlock()

    // 节点切换时关闭旧连接，使流量立即走新节点
    if old != nil && proxy != nil && old.Name() != proxy.Name() {
        groupName := u.Name()
        statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
            for _, chain := range c.Chains() {
                if chain == groupName {
                    _ = c.Close()
                    break
                }
            }
            return true
        })
    }
}
```

> **import 新增**：`"github.com/metacubex/mihomo/tunnel/statistic"`

### 1.5 新增 `healthCheck()` override（预热）

```go
func (u *URLTest) healthCheck() {
    u.fastSingle.Reset()
    u.GroupBase.healthCheck()
    u.fastSingle.Reset()
    _ = u.fast(false) // 检查完立即选出最优节点
}
```

### 1.6 `URLTest()` 测速后重置缓存

```diff
 func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
-    return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
+    delays, err := u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
+    u.fastSingle.Reset()
+    _ = u.fast(false)
+    return delays, err
 }
```

### 1.7 `MarshalJSON` 使用线程安全读取

```diff
-    "fixed": u.selected,
+    "fixed": u.getSelected(),
```

---

## 文件 2: `adapter/outboundgroup/fallback.go`

### 2.1 结构体添加 `sync.RWMutex`

```diff
 type Fallback struct {
     *GroupBase
+    stateMux       sync.RWMutex
     disableUDP     bool
```

### 2.2 `findAliveProxy()` 增加手选支持 + 全死亡检查

完整替换为：

```go
func (f *Fallback) findAliveProxy(touch bool) C.Proxy {
    proxies := f.GetProxies(touch)
    selected := f.getSelected()

    if len(selected) != 0 {
        for _, proxy := range proxies {
            if proxy.Name() != selected {
                continue
            }
            if proxy.AliveForTestUrl(f.testUrl) {
                return proxy
            }
            f.clearSelectedIf(selected)
            break
        }
    }

    for _, proxy := range proxies {
        if proxy.AliveForTestUrl(f.testUrl) {
            return proxy
        }
    }

    // 全死亡 → 异步健康检查
    log.Warnln("Fallback: all proxies in %s are not alive, triggering health check", f.Name())
    go f.healthCheck()
    return proxies[0]
}
```

> **import 新增**：`"github.com/metacubex/mihomo/log"`

### 2.3 新增三个线程安全辅助方法

```go
func (f *Fallback) getSelected() string {
    f.stateMux.RLock()
    defer f.stateMux.RUnlock()
    return f.selected
}

func (f *Fallback) setSelected(name string) {
    f.stateMux.Lock()
    f.selected = name
    f.stateMux.Unlock()
}

func (f *Fallback) clearSelectedIf(selected string) {
    f.stateMux.Lock()
    if f.selected == selected {
        f.selected = ""
    }
    f.stateMux.Unlock()
}
```

### 2.4 `Set()` / `ForceSet()` 使用线程安全方法

```diff
-    f.selected = name
+    f.setSelected(name)
```

### 2.5 `MarshalJSON` 使用 `getSelected()` 并补全字段

```diff
 return json.Marshal(map[string]any{
     "type":           f.Type().String(),
     "now":            f.Now(),
     "all":            all,
+    "testUrl":        f.testUrl,
+    "expectedStatus": f.expectedStatus,
+    "fixed":          f.getSelected(),
+    "hidden":         f.Hidden(),
+    "icon":           f.Icon(),
 })
```

---

## 文件 3: `adapter/provider/healthcheck.go`

### 3.1 健康检查并发度 10 → 100

```diff
 b := new(errgroup.Group)
-b.SetLimit(10)
+b.SetLimit(100)
```

### 3.2 `singleDo` 超时与测速超时同步

在 `NewHealthCheck()` 中：

```diff
-singleDo: singledo.NewSingle[struct{}](time.Second),
+singleDo: singledo.NewSingle[struct{}](time.Duration(timeout) * time.Millisecond), // keep in sync with test timeout
```

---

## 移植注意事项

1. **FlClash 的 Mihomo 内核可能版本不同**，结构体字段和方法签名需对照 FlClash 使用的具体版本确认
2. `setFastNode()` 中的**断连逻辑**依赖 `tunnel/statistic` 包，需确认 FlClash 的构建是否包含该包
3. 修改均在 Go 层面，与平台无关，安卓版的改动内容完全一致

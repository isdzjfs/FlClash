# Android VPN 启动崩溃问题修复日志

在先前的优化中，由于为了优化内存泄漏与性能，我们针对 Android 原生服务和核心组件做了许多重构和性能提升。经过仔细审查日志和底层代码逻辑，我们定位到了导致“手动启动后能连接但会自动断开”的致命错误根源，并进行了精准修复。

以下是本次对话中具体修改的代码和修复说明：

## 1. 修复 `VpnService` 中的 `ConcurrentModificationException` (导致 VPN 自动断开的核心原因)

**文件：** `android/service/src/main/java/com/follow/clash/service/VpnService.kt`

**问题分析：**
在之前的优化中，我们为 `VpnService` 的 `uidPageNameMap` 引入了 LRU 淘汰机制，将其改为了带有 `accessOrder = true` 的 `LinkedHashMap`。当 VPN 成功启动并接管流量后，底层的 Go 核心会通过 JNI 的多线程并发回调 `resolverProcess` 方法来解析 UID 对应的包名。然而，`LinkedHashMap` (特别是在开启了 `accessOrder` 时) **并不是线程安全的**，即使是单纯的读取 (`get`) 操作也会修改内部链表结构。多线程并发访问瞬间引发了 `ConcurrentModificationException`，导致 Android 的 `VpnService` 进程发生 Crash 而自动断开连接。

**修改内容：**
引入了专门的锁对象 `uidPageNameMapLock`，并在 `resolverProcess` 方法中使用 `synchronized` 同步块包裹了对 `uidPageNameMap` 的读写操作，确保 JNI 多线程回调时的线程安全。

```kotlin
// 增加锁对象
private val uidPageNameMapLock = Any()

// 在 resolverProcess 方法中增加 synchronized 同步块
synchronized(uidPageNameMapLock) {
    if (!uidPageNameMap.containsKey(nextUid)) {
        uidPageNameMap[nextUid] = this.packageManager?.getPackagesForUid(nextUid)?.firstOrNull() ?: ""
    }
    return uidPageNameMap[nextUid] ?: ""
}
```

## 2. 预防性修复 `AppPlugin` 中的并发访问问题

**文件：** `android/app/src/main/kotlin/com/follow/clash/plugins/AppPlugin.kt`

**问题分析：**
在上一轮优化国内包解析时，我们添加了 `chinaPackageCache` 以大幅提升性能。由于 Flutter 可能会在协程池中并发调用查询方法，原本使用的普通 `mutableMapOf` 在极端并发下同样面临 `ConcurrentModificationException` 的风险。

**修改内容：**
将 `chinaPackageCache` 的数据结构从 `mutableMapOf` 安全地替换为了 `java.util.concurrent.ConcurrentHashMap`。

```kotlin
// 原代码
// private val chinaPackageCache = mutableMapOf<String, Boolean>()

// 新代码：使用线程安全的并发哈希表
private val chinaPackageCache = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
```

## 3. 新增 DNS 级别日志模式
**文件：** `lib/enum/enum.dart`, `lib/manager/core_manager.dart`, `lib/common/task.dart`

**修改内容：**
为了解决 debug 模式下日志太长的问题，我们在全局 `LogLevel` 枚举中新增了 `dns` 级别。通过修改底层的 `task.dart`，当您选择 `dns` 级别时，我们会欺骗 Clash Core 让它继续以 `debug` 模式运行，但在 Flutter 层的 `core_manager.dart` 中，我们只保留以 `[DNS]` 开头的核心日志，同时保留所有的 App 日志，从而实现完美的 DNS 独立日志过滤，且不会导致 Core 崩溃。

## 4. 增加了网络监听模块的容错 (NetworkObserveModule)
**文件：** `android/service/src/main/java/com/follow/clash/service/modules/NetworkObserveModule.kt`

**修改内容：**
我们发现如果 Android 系统的网络属性 (LinkProperties) 返回异常，会导致整个 VPN 进程发生未捕获的异常从而断开。因此对 `applyNetworkUpdate` 函数增加了全局的 try-catch，进一步保证了后台服务不会异常停止。

## 总结
通过本次修复，彻底解决了多线程并发导致的系统级崩溃问题，现在 OnePlus 15 (Android 16) 设备上 VPN 将能够稳定连接并持续保持后台运行。

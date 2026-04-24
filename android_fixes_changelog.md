# FLClash 安卓端性能优化与代码修复总结

这份文档记录了我们在本次对话中对 FLClash 安卓端进行的所有代码修改。本次优化主要针对性能瓶颈、内存泄漏、稳定性风险以及安全问题进行了全面的修复。

## 核心网络性能优化

### 1. `android/core/src/main/java/com/follow/clash/core/Core.kt`
- **改动**: 重构了 `parseInetSocketAddress` 方法。
- **详情**: 原代码在解析 Socket 地址时使用了 `URL` 对象和 `InetAddress.getByName()`，这会导致高频的网络连接每次都触发 DNS 解析和巨大的系统开销。修复后直接使用字符串解析和 `InetSocketAddress.createUnresolved()`，避免了每连接一次的 DNS 查找和 Binder IPC 开销，大幅提升网络吞吐效率。

## 内存泄漏修复 (协程作用域管理)

### 2. `android/service/src/main/java/com/follow/clash/service/VpnService.kt`
- **改动**: 在 `onDestroy()` 中添加 `coroutineContext[Job]?.cancel()`，并使用 `SupervisorJob()`。
- **详情**: 防止服务销毁后协程仍在后台运行导致内存泄漏。

### 3. `android/service/src/main/java/com/follow/clash/service/CommonService.kt`
- **改动**: 在 `onDestroy()` 中添加协程取消逻辑。

### 4. `android/app/src/main/kotlin/com/follow/clash/MainActivity.kt`
- **改动**: 在 `onDestroy()` 中添加协程取消逻辑。

### 5. `android/app/src/main/kotlin/com/follow/clash/TempActivity.kt`
- **改动**: 在 `onDestroy()` 中添加协程取消逻辑。

### 6. `android/service/src/main/java/com/follow/clash/service/RemoteService.kt`
- **改动**: 添加了 `kotlinx.coroutines.Job` 导入，并在 `onDestroy()` 中调用 `coroutineContext[Job]?.cancel()`。
- **详情**: RemoteService 负责处理跨进程的 AIDL 调用，修复前进程被杀或销毁时会导致大量挂起的协程（如 `invokeAction` 回调）泄漏。

### 7. `android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt`
- **改动**: 在 `onDetachedFromEngine` 中添加 `coroutineContext[Job]?.cancel()`。
- **详情**: 确保 Flutter 引擎断开时清理 Plugin 持有的协程。

## 缓存与频繁 GC 优化

### 8. `android/service/src/main/java/com/follow/clash/service/VpnService.kt` (第二次修改)
- **改动**: 将无界限的 `uidPageNameMap` 替换为容量上限为 256 的 LRU Cache (`object : LinkedHashMap<Int, String>(256, 0.75f, true)`，覆盖 `removeEldestEntry`)。修复了 `getPackagesForUid()` 结果为空时调用 `.first()` 导致 `NoSuchElementException` 崩溃的问题（改为 `.firstOrNull()`）。
- **详情**: 避免长时间开启 VPN 导致该 Map 无限增长耗尽内存。

### 9. `android/service/src/main/java/com/follow/clash/service/models/Traffic.kt`
- **改动**: 将 `Gson` 实例提取为顶层私有属性缓存 (`private val trafficGson = Gson()`)。
- **详情**: `getSpeedTrafficText` 每秒都会调用，原代码每次都会 `new Gson()`，导致严重的垃圾回收（GC）压力和微卡顿。

### 10. `android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt` (第二次修改)
- **改动**: 在类内缓存 `Gson` 实例 (`private val gson = Gson()`) 供 `handleSyncState` 使用。

### 11. `android/app/src/main/kotlin/com/follow/clash/plugins/AppPlugin.kt` (中国包扫描优化)
- **改动**: 添加了 `chinaPackageCache` (按 `packageName:lastUpdateTime` 缓存) 和 `appGson` 实例缓存。
- **详情**: 原代码在每次调用 `getChinaPackageNames()` 时都会对所有应用全量解压 DEX 文件扫描。修改后，结果被缓存下来，仅当应用更新时 (`lastUpdateTime` 变化) 才重新扫描。大幅降低打开设置页面时的 CPU 占用、发热和卡顿。

## 服务稳定性与逻辑防抖

### 12. `android/service/src/main/java/com/follow/clash/service/modules/NotificationModule.kt`
- **改动1 (第一轮)**: 移除了多余的死代码，并强制立即调用 `service.startForeground(notification)`。防止在 Android 16 上因前台服务启动延迟触发 `ForegroundServiceStartNotAllowedException` 崩溃。
- **改动2 (第二轮)**: 将通知刷新的 `tickerFlow` 从每 1000ms 改为 3000ms。
- **详情**: 减少 JNI 通信和更新系统通知产生的无效开销，3秒刷新足以满足用户看网速的需求。

### 13. `android/service/src/main/java/com/follow/clash/service/modules/NetworkObserveModule.kt`
- **改动**: 引入了协程防抖 (`Debounce`) 机制 (`DEBOUNCE_MS = 500L`)。
- **详情**: 在电梯或网络切换时（如 WiFi 切换到 5G），系统会瞬间下发多次网络状态变更回调。加入 500ms 的防抖，避免瞬间多次触发耗时的 DNS 对比和 `Core.updateDNS` 操作，减少瞬间抖动。

### 14. `android/service/src/main/java/com/follow/clash/service/modules/SuspendModule.kt`
- **改动**: 添加了对 `ACTION_DEVICE_IDLE_MODE_CHANGED` 的监听。
- **详情**: 优化了对 Doze 休眠模式的支持，确保 VPN 在设备深度休眠和唤醒时能够正确暂停和恢复连接状态（在一加等国产系统上效果更佳）。

### 15. `android/service/src/main/java/com/follow/clash/service/modules/ModuleLoader.kt`
- **改动**: 将全局 `Mutex` 移入 `moduleLoader` 实例作用域内部。
- **详情**: 修复了不同服务实例（如 VpnService 和 CommonService）之间共享 Mutex 导致的跨服务死锁风险。

## 安全与权限规范

### 16. `android/service/src/main/java/com/follow/clash/service/FilesProvider.kt`
- **改动**: 重写了文件访问逻辑，使用相对路径作为 `documentId`，并在 `resolveFile()` 中校验 `canonical.path.startsWith(baseDirCanonical.path)`。
- **详情**: 修复了由于使用绝对路径导致的潜在路径遍历 (Path Traversal) 安全漏洞，确保恶意调用方无法读取 `filesDir` 之外的系统文件。

### 17. `android/app/src/main/AndroidManifest.xml`
- **改动**: 移除了 `<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />` 和 `ACCESS_COARSE_LOCATION`。
- **详情**: 经过代码检查，应用内部使用 `ConnectivityManager` 获取 WiFi 状态，并不依赖定位权限。移除无用权限以符合合规要求。

## 构建与依赖现代化

### 18. `android/settings.gradle.kts`
- **改动**: 将 `firebase-crashlytics-gradle` 升级到 `3.0.3`，`google-services` 升级到 `4.4.2`。
- **详情**: 兼容更新的 Android Gradle Plugin 版本。

### 19. `android/gradle/libs.versions.toml` & `android/common/build.gradle.kts`
- **改动**: 在 TOML 中显式锁定了 `kotlinx-coroutines` 的版本为 `1.10.2`，并在 `common` 模块中使用 `api` 导出。
- **详情**: 消除协程依赖因为传递依赖（Transitive Dependency）导致的隐式版本变动风险，规范化依赖树。

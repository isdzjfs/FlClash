package com.follow.clash.service.modules

import android.app.Service
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkCapabilities.NET_CAPABILITY_FOREGROUND
import android.net.NetworkCapabilities.TRANSPORT_SATELLITE
import android.net.NetworkCapabilities.TRANSPORT_USB
import android.net.NetworkRequest
import android.os.Build
import androidx.core.content.getSystemService
import com.follow.clash.core.Core
import com.follow.clash.service.VpnService
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class NetworkInfo(
    @Volatile var losingMs: Long = 0, @Volatile var dnsList: List<InetAddress> = emptyList()
) {
    fun isAvailable(): Boolean = losingMs < System.currentTimeMillis()
}

class NetworkObserveModule(private val service: Service) : Module() {

    private val networkInfos = ConcurrentHashMap<Network, NetworkInfo>()
    private val connectivity by lazy {
        service.getSystemService<ConnectivityManager>()
    }
    private var preDnsList = listOf<String>()
    private var preUnderlyingNetworks = listOf<Network>()
    private val debounceScope = CoroutineScope(Dispatchers.Default)
    private var debounceJob: Job? = null
    private companion object {
        const val DEBOUNCE_MS = 500L
    }

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            refreshNetwork(network)
            onUpdateNetwork()
            super.onAvailable(network)
        }

        override fun onLosing(network: Network, maxMsToLive: Int) {
            val info = networkInfos[network] ?: NetworkInfo()
            info.losingMs = System.currentTimeMillis() + maxMsToLive
            networkInfos[network] = info
            onUpdateNetwork()
            super.onLosing(network, maxMsToLive)
        }

        override fun onLost(network: Network) {
            networkInfos.remove(network)
            onUpdateNetwork()
            super.onLost(network)
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            refreshNetwork(network)
            onUpdateNetwork()
            super.onCapabilitiesChanged(network, networkCapabilities)
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            refreshNetwork(network, linkProperties = linkProperties)
            onUpdateNetwork()
            super.onLinkPropertiesChanged(network, linkProperties)
        }
    }


    override fun onInstall() {
        preloadNetworks()
        applyNetworkUpdate()
        connectivity?.registerNetworkCallback(request, callback)
    }

    private fun preloadNetworks() {
        val cm = connectivity ?: return
        cm.allNetworks.forEach { network ->
            refreshNetwork(network, cm.getLinkProperties(network))
        }
    }

    private fun refreshNetwork(network: Network, linkProperties: LinkProperties? = null) {
        val cm = connectivity ?: return
        val capabilities = cm.getNetworkCapabilities(network) ?: run {
            networkInfos.remove(network)
            return
        }
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        ) {
            networkInfos.remove(network)
            return
        }
        val current = networkInfos[network] ?: NetworkInfo()
        val losingMs = current.losingMs
        val dnsList = (linkProperties ?: cm.getLinkProperties(network))?.dnsServers ?: current.dnsList
        networkInfos[network] = NetworkInfo(losingMs = losingMs, dnsList = dnsList)
    }

    private fun networkToInt(entry: Map.Entry<Network, NetworkInfo>): Int {
        val cm = connectivity ?: return 100
        val capabilities = cm.getNetworkCapabilities(entry.key) ?: return 100
        val linkProperties = cm.getLinkProperties(entry.key)
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && capabilities.hasTransport(
                TRANSPORT_USB
            ) -> 2

            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 3
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> 4
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM && capabilities.hasTransport(
                TRANSPORT_SATELLITE
            ) -> 5

            else -> 20
        } +
            (if (entry.value.isAvailable()) 0 else 10) +
            (if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 0 else 10) +
            (if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                capabilities.hasCapability(NET_CAPABILITY_FOREGROUND)
            ) {
                0
            } else {
                5
            }) +
            (if (linkProperties?.dnsServers.isNullOrEmpty()) 20 else 0)
    }

    private fun prioritizedNetworks(): List<Map.Entry<Network, NetworkInfo>> {
        return networkInfos.entries
            .filter { connectivity?.getNetworkCapabilities(it.key) != null }
            .sortedBy(::networkToInt)
    }

    private fun scheduleUpdate() {
        debounceJob?.cancel()
        debounceJob = debounceScope.launch {
            delay(DEBOUNCE_MS)
            applyNetworkUpdate()
        }
    }

    fun onUpdateNetwork(allowClearDns: Boolean = false) {
        if (allowClearDns) {
            // Direct call for cleanup on uninstall, no debounce needed
            applyNetworkUpdate(allowClearDns = true)
        } else {
            scheduleUpdate()
        }
    }

    private fun applyNetworkUpdate(allowClearDns: Boolean = false) {
        try {
        val prioritizedNetworks = prioritizedNetworks()
        val dnsList = prioritizedNetworks
            .firstOrNull { it.value.dnsList.isNotEmpty() }
            ?.value
            ?.dnsList
            ?.map { x -> x.asSocketAddressText(53) }
            ?: if (allowClearDns) {
                emptyList()
            } else {
                preDnsList
            }
        if (dnsList == preDnsList) {
            updateUnderlyingNetworks(prioritizedNetworks)
            return
        }
        preDnsList = dnsList
        Core.updateDNS(dnsList.toSet().joinToString(","))
        updateUnderlyingNetworks(prioritizedNetworks)
        } catch (e: Exception) {
            com.follow.clash.common.GlobalState.log("applyNetworkUpdate error: ${e.message}")
        }
    }

    private fun updateUnderlyingNetworks(prioritizedNetworks: List<Map.Entry<Network, NetworkInfo>>) {
        if (service !is VpnService || Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return
        }
        val networks = prioritizedNetworks.map { it.key }
        if (networks == preUnderlyingNetworks) {
            return
        }
        preUnderlyingNetworks = networks
        service.setUnderlyingNetworks(networks.toTypedArray().takeIf { it.isNotEmpty() })
    }

    override fun onUninstall() {
        debounceJob?.cancel()
        connectivity?.unregisterNetworkCallback(callback)
        networkInfos.clear()
        preUnderlyingNetworks = emptyList()
        onUpdateNetwork(allowClearDns = true)
    }
}

fun InetAddress.asSocketAddressText(port: Int): String {
    return when (this) {
        is Inet6Address -> "[${numericToTextFormat(this)}]:$port"

        is Inet4Address -> "${this.hostAddress}:$port"

        else -> throw IllegalArgumentException("Unsupported Inet type ${this.javaClass}")
    }
}

private fun numericToTextFormat(address: Inet6Address): String {
    val src = address.address
    val sb = StringBuilder(39)
    for (i in 0 until 8) {
        sb.append(
            Integer.toHexString(
                src[i shl 1].toInt() shl 8 and 0xff00 or (src[(i shl 1) + 1].toInt() and 0xff)
            )
        )
        if (i < 7) {
            sb.append(":")
        }
    }
    if (address.scopeId > 0) {
        sb.append("%")
        sb.append(address.scopeId)
    }
    return sb.toString()
}

package com.follow.clash.core

import java.net.InetSocketAddress

data object Core {
    private external fun startTun(
        fd: Int,
        mtu: Int,
        cb: TunInterface,
        stack: String,
        address: String,
        dns: String,
    )

    external fun forceGC(
    )

    external fun updateDNS(
        dns: String,
    )

    private fun parseInetSocketAddress(address: String): InetSocketAddress {
        // address format: "ip:port" or "[ipv6]:port"
        val lastColon = address.lastIndexOf(':')
        val host = address.substring(0, lastColon).removeSurrounding("[", "]")
        val port = address.substring(lastColon + 1).toInt()
        return InetSocketAddress.createUnresolved(host, port)
    }

    fun startTun(
        fd: Int,
        mtu: Int,
        protect: (Int) -> Boolean,
        resolverProcess: (protocol: Int, source: InetSocketAddress, target: InetSocketAddress, uid: Int) -> String,
        stack: String,
        address: String,
        dns: String,
    ) {
        startTun(
            fd,
            mtu,
            object : TunInterface {
                override fun protect(fd: Int) {
                    try {
                        protect(fd)
                    } catch (e: Throwable) {
                        android.util.Log.e("FlClash", "protect exception", e)
                    }
                }

                override fun resolverProcess(
                    protocol: Int,
                    source: String,
                    target: String,
                    uid: Int
                ): String {
                    return try {
                        resolverProcess(
                            protocol,
                            parseInetSocketAddress(source),
                            parseInetSocketAddress(target),
                            uid,
                        )
                    } catch (e: Throwable) {
                        android.util.Log.e("FlClash", "resolverProcess exception", e)
                        ""
                    }
                }
            },
            stack,
            address,
            dns
        )
    }

    external fun suspended(
        suspended: Boolean,
    )

    private external fun invokeAction(
        data: String,
        cb: InvokeInterface
    )

    fun invokeAction(
        data: String,
        cb: (result: String?) -> Unit
    ) {
        invokeAction(
            data,
            object : InvokeInterface {
                override fun onResult(result: String?) {
                    try {
                        cb(result)
                    } catch (e: Throwable) {
                        android.util.Log.e("FlClash", "invokeAction callback exception", e)
                    }
                }
            },
        )
    }

    private external fun setEventListener(cb: InvokeInterface?)

    fun callSetEventListener(
        cb: ((result: String?) -> Unit)?
    ) {
        when (cb != null) {
            true -> setEventListener(
                object : InvokeInterface {
                    override fun onResult(result: String?) {
                        try {
                            cb(result)
                        } catch (e: Throwable) {
                            android.util.Log.e("FlClash", "callSetEventListener callback exception", e)
                        }
                    }
                },
            )

            false -> setEventListener(null)
        }
    }

    fun quickSetup(
        initParamsString: String,
        setupParamsString: String,
        cb: (result: String?) -> Unit,
    ) {
        quickSetup(
            initParamsString,
            setupParamsString,
            object : InvokeInterface {
                override fun onResult(result: String?) {
                    try {
                        cb(result)
                    } catch (e: Throwable) {
                        android.util.Log.e("FlClash", "quickSetup callback exception", e)
                    }
                }
            },
        )
    }

    private external fun quickSetup(
        initParamsString: String,
        setupParamsString: String,
        cb: InvokeInterface
    )

    external fun stopTun()

    external fun getTraffic(onlyStatisticsProxy: Boolean): String

    external fun getTotalTraffic(onlyStatisticsProxy: Boolean): String

    init {
        System.loadLibrary("core")
    }
}
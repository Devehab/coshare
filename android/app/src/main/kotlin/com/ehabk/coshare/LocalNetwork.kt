package com.ehabk.coshare

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Socket

/** What CoShare needs to know about the local networks: gateways, changes, and which network reaches an address. */
class LocalNetwork(context: Context) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    @Suppress("DEPRECATION")
    private fun lanNetworks(): List<Pair<Network, LinkProperties>> = cm.allNetworks.mapNotNull { network ->
        val caps = cm.getNetworkCapabilities(network) ?: return@mapNotNull null
        val lan = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        if (!lan) return@mapNotNull null
        cm.getLinkProperties(network)?.let { network to it }
    }

    /**
     * IPv4 gateways of the Wi-Fi / Ethernet networks. On a phone's hotspot that's the phone itself (192.168.43.1,
     * 172.20.10.1, …): greeting it directly is what makes the hotspot case work without mDNS.
     */
    fun gateways(): List<String> = lanNetworks().flatMap { (_, lp) ->
        lp.routes.filter { it.isDefaultRoute && it.gateway is Inet4Address && !it.gateway!!.isAnyLocalAddress }
            .mapNotNull { it.gateway?.hostAddress }
    }.distinct()

    /** Changes whenever we join another network or the gateway moves; "offline" without any LAN. */
    fun signature(): String {
        val parts = lanNetworks().map { (_, lp) ->
            lp.interfaceName + "=" + lp.linkAddresses.joinToString(",") { it.toString() } + "|" +
                lp.routes.filter { it.isDefaultRoute }.joinToString(",") { it.gateway?.hostAddress ?: "" }
        }.sorted()
        return if (parts.isEmpty()) "offline" else parts.joinToString(";")
    }

    /**
     * When Wi-Fi has no internet, Android may send traffic over mobile data by default, and LAN addresses become
     * unreachable. Bind each outgoing socket to the network whose subnet contains the address.
     */
    fun bindToLan(socket: Socket, host: String) {
        val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return
        if (address.isLoopbackAddress) return
        val network = lanNetworks().firstOrNull { (_, lp) -> lp.routes.any { !it.isDefaultRoute && it.matches(address) } }?.first
            ?: return
        if (network == cm.activeNetwork) return
        runCatching { network.bindSocket(socket) }
    }

    /** Calls `onChange(signature)` (on the main thread, debounced) when Wi-Fi / Ethernet networks come, go or change. */
    fun watch(onChange: (String) -> Unit) {
        var pending: Runnable? = null
        fun changed() {
            pending?.let { main.removeCallbacks(it) }
            pending = Runnable { onChange(signature()) }.also { main.postDelayed(it, 1500) }
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = changed()
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { cm.registerNetworkCallback(request, callback) }
        main.post { onChange(signature()) }
    }
}

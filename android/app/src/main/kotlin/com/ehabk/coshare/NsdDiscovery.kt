package com.ehabk.coshare

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.RequiresApi
import com.ehabk.coshare.core.DiscoveredService
import com.ehabk.coshare.core.LocalIdentity
import com.ehabk.coshare.core.ServiceDiscovery
import com.ehabk.coshare.core.Wire
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executor

/**
 * mDNS through Android's NsdManager: advertises this device as _coshare._tcp with the same TXT record as the
 * Apple and desktop apps, and finds the others. Android 14+ follows each service live; older versions resolve one
 * service at a time (the platform refuses parallel resolves) and look again on every refresh.
 */
class NsdDiscovery(context: Context) : ServiceDiscovery {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val thread = HandlerThread("coshare-nsd").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private var session: Session? = null

    override fun start(me: LocalIdentity, port: Int, onServices: (List<DiscoveredService>) -> Unit, onEvent: (String, Boolean) -> Unit) {
        handler.post {
            session?.end()
            session = Session(me, port, onServices, onEvent).also { it.begin() }
        }
    }

    override fun refresh() {
        handler.post { session?.refresh() }
    }

    override fun stop() {
        handler.post {
            session?.end()
            session = null
        }
    }

    /** One advertise + browse run; every callback hops onto `handler`, so state needs no locks. */
    private inner class Session(
        private val me: LocalIdentity,
        private val port: Int,
        private val onServices: (List<DiscoveredService>) -> Unit,
        private val onEvent: (String, Boolean) -> Unit,
    ) {
        private var ended = false
        private var registered = false
        private var discovering = false
        private val found = LinkedHashMap<String, NsdServiceInfo>()
        private val resolved = HashMap<String, DiscoveredService>()
        private val resolveQueue = ArrayDeque<NsdServiceInfo>()
        private var resolving = false
        private val callbacks = HashMap<String, NsdManager.ServiceInfoCallback>()
        private var registration: NsdManager.RegistrationListener? = null
        private var discovery: NsdManager.DiscoveryListener? = null
        private var registerFailures = 0
        private var discoverFailures = 0

        /** Retries back off (5 s, 10 s … 1 min) and only the first failure goes in the activity log. */
        private fun retryDelay(failures: Int) = minOf(60_000L, 5000L shl minOf(failures - 1, 4))

        fun begin() {
            register()
            discover()
        }

        fun refresh() {
            if (ended) return
            if (!registered && registration == null) register()
            if (!discovering && discovery == null) discover()
            // Without live callbacks, TXT changes (new groups, a new name) are only seen by resolving again.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) found.values.forEach(::enqueueResolve)
        }

        fun end() {
            ended = true
            registration?.let { runCatching { nsd.unregisterService(it) } }
            registration = null
            discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
            discovery = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                callbacks.values.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
            }
            callbacks.clear()
        }

        private fun register() {
            val info = NsdServiceInfo().apply {
                serviceName = me.id
                serviceType = Wire.SERVICE_TYPE
                setPort(port)
                for ((key, value) in me.txtRecord()) {
                    // A record that grew past the platform's limit just loses that entry (e.g. a 9th group).
                    try {
                        setAttribute(key, value)
                    } catch (_: IllegalArgumentException) {
                    }
                }
            }
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) = post {
                    registered = true
                    registerFailures = 0
                }
                override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) = post {
                    registration = null
                    if (++registerFailures == 1) onEvent("تعذّر الإعلان عن هذا الجهاز على الشبكة (رمز $error) — إعادة المحاولة", true)
                    handler.postDelayed({ if (!ended && registration == null) register() }, retryDelay(registerFailures))
                }
                override fun onServiceUnregistered(info: NsdServiceInfo) = post { registered = false }
                override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) {}
            }
            registration = listener
            try {
                nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (e: Exception) {
                registration = null
                onEvent("تعذّر الإعلان عن هذا الجهاز على الشبكة: ${e.message}", true)
            }
        }

        private fun discover() {
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) = post {
                    discovering = true
                    discoverFailures = 0
                }
                override fun onDiscoveryStopped(serviceType: String) = post { discovering = false }
                override fun onStartDiscoveryFailed(serviceType: String, error: Int) = post {
                    discovery = null
                    if (++discoverFailures == 1) onEvent("تعذّر البحث عن الأجهزة (رمز $error) — إعادة المحاولة", true)
                    handler.postDelayed({ if (!ended && discovery == null) discover() }, retryDelay(discoverFailures))
                }
                override fun onStopDiscoveryFailed(serviceType: String, error: Int) {}
                override fun onServiceFound(info: NsdServiceInfo) = post {
                    if (info.serviceName == me.id) return@post
                    found[info.serviceName] = info
                    follow(info)
                }
                override fun onServiceLost(info: NsdServiceInfo) = post {
                    found.remove(info.serviceName)
                    unfollow(info.serviceName)
                    if (resolved.remove(info.serviceName) != null) publish()
                }
            }
            discovery = listener
            try {
                nsd.discoverServices(Wire.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (e: Exception) {
                discovery = null
                onEvent("تعذّر البحث عن الأجهزة: ${e.message}", true)
            }
        }

        private fun follow(info: NsdServiceInfo) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) followLive(info) else enqueueResolve(info)
        }

        @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        private fun followLive(info: NsdServiceInfo) {
            if (info.serviceName in callbacks) return
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(error: Int) = post {
                    callbacks.remove(info.serviceName)
                    enqueueResolve(info)
                }
                override fun onServiceUpdated(updated: NsdServiceInfo) = post { store(info.serviceName, updated) }
                override fun onServiceLost() = post {
                    if (resolved.remove(info.serviceName) != null) publish()
                }
                override fun onServiceInfoCallbackUnregistered() {}
            }
            callbacks[info.serviceName] = callback
            try {
                nsd.registerServiceInfoCallback(info, executor, callback)
            } catch (_: Exception) {
                callbacks.remove(info.serviceName)
                enqueueResolve(info)
            }
        }

        private fun unfollow(name: String) {
            val callback = callbacks.remove(name) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) runCatching { nsd.unregisterServiceInfoCallback(callback) }
        }

        private fun enqueueResolve(info: NsdServiceInfo) {
            if (resolveQueue.none { it.serviceName == info.serviceName }) resolveQueue.addLast(info)
            resolveNext()
        }

        @Suppress("DEPRECATION")
        private fun resolveNext() {
            if (resolving || ended) return
            val info = resolveQueue.removeFirstOrNull() ?: return
            if (info.serviceName !in found) return resolveNext()
            resolving = true
            val listener = object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, error: Int) = post {
                    resolving = false
                    // Busy (another resolve still running somewhere): try again shortly.
                    if (error == NsdManager.FAILURE_ALREADY_ACTIVE) handler.postDelayed({ enqueueResolve(info) }, 500)
                    resolveNext()
                }
                override fun onServiceResolved(info: NsdServiceInfo) = post {
                    resolving = false
                    store(info.serviceName, info)
                    resolveNext()
                }
            }
            try {
                nsd.resolveService(info, listener)
            } catch (_: Exception) {
                resolving = false
                handler.postDelayed({ resolveNext() }, 500)
            }
        }

        @Suppress("DEPRECATION")
        private fun store(name: String, info: NsdServiceInfo) {
            if (ended || name !in found) return
            val addresses: List<InetAddress> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                info.hostAddresses
            } else {
                listOfNotNull(info.host)
            }
            val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull() ?: return
            val txt = info.attributes.mapValues { (_, value) -> value?.toString(Charsets.UTF_8) ?: "" }
            resolved[name] = DiscoveredService(name, txt, address.hostAddress ?: return, info.port)
            publish()
        }

        private fun publish() {
            if (!ended) onServices(resolved.values.toList())
        }

        private fun post(block: () -> Unit) {
            handler.post { if (!ended) block() }
        }
    }
}

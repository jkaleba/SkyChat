package com.offlinegroupmessenger.offline_connectivity

import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Handler
import android.os.SystemClock
import android.util.Log

/** App-only DNS-SD records. Never publishes network/admission credentials. */
internal class PublicGroupDiscovery(
    private val manager: WifiP2pManager,
    private val handler: Handler,
    private val onPeers: (List<Map<String, Any>>) -> Unit,
    private val onAdvertiseError: () -> Unit,
    private val onSearchFinished: () -> Unit
) {
    private var channel: WifiP2pManager.Channel? = null
    private var service: WifiP2pDnsSdServiceInfo? = null
    private var request: WifiP2pDnsSdServiceRequest? = null
    private var advertised = false
    private var advertisedPrivate = false
    private var advertisedContactId: String? = null
    private var advertisedHostName: String? = null
    private var privateSessionId: String? = null
    private var advertisementRevision = 0
    private var scanRevision = 0
    private var scanning = false
    private val peers = linkedMapOf<String, Pair<Map<String, Any>, Long>>()

    fun attach(value: WifiP2pManager.Channel) {
        if (channel === value) return
        close()
        channel = value
        manager.setDnsSdResponseListeners(value, { _, _, _ -> }, { domain, record, device ->
            if (channel === value && scanning && PublicGroupRecord.accepts(domain, record)) {
                val isPrivate = record["mode"] == "private"
                val sessionId = record["sid"]
                val advertisedName = record["name"]?.trim()?.takeIf { it.isNotEmpty() }
                Log.d("OfflineDiscovery", "TXT response accepted private=$isPrivate")
                peers[device.deviceAddress] = Pair(buildMap {
                    put("id", device.deviceAddress)
                    put(
                        "name",
                        if (isPrivate) "Private group ${sessionId?.take(6)}" else advertisedName
                            ?: device.deviceName?.takeIf { it.isNotBlank() }
                            ?: if (isPrivate) "Private group" else "Public group"
                    )
                    put("isGroupOwner", true)
                    put("privateGroup", isPrivate)
                }, SystemClock.elapsedRealtime())
                publishPeers()
            }
        })
    }

    fun advertise(
        enabled: Boolean,
        privateGroup: Boolean = false,
        hostContactId: String? = null,
        hostName: String? = null
    ) {
        val ch = channel ?: return
        if (enabled == advertised &&
            (!enabled || (privateGroup == advertisedPrivate && hostContactId == advertisedContactId && hostName == advertisedHostName))) {
            return
        }
        if (enabled && privateGroup && !advertised) {
            privateSessionId = java.util.UUID.randomUUID().toString().replace("-", "")
        }
        advertised = enabled
        advertisedPrivate = privateGroup
        advertisedContactId = hostContactId
        advertisedHostName = hostName
        val revision = ++advertisementRevision
        service?.let { try { manager.removeLocalService(ch, it, null) } catch (_: RuntimeException) {} }
        service = null
        if (!enabled) return
        val info = WifiP2pDnsSdServiceInfo.newInstance(
            PublicGroupRecord.INSTANCE, PublicGroupRecord.TYPE,
            PublicGroupRecord.fields(
                privateGroup = privateGroup,
                hostContactId = hostContactId,
                hostName = hostName,
                sessionId = privateSessionId
            ) + ("advertisement" to revision.toString())
        )
        service = info
        try {
            manager.addLocalService(ch, info, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d("OfflineDiscovery", "Advertisement registered")
                    if (channel !== ch || revision != advertisementRevision || !advertised) {
                        try { manager.removeLocalService(ch, info, null) } catch (_: RuntimeException) {}
                    }
                }
                override fun onFailure(reason: Int) {
                    if (channel === ch && revision == advertisementRevision) {
                        advertised = false
                        Log.d("OfflineDiscovery", "Advertisement failed: $reason")
                        onAdvertiseError()
                    }
                }
            })
        } catch (_: RuntimeException) { advertised = false; onAdvertiseError() }
    }

    fun search(listener: WifiP2pManager.ActionListener) {
        val ch = channel ?: run { listener.onFailure(WifiP2pManager.ERROR); return }
        stopSearch()
        scanning = true
        val revision = scanRevision
        fun valid() = channel === ch && scanning && revision == scanRevision
        var cycle = 0
        var started = false
        var lastError = WifiP2pManager.ERROR
        fun runCycle() {
            if (!valid()) return
            if (cycle == 4) {
                scanning = false
                request?.let { try { manager.removeServiceRequest(ch, it, null) } catch (_: RuntimeException) {} }
                request = null
                try { manager.stopPeerDiscovery(ch, null) } catch (_: RuntimeException) {}
                Log.d("OfflineDiscovery", "Search finished; public results=${peers.size}")
                if (!started) listener.onFailure(lastError)
                onSearchFinished()
                return
            }
            val currentCycle = ++cycle
            fun current() = valid() && currentCycle == cycle
            // Some OEMs answer the all-services request more reliably than a
            // targeted TXT query. Both routes still require validated public TXT.
            val req = if (cycle == 1)
                WifiP2pDnsSdServiceRequest.newInstance(PublicGroupRecord.INSTANCE, PublicGroupRecord.TYPE)
                else WifiP2pDnsSdServiceRequest.newInstance()
            request = req
            Log.d("OfflineDiscovery", "Search cycle $cycle (${if (cycle == 1) "TXT" else "all DNS-SD"})")
            var busyRetries = 0
            fun configure() {
                if (!current()) return
                fun failed(reason: Int) {
                    if (!current()) return
                    lastError = reason
                    Log.d("OfflineDiscovery", "Search operation failed: $reason")
                    if (reason == WifiP2pManager.BUSY && busyRetries < 4) {
                        busyRetries++
                        handler.postDelayed({ configure() }, 400L * busyRetries)
                    }
                }
                try { manager.clearServiceRequests(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        if (!current()) return
                        try { manager.addServiceRequest(ch, req, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {
                                if (!current()) return
                                try { manager.discoverServices(ch, object : WifiP2pManager.ActionListener {
                                    override fun onSuccess() {
                                        if (current()) {
                                            Log.d("OfflineDiscovery", "Discovery started")
                                            if (!started) { started = true; listener.onSuccess() }
                                        }
                                    }
                                    override fun onFailure(reason: Int) = failed(reason)
                                }) } catch (_: RuntimeException) { failed(WifiP2pManager.ERROR) }
                            }
                            override fun onFailure(reason: Int) = failed(reason)
                        }) } catch (_: RuntimeException) { failed(WifiP2pManager.ERROR) }
                    }
                    override fun onFailure(reason: Int) = failed(reason)
                }) } catch (_: RuntimeException) { failed(WifiP2pManager.ERROR) }
            }
            try { manager.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = configure()
                override fun onFailure(reason: Int) = configure()
            }) } catch (_: RuntimeException) {
                lastError = WifiP2pManager.ERROR
            }
            handler.postDelayed({ runCycle() }, 12_000)
        }
        runCycle()
        fun expire() {
            if (channel !== ch || revision != scanRevision) return
            val cutoff = SystemClock.elapsedRealtime() - 60_000
            if (peers.entries.removeAll { it.value.second < cutoff }) publishPeers()
            if (scanning || peers.isNotEmpty()) handler.postDelayed({ expire() }, 5_000)
        }
        handler.postDelayed({ expire() }, 5_000)
    }

    private fun publishPeers() = onPeers(peers.values.map { it.first }.sortedBy { it["name"].toString() })

    fun stopSearch(stopNativeDiscovery: Boolean = true, onStopped: (() -> Unit)? = null) {
        val wasScanning = scanning
        scanning = false
        scanRevision++
        val ch = channel
        val req = request
        request = null
        if (ch != null && req != null) {
            try { manager.removeServiceRequest(ch, req, null) } catch (_: RuntimeException) {}
        }
        peers.clear()
        onPeers(emptyList())
        // STOP_DISCOVERY can flush Android's peer table. MAC-address joining
        // must only detach our callbacks; connect stops the native scan itself.
        if (stopNativeDiscovery && ch != null && (wasScanning || onStopped != null)) {
            try { manager.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { onStopped?.invoke() }
                override fun onFailure(reason: Int) { onStopped?.invoke() }
            }) } catch (_: RuntimeException) { onStopped?.invoke() }
        } else onStopped?.invoke()
    }

    fun isSearching() = scanning

    fun close() {
        advertise(false)
        stopSearch()
        channel = null
    }
}

package com.sondermium.chatblue

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.NetworkInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.WpsInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Manages Wi‑Fi Direct (Wi‑Fi P2P) discovery and a single TCP socket connection.
 * Exposes callbacks to bridge events to Flutter via platform channels.
 */
class WifiDirectManager(private val context: Context) {

    private val manager: WifiP2pManager? = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var channel: WifiP2pManager.Channel? = manager?.initialize(context, context.mainLooper, null)

    /// Set when the P2P service went down (WIFI_P2P_STATE_DISABLED): a
    /// channel obtained before the restart is STALE and every operation on
    /// it fails instantly (ERROR/BUSY, request never leaves the device) —
    /// the classic "connects once, then never again". The channel is
    /// re-initialized on the next ENABLED broadcast (and defensively in
    /// [connect]).
    private var channelDirty: Boolean = false

    private val peersByAddress: MutableMap<String, Map<String, Any?>> = ConcurrentHashMap()
    private val discoveryRegistered = AtomicBoolean(false)
    private var p2pEnabled: Boolean = false

    /// This device's current P2P MAC (from THIS_DEVICE_CHANGED). The peer
    /// can't learn it from the socket, and it keys the peer's chat session —
    /// sent to the peer inside the identity frame.
    private var thisDeviceAddress: String? = null

    /// Ensures `onSocketDisconnected` fires at most ONCE per connection
    /// episode. A teardown triggers up to three events (TCP EOF, the
    /// CONNECTION_CHANGED broadcast branch and `disconnect()`'s own cancel)
    /// and each used to surface a separate "connection lost" snackbar on the
    /// peer. Reset in [manageConnectedSocket] for the next episode.
    private val disconnectNotified = AtomicBoolean(false)

    /// True while THIS device is the explicit Group Owner (Start Server via
    /// createGroup). Used by [disconnect] to preserve the group+server for
    /// peer reconnects, while still tearing the group down after ordinary
    /// client-mode chat sessions (a lingering group blocks the next connect
    /// with BUSY on OEM builds).
    private val groupOwnerMode = AtomicBoolean(false)

    private var onScanStarted: (() -> Unit)? = null
    private var onPeerFound: ((Map<String, Any?>) -> Unit)? = null
    private var onScanFinished: (() -> Unit)? = null
    private var onScanError: ((String) -> Unit)? = null

    private var onSocketConnected: ((Map<String, Any?>) -> Unit)? = null
    private var onSocketDisconnected: ((String) -> Unit)? = null
    private var onBytesReceived: ((ByteArray) -> Unit)? = null
    private var onTextReceived: ((String) -> Unit)? = null
    private var onSocketError: ((String) -> Unit)? = null
    private var onTransferProgress: ((String, Int, Int, String) -> Unit)? = null

    private var serverThread: ServerThread? = null
    private var clientThread: ClientThread? = null
    private var connectedThread: ConnectedThread? = null
    private var lastConnectAddress: String? = null
    private var retriedOnce: Boolean = false

    private val ioExecutor = Executors.newSingleThreadExecutor()

    private companion object {
        const val FRAME_TYPE_TEXT: Byte = 1
        const val FRAME_TYPE_BYTES: Byte = 2
        const val PORT: Int = 8988 // Align with Android Wi‑Fi Direct sample conventions

        /// Backoff before the connect retry: after a group teardown the P2P
        /// service restarts and a connect issued during the restart fails
        /// with BUSY/ERROR; 1.5 s was too short on OEM builds.
        const val RETRY_DELAY_MS: Long = 5000
    }

    fun setScanCallbacks(
        onStarted: (() -> Unit)?,
        onPeerFound: ((Map<String, Any?>) -> Unit)?,
        onFinished: (() -> Unit)?,
        onError: ((String) -> Unit)?,
    ) {
        this.onScanStarted = onStarted
        this.onPeerFound = onPeerFound
        this.onScanFinished = onFinished
        this.onScanError = onError
    }

    fun setSocketCallbacks(
        onConnected: ((Map<String, Any?>) -> Unit)?,
        onDisconnected: ((String) -> Unit)?,
        onBytesReceived: ((ByteArray) -> Unit)?,
        onError: ((String) -> Unit)?,
        onTextReceived: ((String) -> Unit)? = null,
        onProgress: ((String, Int, Int, String) -> Unit)? = null,
    ) {
        this.onSocketConnected = onConnected
        this.onSocketDisconnected = onDisconnected
        this.onBytesReceived = onBytesReceived
        this.onSocketError = onError
        this.onTextReceived = onTextReceived
        this.onTransferProgress = onProgress
    }

    fun isP2pSupported(): Boolean = manager != null && channel != null

    fun getThisDeviceAddress(): String? = thisDeviceAddress

    fun getDiscoveredPeers(): List<Map<String, Any?>> = peersByAddress.values.toList()

    fun clearDiscoveredPeers() { peersByAddress.clear() }

    fun isConnected(): Boolean = connectedThread?.isActive() == true

    fun dispose() {
        tryUnregisterReceiver()
        stopDiscovery()
        removeGroup()
        disconnect()
        ioExecutor.shutdownNow()
    }

    /// Returns a channel that is fresh: when the P2P service restarted since
    /// our last use (teardown or a DISABLED broadcast), re-initializes —
    /// a stale channel fails every operation instantly (ERROR/BUSY).
    private fun effectiveChannel(): WifiP2pManager.Channel? {
        if (channelDirty) {
            channelDirty = false
            channel = manager?.initialize(context, context.mainLooper, null)
        }
        return channel
    }

    fun startDiscovery() {
        val m = manager ?: return onScanError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = effectiveChannel() ?: return onScanError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        if (!hasDiscoveryPermission()) {
            onScanError?.invoke("Missing Wi‑Fi Direct discovery permission")
            return
        }
        tryRegisterReceiver()
        peersByAddress.clear()
        onScanStarted?.invoke()
        m.discoverPeers(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { /* wait for peers changed */ }
            override fun onFailure(reason: Int) { onScanError?.invoke("discoverPeers failed: $reason") }
        })
    }

    fun stopDiscovery() {
        val m = manager ?: return
        val c = channel ?: return
        m.stopPeerDiscovery(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { onScanFinished?.invoke() }
            override fun onFailure(reason: Int) { onScanFinished?.invoke() }
        })
    }

    /// Refreshes the peer list from the framework and pushes every device
    /// to [onPeerFound]. Also exposed to Dart: some OEM stacks
    /// (MIUI/HyperOS) never deliver PEERS_CHANGED, so scanning flows poll
    /// this instead of relying on the broadcast.
    @SuppressLint("MissingPermission")
    fun requestPeers() {
        val m = manager ?: return
        val c = effectiveChannel() ?: return
        if (!hasDiscoveryPermission()) return
        tryRegisterReceiver()
        m.requestPeers(c) { list: WifiP2pDeviceList ->
            list.deviceList?.forEach { d: WifiP2pDevice ->
                val mapped = deviceToMap(d)
                peersByAddress[d.deviceAddress] = mapped
                onPeerFound?.invoke(mapped)
            }
        }
    }

    fun createGroup() {
        groupOwnerMode.set(true)
        val m = manager ?: return onSocketError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = effectiveChannel() ?: return onSocketError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        m.createGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                // Start server immediately; ServerSocket can bind without waiting IP
                startServerSocket()
                // Also proactively query connection info; some devices don't fire connected immediately
                Handler(Looper.getMainLooper()).postDelayed({ requestConnectionInfo() }, 600)
            }
            override fun onFailure(reason: Int) {
                groupOwnerMode.set(false)
                onSocketError?.invoke("createGroup failed: $reason")
            }
        })
    }

    fun removeGroup(listener: WifiP2pManager.ActionListener? = null) {
        groupOwnerMode.set(false)
        val m = manager ?: return
        val c = channel ?: return
        if (listener != null) {
            m.removeGroup(c, listener)
        } else {
            m.removeGroup(c, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { }
                override fun onFailure(reason: Int) { }
            })
        }
    }

    fun connect(deviceAddress: String) {
        val m = manager ?: return onSocketError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        // Defensive channel refresh: if the P2P service restarted since our
        // last use, the old channel would fail every call instantly.
        val c = effectiveChannel() ?: return onSocketError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        // NOTE: deliberately NO hard `p2pEnabled` guard here. The flag is
        // only updated by explicit state broadcasts and turns stale when the
        // framework silently re-enables P2P (e.g. through discoverPeers
        // without a broadcast) — a stale false flag rejected every connect
        // after the first session ("connects once, then never again").
        // The framework itself reports real failures (P2P_UNSUPPORTED /
        // ERROR) through the attempt callbacks below.
        if (!isWifiEnabled()) {
            onSocketError?.invoke("Wi‑Fi is disabled")
            return
        }
        if (!hasDiscoveryPermission()) {
            onSocketError?.invoke("Missing permission for Wi‑Fi Direct (Nearby/Location)")
            return
        }
        if (!isLocationOn()) {
            // On many devices, location must be enabled for P2P discovery/connect to succeed
            onSocketError?.invoke("Location is turned off")
            return
        }

        if (lastConnectAddress != deviceAddress) {
            lastConnectAddress = deviceAddress
        }
        // ALWAYS reset the retry budget: it used to reset only on address
        // change, so a second connect to the SAME peer had retriedOnce=true
        // from the previous session and skipped its retry entirely —
        // "connect failed: ERROR (0)" appeared immediately instead of
        // retrying through the P2P service restart.
        retriedOnce = false

        // Ignore obviously invalid addresses
        if (deviceAddress.isBlank() || deviceAddress == "02:00:00:00:00:00") {
            onSocketError?.invoke("Invalid device address: $deviceAddress")
            return
        }

        // Best-effort: cancel discovery/connect before a new connect
        runCatching { m.cancelConnect(c, null) }
        runCatching { m.stopPeerDiscovery(c, null) }
        // Ensure we are not part of a previous group before attempting
        // connect — and WAIT for the removal: on Samsung/OEM builds a
        // lingering group (left from the previous session's connection)
        // makes an immediate connect fail with BUSY.
        removeGroup(object : WifiP2pManager.ActionListener {
            override fun onSuccess() { attemptConnect(deviceAddress, goIntent = 0) }
            override fun onFailure(reason: Int) {
                // Even a rejected removal is a state change; try anyway.
                attemptConnect(deviceAddress, goIntent = 0)
            }
        })
    }

    private fun attemptConnect(deviceAddress: String, goIntent: Int) {
        val m = manager ?: return onSocketError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = channel ?: return onSocketError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = goIntent.coerceIn(0, 15)
        }
        Handler(Looper.getMainLooper()).postDelayed({
            m.connect(c, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { /* Await WIFI_P2P_CONNECTION_CHANGED_ACTION -> requestConnectionInfo */ }
                override fun onFailure(reason: Int) {
                    val message = "connect failed: ${reasonToString(reason)} ($reason)"
                    if ((reason == WifiP2pManager.BUSY || reason == WifiP2pManager.ERROR) && !retriedOnce) {
                        retriedOnce = true
                        // Flip GO intent and retry once
                        val nextIntent = if (goIntent < 8) 15 else 0
                        // Refresh peers before retry to avoid stale device addresses
                        runCatching {
                            m.discoverPeers(c, object : WifiP2pManager.ActionListener {
                                override fun onSuccess() {}
                                override fun onFailure(code: Int) {}
                            })
                        }
                        Handler(Looper.getMainLooper()).postDelayed({
                            attemptConnect(deviceAddress, nextIntent)
                        }, RETRY_DELAY_MS)
                    } else {
                        onSocketError?.invoke(message)
                    }
                }
            })
        }, 600)
    }

    private fun reasonToString(reason: Int): String = when (reason) {
        WifiP2pManager.ERROR -> "ERROR"
        WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
        WifiP2pManager.BUSY -> "BUSY"
        else -> "UNKNOWN"
    }

    fun isWifiEnabled(): Boolean {
        val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return wm?.isWifiEnabled == true
    }

    /// Opens the system Wi‑Fi settings panel (popup panel on Android 10+,
    /// settings screen below) so the user can turn Wi‑Fi on. Apps cannot
    /// enable Wi‑Fi silently since Android 10; the panel is the standard
    /// flow. Returns whether the launch was attempted.
    fun requestEnableWifi(): Boolean {
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.Panel.ACTION_WIFI)
            } else {
                Intent(Settings.ACTION_WIFI_SETTINGS)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun isLocationOn(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm?.isLocationEnabled == true
        } else {
            val gps = lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true
            val net = lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
            gps || net
        }
    }

    fun disconnect() {
        connectedThread?.cancel("manual")
        connectedThread = null
        clientThread?.cancel()
        clientThread = null
        serverThread?.cancel()
        serverThread = null
        // Tear down the P2P group when this was an ordinary (client-mode)
        // chat session: leaving the group behind keeps the P2P stack busy
        // and the NEXT connect fails with BUSY on OEM builds. Server mode
        // (explicit createGroup) keeps its group and accept loop so peers
        // can reconnect to the already-started server.
        if (!groupOwnerMode.get()) {
            removeGroup()
        }
        // A session ended: the P2P service may restart during teardown, so
        // the next operation must re-initialize the channel (broadcasts may
        // not always fire).
        channelDirty = true
    }

    fun sendText(text: String) {
        val payload = text.toByteArray(Charsets.UTF_8)
        connectedThread?.writeFramed(FRAME_TYPE_TEXT, payload)
    }

    fun sendRawBytes(data: ByteArray) {
        connectedThread?.writeFramed(FRAME_TYPE_BYTES, data)
    }

    private fun tryRegisterReceiver() {
        if (discoveryRegistered.compareAndSet(false, true)) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
            }
            context.registerReceiver(receiver, filter)
        }
    }

    private fun tryUnregisterReceiver() {
        if (discoveryRegistered.compareAndSet(true, false)) {
            try { context.unregisterReceiver(receiver) } catch (_: IllegalArgumentException) {}
        }
    }

    private fun hasDiscoveryPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private val receiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    p2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
                    // The P2P service restarts after a group teardown on
                    // most devices; a channel obtained before the restart is
                    // stale and every op on it fails instantly — the
                    // "connects once, then never again" class of bug. Grab a
                    // fresh channel when the service comes back up.
                    if (state == WifiP2pManager.WIFI_P2P_STATE_DISABLED) {
                        channelDirty = true
                    } else if (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED && channelDirty) {
                        channelDirty = false
                        channel = manager?.initialize(context, context.mainLooper, null)
                    }
                }
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> requestPeers()
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val networkInfo: NetworkInfo? = intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO)
                    if (networkInfo?.isConnected == true) {
                        // A group is up — peer discovery is no longer useful
                        // and most stacks drop it anyway; stop it so the
                        // UI's scanning state stays truthful and the stack
                        // stays free. No listener: this would otherwise emit
                        // a spurious "scan finished" event.
                        val m = manager ?: return
                        val c = channel ?: return
                        runCatching { m.stopPeerDiscovery(c, null) }
                        requestConnectionInfo()
                    } else {
                        // disconnected
                        if (disconnectNotified.compareAndSet(false, true)) {
                            onSocketDisconnected?.invoke("disconnected")
                        }
                        disconnect()
                    }
                }
                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    // Remember our own P2P MAC: the peer can't read it from
                    // the socket and needs it to key its chat session.
                    val device: WifiP2pDevice? =
                        if (Build.VERSION.SDK_INT >= 33) {
                            intent.getParcelableExtra(
                                WifiP2pManager.EXTRA_WIFI_P2P_DEVICE,
                                WifiP2pDevice::class.java,
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE)
                        }
                    val addr = device?.deviceAddress
                    // The framework often broadcasts the this-device record
                    // with the unresolved dummy MAC (02:00:00:00:00:00) until
                    // the real randomized P2P MAC is assigned — never cache
                    // the dummy; it would travel to the peer in the identity
                    // frame and become its session key.
                    if (!addr.isNullOrEmpty() && addr != "02:00:00:00:00:00") {
                        thisDeviceAddress = addr
                    }
                }
            }
        }
    }

    private fun requestConnectionInfo() {
        val m = manager ?: return
        val c = channel ?: return
        try {
            m.requestConnectionInfo(c) { info: WifiP2pInfo ->
                handleConnectionInfo(info)
            }
        } catch (_: SecurityException) {}
    }

    private fun deviceToMap(device: WifiP2pDevice): Map<String, Any?> {
        return mapOf(
            "deviceName" to device.deviceName,
            "deviceAddress" to device.deviceAddress,
            "status" to device.status
        )
    }

    private fun handleConnectionInfo(info: WifiP2pInfo) {
        if (info.groupFormed) {
            if (info.isGroupOwner) {
                startServerSocket()
            } else {
                val host = info.groupOwnerAddress?.hostAddress
                if (host != null) startClientSocket(host)
            }
        }
    }

    private fun startServerSocket() {
        serverThread?.cancel()
        serverThread = ServerThread().also { it.start() }
    }

    private fun startClientSocket(host: String) {
        clientThread?.cancel()
        clientThread = ClientThread(host).also { it.start() }
    }

    private inner class ServerThread : Thread("WdServerThread") {
        private var server: ServerSocket? = null
        private val cancelled = AtomicBoolean(false)

        init {
            try {
                server = ServerSocket()
                server?.reuseAddress = true
                server?.bind(InetSocketAddress(PORT))
            } catch (e: IOException) {
                onSocketError?.invoke("Server socket failed: ${e.message}")
            }
        }

        override fun run() {
            while (!cancelled.get()) {
                try {
                    val s = server?.accept()
                    if (s != null) handleAcceptedSocket(s)
                    // Keep accepting: previously connected peers can reconnect.
                    // A new peer replaces the current connection
                    // (manageConnectedSocket cancels it with "replaced").
                } catch (e: IOException) {
                    if (!cancelled.get()) onSocketError?.invoke("Accept failed: ${e.message}")
                    break
                }
            }
            cancel()
        }

        fun cancel() {
            cancelled.set(true)
            try { server?.close() } catch (_: IOException) {}
            server = null
        }
    }

    private inner class ClientThread(private val host: String) : Thread("WdClientThread") {
        private var socket: Socket? = null
        private val cancelled = AtomicBoolean(false)

        override fun run() {
            var attempt = 0
            while (!cancelled.get() && attempt < 5) {
                attempt += 1
                try {
                    val s = Socket()
                    s.connect(InetSocketAddress(host, PORT), 8000)
                    socket = s
                    manageConnectedSocket(s, isGroupOwner = false)
                    return
                } catch (e: IOException) {
                    if (attempt >= 5 || cancelled.get()) {
                        onSocketError?.invoke("Connect failed: ${e.message}")
                        break
                    }
                    try { Thread.sleep(700L * attempt) } catch (_: InterruptedException) {}
                }
            }
            cancel()
        }

        fun cancel() {
            cancelled.set(true)
            try { socket?.close() } catch (_: IOException) {}
            socket = null
        }
    }

    private inner class ConnectedThread(private val socket: Socket, private val isGroupOwner: Boolean) : Thread("WdConnectedThread") {
        private val input: InputStream? = try { socket.getInputStream() } catch (_: IOException) { null }
        private val output: OutputStream? = try { socket.getOutputStream() } catch (_: IOException) { null }
        private val active = AtomicBoolean(true)
        private var accumulator: ByteArray = ByteArray(0)

        override fun run() {
            val buffer = ByteArray(4096)
            var lastReason: String? = null
            while (active.get()) {
                try {
                    val read = input?.read(buffer) ?: -1
                    if (read == -1) { lastReason = "eof"; break }
                    val incoming = buffer.copyOf(read)
                    accumulator += incoming
                    if (accumulator.size >= 5) {
                        val type = accumulator[0]
                        val len = ((accumulator[1].toInt() and 0xFF) shl 24) or
                                  ((accumulator[2].toInt() and 0xFF) shl 16) or
                                  ((accumulator[3].toInt() and 0xFF) shl 8) or
                                  (accumulator[4].toInt() and 0xFF)
                        val cur = kotlin.math.max(0, kotlin.math.min(len, accumulator.size - 5))
                        val kind = if (type == FRAME_TYPE_BYTES) "bytes" else "text"
                        onTransferProgress?.invoke("in", cur, len, kind)
                    }
                    while (accumulator.size >= 5) {
                        val type = accumulator[0]
                        val len = ((accumulator[1].toInt() and 0xFF) shl 24) or
                                  ((accumulator[2].toInt() and 0xFF) shl 16) or
                                  ((accumulator[3].toInt() and 0xFF) shl 8) or
                                  (accumulator[4].toInt() and 0xFF)
                        if (accumulator.size < 5 + len) break
                        val payload = accumulator.copyOfRange(5, 5 + len)
                        accumulator = accumulator.copyOfRange(5 + len, accumulator.size)
                        if (type == FRAME_TYPE_TEXT) {
                            try {
                                val text = String(payload, Charsets.UTF_8)
                                onTextReceived?.invoke(text)
                            } catch (_: Exception) {
                                onSocketError?.invoke("Failed to decode text payload")
                            }
                        } else if (type == FRAME_TYPE_BYTES) {
                            onBytesReceived?.invoke(payload)
                        } else {
                            onSocketError?.invoke("Unknown frame type: $type")
                        }
                        val kind = if (type == FRAME_TYPE_BYTES) "bytes" else "text"
                        onTransferProgress?.invoke("in", len, len, kind)
                    }
                } catch (e: IOException) {
                    if (active.get()) lastReason = "io: ${e.message}"
                    break
                }
            }
            cancel(lastReason ?: "stopped")
        }

        fun writeFramed(type: Byte, payload: ByteArray) {
            ioExecutor.execute {
                try {
                    val header = ByteArray(5)
                    header[0] = type
                    val len = payload.size
                    header[1] = ((len ushr 24) and 0xFF).toByte()
                    header[2] = ((len ushr 16) and 0xFF).toByte()
                    header[3] = ((len ushr 8) and 0xFF).toByte()
                    header[4] = (len and 0xFF).toByte()
                    output?.write(header)
                    onTransferProgress?.invoke("out", 0, len, if (type == FRAME_TYPE_BYTES) "bytes" else "text")
                    var written = 0
                    val chunk = ByteArray(8192)
                    var offset = 0
                    while (offset < payload.size) {
                        val toWrite = kotlin.math.min(chunk.size, payload.size - offset)
                        System.arraycopy(payload, offset, chunk, 0, toWrite)
                        output?.write(chunk, 0, toWrite)
                        offset += toWrite
                        written += toWrite
                        onTransferProgress?.invoke("out", written, len, if (type == FRAME_TYPE_BYTES) "bytes" else "text")
                    }
                    output?.flush()
                } catch (e: IOException) {
                    onSocketError?.invoke("Write failed: ${e.message}")
                }
            }
        }

        fun isActive(): Boolean = active.get()

        fun cancel(reason: String) {
            active.set(false)
            try { input?.close() } catch (_: IOException) {}
            try { output?.close() } catch (_: IOException) {}
            try { socket.close() } catch (_: IOException) {}
            // At most one disconnect notification per connection episode:
            // EOF, the broadcast branch and a later manual cancel all flow
            // through here.
            if (disconnectNotified.compareAndSet(false, true)) {
                onSocketDisconnected?.invoke(reason)
            }
        }
    }

    /// A connection was accepted on the GO side. Tries to learn the client's
    /// P2P device name (the socket alone carries only an IP) via
    /// `requestGroupInfo`, so the receiving side's connection banner shows a
    /// real name instead of "unknown". Falls back to a nameless connection
    /// after a short window — the handshake must never stall on this.
    private fun handleAcceptedSocket(s: Socket) {
        val m = manager
        val c = channel
        if (m == null || c == null) {
            manageConnectedSocket(s, isGroupOwner = true)
            return
        }
        var settled = false
        val fallback = Runnable {
            if (!settled) {
                settled = true
                manageConnectedSocket(s, isGroupOwner = true)
            }
        }
        Handler(Looper.getMainLooper()).postDelayed(fallback, 1000)
        runCatching {
            m.requestGroupInfo(c) { group ->
                if (!settled) {
                    settled = true
                    // The client's DEVICE ADDRESS (MAC) is core to the group
                    // membership and reliably populated (unlike the name) —
                    // without it the receiving side would key its chat
                    // session on a random UUID and show "unknown" in the
                    // session list. The name rides along when available.
                    val client = group?.clientList?.firstOrNull()
                    manageConnectedSocket(
                        s,
                        isGroupOwner = true,
                        peerName = client?.deviceName,
                        peerAddress = client?.deviceAddress,
                    )
                }
            }
        }
    }

    private fun manageConnectedSocket(
        socket: Socket,
        isGroupOwner: Boolean,
        peerName: String? = null,
        peerAddress: String? = null,
    ) {
        connectedThread?.cancel("replaced")
        // New connection episode: allow exactly one disconnect notification.
        disconnectNotified.set(false)
        connectedThread = ConnectedThread(socket, isGroupOwner).also { it.start() }
        val remoteMap = mapOf(
            "deviceName" to peerName,
            "deviceAddress" to peerAddress,
            "ip" to socket.inetAddress?.hostAddress,
            "port" to socket.port,
            "isGroupOwner" to isGroupOwner
        )
        onSocketConnected?.invoke(remoteMap)
    }
}



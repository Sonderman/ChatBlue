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
    private val channel: WifiP2pManager.Channel? = manager?.initialize(context, context.mainLooper, null)

    private val peersByAddress: MutableMap<String, Map<String, Any?>> = ConcurrentHashMap()
    private val discoveryRegistered = AtomicBoolean(false)
    private var p2pEnabled: Boolean = false

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

    fun startDiscovery() {
        val m = manager ?: return onScanError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = channel ?: return onScanError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
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

    fun createGroup() {
        val m = manager ?: return onSocketError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = channel ?: return onSocketError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        m.createGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                // Start server immediately; ServerSocket can bind without waiting IP
                startServerSocket()
                // Also proactively query connection info; some devices don't fire connected immediately
                Handler(Looper.getMainLooper()).postDelayed({ requestConnectionInfo() }, 600)
            }
            override fun onFailure(reason: Int) { onSocketError?.invoke("createGroup failed: $reason") }
        })
    }

    fun removeGroup() {
        val m = manager ?: return
        val c = channel ?: return
        m.removeGroup(c, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { }
            override fun onFailure(reason: Int) { }
        })
    }

    fun connect(deviceAddress: String) {
        val m = manager ?: return onSocketError?.invoke("Wi‑Fi P2P not supported") ?: Unit
        val c = channel ?: return onSocketError?.invoke("Wi‑Fi P2P channel unavailable") ?: Unit
        if (!p2pEnabled) {
            onSocketError?.invoke("Wi‑Fi Direct is disabled")
            return
        }
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
            retriedOnce = false
        }

        // Ignore obviously invalid addresses
        if (deviceAddress.isBlank() || deviceAddress == "02:00:00:00:00:00") {
            onSocketError?.invoke("Invalid device address: $deviceAddress")
            return
        }

        // Best-effort: cancel discovery/connect before a new connect
        runCatching { m.cancelConnect(c, null) }
        runCatching { m.stopPeerDiscovery(c, null) }
        // Ensure we are not part of a previous group before attempting client connect
        removeGroup()

        attemptConnect(deviceAddress, goIntent = 0)
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
                        }, 1500)
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

    private fun isWifiEnabled(): Boolean {
        val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return wm?.isWifiEnabled == true
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
                }
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    val m = manager ?: return
                    val c = channel ?: return
                    m.requestPeers(c) { list: WifiP2pDeviceList ->
                        list.deviceList?.forEach { d: WifiP2pDevice ->
                            val mapped = deviceToMap(d)
                            peersByAddress[d.deviceAddress] = mapped
                            onPeerFound?.invoke(mapped)
                        }
                    }
                }
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val networkInfo: NetworkInfo? = intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO)
                    if (networkInfo?.isConnected == true) {
                        requestConnectionInfo()
                    } else {
                        // disconnected
                        onSocketDisconnected?.invoke("disconnected")
                        disconnect()
                    }
                }
                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    // no-op
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
            try {
                val s = server?.accept()
                if (s != null) manageConnectedSocket(s, isGroupOwner = true)
            } catch (e: IOException) {
                if (!cancelled.get()) onSocketError?.invoke("Accept failed: ${e.message}")
            } finally {
                cancel()
            }
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
            onSocketDisconnected?.invoke(reason)
        }
    }

    private fun manageConnectedSocket(socket: Socket, isGroupOwner: Boolean) {
        connectedThread?.cancel("replaced")
        connectedThread = ConnectedThread(socket, isGroupOwner).also { it.start() }
        val remoteMap = mapOf(
            "deviceName" to null,
            "deviceAddress" to null,
            "ip" to socket.inetAddress?.hostAddress,
            "port" to socket.port,
            "isGroupOwner" to isGroupOwner
        )
        onSocketConnected?.invoke(remoteMap)
    }
}



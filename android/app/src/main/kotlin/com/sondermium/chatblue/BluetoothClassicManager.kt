package com.sondermium.chatblue

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.content.SharedPreferences
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Manages Bluetooth Classic discovery and RFCOMM socket connections.
 * Exposes callbacks to bridge events to Flutter via platform channels.
 */
class BluetoothClassicManager(private val context: Context) {

    private val bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()

    // App-specific UUID used to identify ChatBlue instances via SDP
    private val appServiceUuid: UUID = UUID.fromString("3f4d0001-8b99-4fdd-a17b-9b0a4a97d0c7")
    private val appServiceParcelUuid: ParcelUuid = ParcelUuid(appServiceUuid)

    private val discoveredByAddress: MutableMap<String, Map<String, Any?>> = ConcurrentHashMap()
    private val candidatesByAddress: MutableMap<String, Map<String, Any?>> = ConcurrentHashMap()
    private val discoveryRegistered = AtomicBoolean(false)

    private var onScanStarted: (() -> Unit)? = null
    private var onDeviceFound: ((Map<String, Any?>) -> Unit)? = null
    private var onScanFinished: (() -> Unit)? = null
    private var onScanError: ((String) -> Unit)? = null

    private var onSocketConnected: ((Map<String, Any?>) -> Unit)? = null
    private var onSocketDisconnected: ((String) -> Unit)? = null
    private var onBytesReceived: ((ByteArray) -> Unit)? = null
    private var onTextReceived: ((String) -> Unit)? = null
    private var onSocketError: ((String) -> Unit)? = null
    private var onTransferProgress: ((String, Int, Int, String) -> Unit)? = null

    private var acceptThread: AcceptThread? = null
    private var connectThread: ConnectThread? = null
    private var connectedThread: ConnectedThread? = null

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val prefs: SharedPreferences = context.getSharedPreferences("chatblue_prefs", Context.MODE_PRIVATE)

    private companion object {
        const val FRAME_TYPE_TEXT: Byte = 1
        const val FRAME_TYPE_BYTES: Byte = 2
    }

    fun setScanCallbacks(
        onStarted: (() -> Unit)?,
        onDeviceFound: ((Map<String, Any?>) -> Unit)?,
        onFinished: (() -> Unit)?,
        onError: ((String) -> Unit)?,
    ) {
        this.onScanStarted = onStarted
        this.onDeviceFound = onDeviceFound
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

    fun startDiscovery() {
        val adapter = bluetoothAdapter ?: return onScanError?.invoke("Bluetooth not supported") ?: Unit
        if (!hasScanPermission()) {
            onScanError?.invoke("Missing BLUETOOTH_SCAN permission")
            return
        }
        tryRegisterReceiver()
        discoveredByAddress.clear()
        candidatesByAddress.clear()
        // Cancel any ongoing discovery to restart a fresh scan
        if (adapter.isDiscovering) adapter.cancelDiscovery()
        adapter.startDiscovery()
    }

    fun stopDiscovery() {
        val adapter = bluetoothAdapter ?: return
        if (adapter.isDiscovering) adapter.cancelDiscovery()
        onScanFinished?.invoke()
    }

    fun getDiscoveredDevices(): List<Map<String, Any?>> = discoveredByAddress.values.toList()

    fun clearDiscoveredDevices() {
        discoveredByAddress.clear()
    }

    fun getPairedDevices(): List<Map<String, Any?>> {
        val adapter = bluetoothAdapter ?: return emptyList()
        if (!hasConnectPermission()) return emptyList()
        val known = getKnownAddresses()
        return adapter.bondedDevices
            ?.filter { known.contains(it.address) }
            ?.map { device -> deviceToMap(device) }
            ?: emptyList()
    }

    fun startServer(serviceName: String, uuidString: String?) {
        stopServer()
        val uuid = parseUuidOrDefault(uuidString)
        if (!hasConnectPermission()) {
            onSocketError?.invoke("Missing BLUETOOTH_CONNECT permission")
            return
        }
        acceptThread = AcceptThread(serviceName, uuid).also { it.start() }
    }

    fun stopServer() {
        acceptThread?.cancel()
        acceptThread = null
    }

    fun connect(address: String, uuidString: String?) {
        disconnect()
        val adapter = bluetoothAdapter ?: run {
            onSocketError?.invoke("Bluetooth not supported")
            return
        }
        if (!hasConnectPermission()) {
            onSocketError?.invoke("Missing BLUETOOTH_CONNECT permission")
            return
        }
        val device = adapter.getRemoteDevice(address)
        val uuid = parseUuidOrDefault(uuidString)
        connectThread = ConnectThread(device, uuid).also { it.start() }
    }

    fun isConnected(): Boolean = connectedThread?.isActive() == true

    fun disconnect() {
        connectThread?.cancel()
        connectThread = null
        connectedThread?.cancel("manual")
        connectedThread = null
    }

    fun sendBytes(data: ByteArray) {
        // Backward-compatible: treat as raw payload but frame it as BYTES
        sendRawBytes(data)
    }

    fun sendText(text: String) {
        val payload = text.toByteArray(Charsets.UTF_8)
        connectedThread?.writeFramed(FRAME_TYPE_TEXT, payload)
    }

    fun sendRawBytes(data: ByteArray) {
        connectedThread?.writeFramed(FRAME_TYPE_BYTES, data)
    }

    fun dispose() {
        tryUnregisterReceiver()
        stopDiscovery()
        stopServer()
        disconnect()
        ioExecutor.shutdownNow()
    }

    private fun parseUuidOrDefault(uuidString: String?): UUID {
        return try {
            if (uuidString.isNullOrBlank()) appServiceUuid else UUID.fromString(uuidString)
        } catch (_: IllegalArgumentException) {
            appServiceUuid
        }
    }

    private fun deviceToMap(device: BluetoothDevice): Map<String, Any?> {
        return mapOf(
            "name" to safeDeviceName(device),
            "address" to device.address,
            "type" to device.type,
            "bondState" to device.bondState
        )
    }

    @SuppressLint("MissingPermission")
    private fun safeDeviceName(device: BluetoothDevice): String? {
        return try {
            if (!hasConnectPermission()) null else device.name
        } catch (_: SecurityException) {
            null
        }
    }

    private val discoveryReceiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_DISCOVERY_STARTED -> {
                    onScanStarted?.invoke()
                }
                BluetoothDevice.ACTION_FOUND -> {
                    try {
                        if (!hasScanPermission()) return
                        val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        val rssi: Short = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE)
                        if (device != null) {
                            val mapped = deviceToMap(device) + mapOf("rssi" to rssi.toInt())
                            candidatesByAddress[device.address] = mapped
                            try {
                                if (hasConnectPermission()) device.fetchUuidsWithSdp()
                            } catch (_: SecurityException) {}
                        }
                    } catch (e: SecurityException) {
                        onScanError?.invoke("SecurityException: ${e.message}")
                    }
                }
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    onScanFinished?.invoke()
                    candidatesByAddress.clear()
                }
                BluetoothDevice.ACTION_UUID -> {
                    try {
                        val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        val parcelUuids = intent.getParcelableArrayExtra(BluetoothDevice.EXTRA_UUID)
                        if (device != null && parcelUuids != null) {
                            val hasApp = parcelUuids.any { it is ParcelUuid && it == appServiceParcelUuid }
                            if (hasApp) {
                                val mapped = candidatesByAddress[device.address] ?: deviceToMap(device)
                                discoveredByAddress[device.address] = mapped
                                onDeviceFound?.invoke(mapped)
                            }
                            candidatesByAddress.remove(device.address)
                        }
                    } catch (e: Exception) {
                        onScanError?.invoke("UUID check failed: ${e.message}")
                    }
                }
            }
        }
    }

    private fun tryRegisterReceiver() {
        if (discoveryRegistered.compareAndSet(false, true)) {
            val filter = IntentFilter().apply {
                addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                addAction(BluetoothDevice.ACTION_FOUND)
                addAction(BluetoothDevice.ACTION_UUID)
            }
            context.registerReceiver(discoveryReceiver, filter)
        }
    }

    private fun tryUnregisterReceiver() {
        if (discoveryRegistered.compareAndSet(true, false)) {
            try {
                context.unregisterReceiver(discoveryReceiver)
            } catch (_: IllegalArgumentException) {
                // Receiver not registered; ignore
            }
        }
    }

    private fun hasScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        } else {
            // For discovery on Android < 12, location is required
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun hasConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else true
    }

    // region Threads

    private inner class AcceptThread(
        private val serviceName: String,
        private val uuid: UUID
    ) : Thread("BtAcceptThread") {
        private var serverSocket: BluetoothServerSocket? = null
        private val cancelled = AtomicBoolean(false)

        init {
            @SuppressLint("MissingPermission")
            try {
                serverSocket = bluetoothAdapter?.listenUsingRfcommWithServiceRecord(serviceName, uuid)
            } catch (e: SecurityException) {
                onSocketError?.invoke("listenUsingRfcomm failed: ${e.message}")
            } catch (e: IOException) {
                onSocketError?.invoke("listenUsingRfcomm IO: ${e.message}")
            }
        }

        override fun run() {
            while (!cancelled.get()) {
                try {
                    val socket = serverSocket?.accept() ?: break
                    manageConnectedSocket(socket)
                    // Only one connection at a time; close server to prevent multiple clients
                    break
                } catch (e: IOException) {
                    if (!cancelled.get()) onSocketError?.invoke("Server accept failed: ${e.message}")
                    break
                }
            }
            cancel()
        }

        fun cancel() {
            cancelled.set(true)
            try { serverSocket?.close() } catch (_: IOException) {}
            serverSocket = null
        }
    }

    private inner class ConnectThread(
        private val device: BluetoothDevice,
        private val uuid: UUID
    ) : Thread("BtConnectThread") {
        private var socket: BluetoothSocket? = null
        private val cancelled = AtomicBoolean(false)

        @SuppressLint("MissingPermission")
        override fun run() {
            try {
                if (bluetoothAdapter?.isDiscovering == true) bluetoothAdapter.cancelDiscovery()
                socket = device.createRfcommSocketToServiceRecord(uuid)
                socket?.connect()
                val s = socket
                if (s != null) manageConnectedSocket(s) else onSocketError?.invoke("Socket null after connect")
            } catch (e: SecurityException) {
                onSocketError?.invoke("Connect SecurityException: ${e.message}")
                cancel()
            } catch (e: IOException) {
                onSocketError?.invoke("Connect IO: ${e.message}")
                cancel()
            }
        }

        fun cancel() {
            cancelled.set(true)
            try { socket?.close() } catch (_: IOException) {}
            socket = null
        }
    }

    private inner class ConnectedThread(private val socket: BluetoothSocket) : Thread("BtConnectedThread") {
        private val input: InputStream?
        private val output: OutputStream?
        private val active = AtomicBoolean(true)
        private var accumulator: ByteArray = ByteArray(0)

        init {
            input = try { socket.inputStream } catch (_: IOException) { null }
            output = try { socket.outputStream } catch (_: IOException) { null }
        }

        override fun run() {
            val buffer = ByteArray(4096)
            var lastReason: String? = null
            while (active.get()) {
                try {
                    val read = input?.read(buffer) ?: -1
                    if (read == -1) {
                        lastReason = "eof"
                        break
                    }
                    // Append to accumulator
                    val incoming = buffer.copyOf(read)
                    accumulator = accumulator + incoming
                    // Progress notification (inbound): if header present, compute current progress
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
                    // Decode frames: [type(1)][len(4)][payload]
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

    @SuppressLint("MissingPermission")
    private fun manageConnectedSocket(socket: BluetoothSocket) {
        // Close any existing connection first
        connectedThread?.cancel("replaced")
        connectedThread = ConnectedThread(socket).also { it.start() }
        val remote = socket.remoteDevice
        val remoteMap = deviceToMap(remote)
        rememberKnown(remote.address)
        onSocketConnected?.invoke(remoteMap)
    }
    private fun getKnownAddresses(): Set<String> {
        return prefs.getStringSet("known_addresses", emptySet()) ?: emptySet()
    }

    private fun rememberKnown(address: String) {
        val set = getKnownAddresses().toMutableSet()
        if (set.add(address)) {
            prefs.edit().putStringSet("known_addresses", set).apply()
        }
    }

    // endregion
}



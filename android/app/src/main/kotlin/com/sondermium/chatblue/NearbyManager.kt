package com.sondermium.chatblue

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.os.Build
import android.provider.Settings
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Manages Google Nearby Connections (P2P_POINT_TO_POINT strategy) for a
 * single 1:1 chat link and exposes callbacks to bridge events to Flutter via
 * platform channels (mirrors the Bt/WD manager contract).
 *
 * Design notes (see `.hermes/plans/2026-10-08_001211-nearby-connections-design.md`):
 * - Identity: the local `endpointInfo` bytes carry `"<uid>|<name>"` (UTF-8);
 *   the remote reads them from [DiscoveredEndpointInfo] at discovery and
 *   [ConnectionInfo] at connection-initiated time. The session key (uid)
 *   therefore arrives BEFORE the connection — no MAC-rotation problem class.
 * - Handshake: Nearby's own accept protocol replaces the READY/identity
 *   frames used over BT/WFD sockets. A dial WE initiated is auto-accepted
 *   (the user already asked); a remotely-initiated connection is forwarded
 *   to the UI banner, which calls [accept]/[reject].
 * - Wire format: application frames keep the SAME 5-byte envelope as the
 *   other transports ([1B type][4B big-endian length]; 1=text, 2=bytes).
 *   Incoming BYTES payloads append to one accumulator parsed with the same
 *   frame parser; outgoing frames are chunked into 256 KB payloads
 *   (well under ConnectionsClient.MAX_BYTES_DATA_SIZE).
 */
class NearbyManager(private val context: Context) {

    private val client: ConnectionsClient? =
        runCatching { Nearby.getConnectionsClient(context) }.getOrNull()

    /// endpointId -> display name ("<uid>|<name>" payload, name part).
    private val endpointNames: MutableMap<String, String> = ConcurrentHashMap()

    /// endpointId -> stable per-install device uid (session key).
    private val endpointUids: MutableMap<String, String> = ConcurrentHashMap()

    /// The endpointId of the dial currently in flight (requestConnection).
    /// An onConnectionInitiated for this id is our own request (or a cross
    /// dial against our target) and is auto-accepted without a banner.
    @Volatile
    private var outgoingEndpointId: String? = null

    /// The endpointId of the live connection (null while not connected).
    @Volatile
    private var connectedEndpointId: String? = null

    /// Ensures `onSocketDisconnected` fires at most ONCE per connection
    /// episode (disconnect() plus the later onDisconnected callback would
    /// otherwise report twice). Reset when a connection is established.
    private val disconnectNotified = AtomicBoolean(false)

    // Scan (advertise + discover) start bookkeeping: 'started' is emitted
    // only when BOTH Tasks succeeded, a failure of either aborts the half.
    private val advStarted = AtomicBoolean(false)
    private val discStarted = AtomicBoolean(false)
    private val startedEmitted = AtomicBoolean(false)

    private val ioExecutor = Executors.newSingleThreadExecutor()

    private val frameLock = Any()
    private var accumulator: ByteArray = ByteArray(0)

    private var onScanStarted: (() -> Unit)? = null
    private var onEndpointFound: ((Map<String, Any?>) -> Unit)? = null
    private var onEndpointLost: ((String) -> Unit)? = null
    private var onScanFinished: (() -> Unit)? = null
    private var onScanError: ((String) -> Unit)? = null

    private var onConnectionInitiated: ((Map<String, Any?>) -> Unit)? = null
    private var onSocketConnected: ((Map<String, Any?>) -> Unit)? = null
    private var onConnectionRejected: ((String) -> Unit)? = null
    private var onSocketDisconnected: ((String) -> Unit)? = null

    private var onBytesReceived: ((ByteArray) -> Unit)? = null
    private var onTextReceived: ((String) -> Unit)? = null
    private var onTransferProgress: ((String, Int, Int, String) -> Unit)? = null
    private var onSocketError: ((String) -> Unit)? = null

    private companion object {
        const val FRAME_TYPE_TEXT: Byte = 1
        const val FRAME_TYPE_BYTES: Byte = 2

        /// Outgoing frame chunk size (BYTES payloads are capped at
        /// ConnectionsClient.MAX_BYTES_DATA_SIZE ≈ 1 MB; stay well under).
        const val CHUNK_BYTES: Int = 262144

        const val SERVICE_ID = "com.sondermium.chatblue.NEARBY"
        val STRATEGY: Strategy = Strategy.P2P_POINT_TO_POINT
    }

    fun setScanCallbacks(
        onStarted: (() -> Unit)?,
        onEndpointFound: ((Map<String, Any?>) -> Unit)?,
        onEndpointLost: ((String) -> Unit)?,
        onFinished: (() -> Unit)?,
        onError: ((String) -> Unit)?,
    ) {
        this.onScanStarted = onStarted
        this.onEndpointFound = onEndpointFound
        this.onEndpointLost = onEndpointLost
        this.onScanFinished = onFinished
        this.onScanError = onError
    }

    fun setConnectionCallbacks(
        onInitiated: ((Map<String, Any?>) -> Unit)?,
        onConnected: ((Map<String, Any?>) -> Unit)?,
        onRejected: ((String) -> Unit)?,
        onDisconnected: ((String) -> Unit)?,
    ) {
        this.onConnectionInitiated = onInitiated
        this.onSocketConnected = onConnected
        this.onConnectionRejected = onRejected
        this.onSocketDisconnected = onDisconnected
    }

    fun setPayloadCallbacks(
        onTextReceived: ((String) -> Unit)?,
        onBytesReceived: ((ByteArray) -> Unit)?,
        onError: ((String) -> Unit)?,
        onProgress: ((String, Int, Int, String) -> Unit)? = null,
    ) {
        this.onTextReceived = onTextReceived
        this.onBytesReceived = onBytesReceived
        this.onSocketError = onError
        this.onTransferProgress = onProgress
    }

    fun isConnected(): Boolean = connectedEndpointId != null

    /// Best-effort user-visible device name — shown to peers in their lists
    /// and banners: OS device name, then legacy Bluetooth name, then the
    /// adapter name, then the hardware model code.
    fun getDeviceName(): String {
        val fromSettings = runCatching {
            Settings.Global.getString(context.contentResolver, "device_name")
        }.getOrNull()
        if (!fromSettings.isNullOrBlank()) return fromSettings
        val fromSecure = runCatching {
            Settings.Secure.getString(context.contentResolver, "bluetooth_name")
        }.getOrNull()
        if (!fromSecure.isNullOrBlank()) return fromSecure
        val fromAdapter = runCatching {
            BluetoothAdapter.getDefaultAdapter()?.name
        }.getOrNull()
        if (!fromAdapter.isNullOrBlank()) return fromAdapter
        return runCatching { Build.MODEL }.getOrNull().orEmpty()
    }

    /// {playServices, bluetoothEnabled, canAdvertise} — the scan screen
    /// shows a panel instead of the controls when the first two are missing,
    /// and an info note when [canAdvertise] is false.
    fun getStatus(): Map<String, Any> {
        val playServices = runCatching {
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) ==
                ConnectionResult.SUCCESS
        }.getOrDefault(false)
        val bluetoothEnabled = runCatching {
            BluetoothAdapter.getDefaultAdapter()?.isEnabled == true
        }.getOrDefault(false)
        // BLE advertising capability for the scan screen's info note: some
        // old budget stacks cannot advertise at all, yet Nearby's advertise
        // Task reports success while nothing ever airs (SM-G610F / Android
        // 8.1). Public API: with Bluetooth ON, a null BluetoothLeAdvertiser
        // means the stack does not support BLE advertising. Meaningless
        // while Bluetooth is off → report true (the BT-off panel covers it).
        val canAdvertise = if (!bluetoothEnabled) {
            true
        } else {
            runCatching {
                BluetoothAdapter.getDefaultAdapter()?.bluetoothLeAdvertiser != null
            }.getOrDefault(true)
        }
        return mapOf(
            "playServices" to playServices,
            "bluetoothEnabled" to bluetoothEnabled,
            "canAdvertise" to canAdvertise
        )
    }

    // region Scanning (advertise + discover together)

    fun startScan(name: String, uid: String) {
        val c = client ?: return onScanError?.invoke("Nearby service unavailable") ?: Unit
        endpointNames.clear()
        endpointUids.clear()
        // A fresh scan starts a fresh session: a marker left behind by a
        // dead attempt would suppress the next incoming request's banner.
        outgoingEndpointId = null
        advStarted.set(false)
        discStarted.set(false)
        startedEmitted.set(false)

        val advOptions = AdvertisingOptions.Builder().setStrategy(STRATEGY).build()
        val discOptions = DiscoveryOptions.Builder().setStrategy(STRATEGY).build()

        // Advertise carries OUR identity bytes; discovery callbacks receive
        // the remote's. Both run together: either side can dial the other.
        c.startAdvertising(endpointInfoBytes(uid, name), SERVICE_ID, lifecycleCallback, advOptions)
            .addOnSuccessListener {
                advStarted.set(true)
                maybeEmitStarted()
            }
            .addOnFailureListener { e -> abortScan("startAdvertising failed: ${e.message}") }

        c.startDiscovery(SERVICE_ID, discoveryCallback, discOptions)
            .addOnSuccessListener {
                discStarted.set(true)
                maybeEmitStarted()
            }
            .addOnFailureListener { e -> abortScan("startDiscovery failed: ${e.message}") }
    }

    fun stopScan() {
        runCatching { client?.stopAdvertising() }
        runCatching { client?.stopDiscovery() }
        advStarted.set(false)
        discStarted.set(false)
        startedEmitted.set(false)
        onScanFinished?.invoke()
    }

    private fun maybeEmitStarted() {
        if (advStarted.get() && discStarted.get() && startedEmitted.compareAndSet(false, true)) {
            onScanStarted?.invoke()
        }
    }

    private fun abortScan(message: String) {
        runCatching { client?.stopAdvertising() }
        runCatching { client?.stopDiscovery() }
        advStarted.set(false)
        discStarted.set(false)
        onScanError?.invoke(message)
    }

    // endregion

    // region Connection lifecycle

    /// Requests a connection to [endpointId]. [uid]/[name] are OUR identity
    /// bytes for the remote's ConnectionInfo (session key + display name).
    fun connect(endpointId: String, uid: String, name: String) {
        val c = client ?: return onSocketError?.invoke("Nearby service unavailable") ?: Unit
        if (endpointId.isBlank()) {
            onSocketError?.invoke("Invalid endpoint id")
            return
        }
        outgoingEndpointId = endpointId
        c.requestConnection(endpointInfoBytes(uid, name), endpointId, lifecycleCallback)
            .addOnFailureListener { e ->
                if (outgoingEndpointId == endpointId) {
                    outgoingEndpointId = null
                }
                onSocketError?.invoke("Connect failed: ${e.message}")
            }
    }

    /// Accepts an incoming connection (UI banner "Accept").
    fun accept(endpointId: String) {
        val c = client ?: return
        c.acceptConnection(endpointId, payloadCallback)
            .addOnFailureListener { e -> onSocketError?.invoke("Accept failed: ${e.message}") }
    }

    /// Rejects an incoming connection (UI banner "Decline"/timeout).
    fun reject(endpointId: String) {
        val c = client ?: return
        c.rejectConnection(endpointId)
            .addOnFailureListener { e -> onSocketError?.invoke("Reject failed: ${e.message}") }
    }

    fun disconnect() {
        val c = client ?: return
        val target = connectedEndpointId
        connectedEndpointId = null
        outgoingEndpointId = null
        runCatching { c.stopAdvertising() }
        runCatching { c.stopDiscovery() }
        synchronized(frameLock) { accumulator = ByteArray(0) }
        if (target != null) {
            if (disconnectNotified.compareAndSet(false, true)) {
                onSocketDisconnected?.invoke("manual")
            }
            runCatching { c.disconnectFromEndpoint(target) }
        }
    }

    /// Aborts a pending outgoing request (UI "İptal"): best effort — GMS may
    /// already be past the point of no return; the Dart side additionally
    /// suppresses a late accept (disconnects it instead of opening a chat).
    fun cancelConnect() {
        val c = client ?: return
        val target = outgoingEndpointId ?: return
        outgoingEndpointId = null
        runCatching { c.disconnectFromEndpoint(target) }
    }

    private val lifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            val (uid, name) = parseEndpointInfo(runCatching { info.endpointInfo }.getOrNull())
            val displayName = name.ifEmpty {
                runCatching { info.endpointName }.getOrNull() ?: ""
            }
            endpointUids[endpointId] = uid
            endpointNames[endpointId] = displayName

            val remoteInitiated = runCatching { info.isIncomingConnection }.getOrDefault(false)
            val isOurTarget = endpointId == outgoingEndpointId
            // A request for our OWN in-flight dial (or a cross-dial to the
            // same target) is not an incoming request for the user: accept
            // silently. Only a genuinely remote-initiated connection gets
            // the request banner (the UI calls accept()/reject()).
            val uiIncoming = remoteInitiated && !isOurTarget
            if (!uiIncoming) {
                runCatching { client?.acceptConnection(endpointId, payloadCallback) }
                if (isOurTarget) {
                    // The marker's job (suppressing this endpoint's redundant
                    // initiation) is done — keeping it would silently suppress
                    // FUTURE banners, e.g. after a dead attempt left it stale.
                    outgoingEndpointId = null
                }
            }

            this@NearbyManager.onConnectionInitiated?.invoke(
                mapOf(
                    "endpointId" to endpointId,
                    "endpointName" to displayName,
                    "uid" to uid,
                    "incoming" to uiIncoming,
                    "authDigits" to (runCatching { info.authenticationDigits }.getOrNull() ?: "")
                )
            )
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.isSuccess()) {
                connectedEndpointId = endpointId
                outgoingEndpointId = null
                disconnectNotified.set(false)
                // A link is up: advertising/discovery are no longer useful
                // (battery) — stop them and report the scan as finished.
                runCatching { client?.stopAdvertising() }
                runCatching { client?.stopDiscovery() }
                onScanFinished?.invoke()
                onSocketConnected?.invoke(peerMap(endpointId))
            } else {
                if (outgoingEndpointId == endpointId) {
                    outgoingEndpointId = null
                }
                onConnectionRejected?.invoke(endpointId)
            }
        }

        override fun onDisconnected(endpointId: String) {
            endpointNames.remove(endpointId)
            endpointUids.remove(endpointId)
            if (connectedEndpointId == endpointId) {
                connectedEndpointId = null
                if (disconnectNotified.compareAndSet(false, true)) {
                    onSocketDisconnected?.invoke("disconnected")
                }
            }
        }
    }

    private val discoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            val (uid, name) = parseEndpointInfo(runCatching { info.endpointInfo }.getOrNull())
            val displayName = name.ifEmpty {
                runCatching { info.endpointName }.getOrNull() ?: ""
            }
            endpointUids[endpointId] = uid
            endpointNames[endpointId] = displayName
            this@NearbyManager.onEndpointFound?.invoke(peerMap(endpointId))
        }

        override fun onEndpointLost(endpointId: String) {
            endpointUids.remove(endpointId)
            endpointNames.remove(endpointId)
            this@NearbyManager.onEndpointLost?.invoke(endpointId)
        }
    }

    // endregion

    // region Payload I/O (framed stream over BYTES payloads)

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            val bytes = runCatching { payload.asBytes() }.getOrNull() ?: return
            if (bytes.isEmpty()) return
            synchronized(frameLock) {
                accumulator += bytes
                parseAccumulated()
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            // Chunk-level progress is emitted from writeFramed; per-payload
            // updates are intentionally not surfaced (they would introduce a
            // second, frame-unaware progress stream).
        }
    }

    /// Appends nothing; parses every complete frame from [accumulator] and
    /// emits in-progress updates for the frame still being received (the
    /// same semantics as the Wd/Bt reader threads).
    private fun parseAccumulated() {
        if (accumulator.size >= 5) {
            val type = accumulator[0]
            val len = frameLength()
            val cur = maxOf(0, minOf(len, accumulator.size - 5))
            onTransferProgress?.invoke("in", cur, len, kindOf(type))
        }
        while (accumulator.size >= 5) {
            val type = accumulator[0]
            val len = frameLength()
            if (accumulator.size < 5 + len) break
            val payload = accumulator.copyOfRange(5, 5 + len)
            accumulator = accumulator.copyOfRange(5 + len, accumulator.size)
            when (type) {
                FRAME_TYPE_TEXT -> {
                    try {
                        onTextReceived?.invoke(String(payload, Charsets.UTF_8))
                    } catch (_: Exception) {
                        onSocketError?.invoke("Failed to decode text payload")
                    }
                }
                FRAME_TYPE_BYTES -> onBytesReceived?.invoke(payload)
                else -> onSocketError?.invoke("Unknown frame type: $type")
            }
            onTransferProgress?.invoke("in", len, len, kindOf(type))
        }
    }

    private fun frameLength(): Int =
        ((accumulator[1].toInt() and 0xFF) shl 24) or
            ((accumulator[2].toInt() and 0xFF) shl 16) or
            ((accumulator[3].toInt() and 0xFF) shl 8) or
            (accumulator[4].toInt() and 0xFF)

    private fun kindOf(type: Byte): String = if (type == FRAME_TYPE_BYTES) "bytes" else "text"

    fun sendText(text: String) {
        writeFramed(FRAME_TYPE_TEXT, text.toByteArray(Charsets.UTF_8))
    }

    fun sendRawBytes(data: ByteArray) {
        writeFramed(FRAME_TYPE_BYTES, data)
    }

    /// Frames [payload] and sends it as a sequence of BYTES payloads on the
    /// single-thread executor (FIFO: frames never interleave).
    private fun writeFramed(type: Byte, payload: ByteArray) {
        val target = connectedEndpointId ?: return
        val c = client ?: return
        ioExecutor.execute {
            try {
                val len = payload.size
                val frame = ByteArray(5 + len)
                frame[0] = type
                frame[1] = ((len ushr 24) and 0xFF).toByte()
                frame[2] = ((len ushr 16) and 0xFF).toByte()
                frame[3] = ((len ushr 8) and 0xFF).toByte()
                frame[4] = (len and 0xFF).toByte()
                System.arraycopy(payload, 0, frame, 5, len)

                val kind = kindOf(type)
                onTransferProgress?.invoke("out", 0, len, kind)
                var offset = 0
                while (offset < frame.size) {
                    val toSend = minOf(CHUNK_BYTES, frame.size - offset)
                    val part = frame.copyOfRange(offset, offset + toSend)
                    c.sendPayload(target, Payload.fromBytes(part))
                        .addOnFailureListener { e -> onSocketError?.invoke("Send failed: ${e.message}") }
                    offset += toSend
                    onTransferProgress?.invoke("out", (offset - 5).coerceIn(0, len), len, kind)
                }
            } catch (e: Exception) {
                onSocketError?.invoke("Write failed: ${e.message}")
            }
        }
    }

    // endregion

    fun dispose() {
        runCatching { client?.stopAdvertising() }
        runCatching { client?.stopDiscovery() }
        runCatching { client?.stopAllEndpoints() }
        ioExecutor.shutdownNow()
    }

    // region helpers

    private fun peerMap(endpointId: String): Map<String, Any?> = mapOf(
        "endpointId" to endpointId,
        "endpointName" to (endpointNames[endpointId] ?: ""),
        "uid" to (endpointUids[endpointId] ?: "")
    )

    /// Our identity bytes: "<uid>|<name>" (UTF-8). '|' inside the name is
    /// replaced so the first '|' always separates uid from name.
    private fun endpointInfoBytes(uid: String, name: String): ByteArray =
        "$uid|${name.replace('|', ' ')}".toByteArray(Charsets.UTF_8)

    /// Parses "<uid>|<name>"; malformed input degrades to name-only or empty
    /// (never a bogus uid — the session key falls back to a UUID instead).
    private fun parseEndpointInfo(raw: ByteArray?): Pair<String, String> {
        if (raw == null || raw.isEmpty()) return "" to ""
        val text = try {
            String(raw, Charsets.UTF_8)
        } catch (_: Exception) {
            return "" to ""
        }
        val bar = text.indexOf('|')
        return if (bar < 0) {
            "" to text.trim()
        } else {
            text.substring(0, bar).trim() to text.substring(bar + 1).trim()
        }
    }

    // endregion
}

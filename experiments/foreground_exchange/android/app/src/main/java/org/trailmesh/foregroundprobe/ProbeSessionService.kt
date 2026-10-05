package org.trailmesh.foregroundprobe

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import kotlin.random.Random

internal data class ProbeSnapshot(
    val active: Boolean, val status: String, val checkpoint: SessionCheckpoint?,
    val permissionTicket: Long, val permissionsNeeded: List<String>,
    val selectedPeer: String?,
) {
    val canResume: Boolean get() = !active && checkpoint?.open == true
}

/** User-started, test-only session owner. Activity binding never controls the radio lifetime. */
class ProbeSessionService : Service() {
    inner class LocalBinder : Binder() { internal val session: ProbeSessionService get() = this@ProbeSessionService }
    private val binder = LocalBinder()
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CallbackScope()
    private val client by lazy { Nearby.getConnectionsClient(applicationContext) }
    private lateinit var journal: SessionJournal
    private var ledger: SessionLedger? = null
    private var saved: SessionCheckpoint? = null
    private var active = false
    private var foreground = false
    private var message = "Not running"
    private val observers = linkedSetOf<(ProbeSnapshot) -> Unit>()
    private val timers = mutableMapOf<String, Runnable>()
    private val candidates = linkedMapOf<String, Pair<String, ProbePeerContext>>()
    private var selectedEndpoint: String? = null
    private var selectedPeer: ProbePeerContext? = null
    private var linkToken: CallbackToken? = null
    private var accepted = false
    private var connected = false
    private var exchange = LinkExchange()
    private val helloReceived get() = exchange.helloReceived
    private val localFinishAcknowledged get() = exchange.localFinishAcknowledged
    private var finishingGrace = false
    private var finishTransmissions = 0
    private val pendingSend get() = exchange.pending
    private val transfers = mutableMapOf<Long, Transfer>()
    private var radioFailures = 0
    private var waitingForRadio = false
    private var permissionTicket = System.nanoTime()
    private var permissionsNeeded = emptyList<String>()
    private var monitoring = false
    private var lastNetworkPresent: Boolean? = null

    private data class Transfer(val token: CallbackToken, val purpose: String, val sendSerial: Long? = null)

    private val radioReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = onMain {
            if (!active) return@onMain
            event("radio_state_changed", "radio" to if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) "bluetooth" else "wifi")
            if (!active) return@onMain
            if (!bluetoothEnabled()) {
                resetRadio()
                waitingForRadio = true
                status("Bluetooth is off. Enable it in Settings to continue this session.")
            } else if (waitingForRadio) {
                waitingForRadio = false
                startRadio()
            }
        }
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = recordNetwork(true)
        override fun onLost(network: Network) = recordNetwork(false)
    }

    override fun onCreate() {
        super.onCreate()
        journal = SessionJournal(File(filesDir, "foreground-probe-session.bin"))
        try {
            saved = journal.load()
            if (saved?.open == true) message = "Interrupted session saved. Tap Resume to continue."
        } catch (_: IOException) {
            message = "Saved session could not be read. Start a new test session."
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Active transport test", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> { promote(); start(false, intent.getIntExtra(EXTRA_SIZE, 2048)) }
            ACTION_RESUME -> { promote(); start(true, 2048) }
            ACTION_STOP -> stopByUser()
            else -> if (!active) stopSelf()
        }
        // A killed process never resurrects radio work; the saved checkpoint needs explicit Resume.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.stop()
        active = false
        cancelTimers()
        stopSdk()
        unregisterMonitoring()
        observers.clear()
        super.onDestroy()
    }

    internal fun observe(observer: (ProbeSnapshot) -> Unit) {
        observers.add(observer)
        observer(snapshot())
    }
    internal fun removeObserver(observer: (ProbeSnapshot) -> Unit) { observers.remove(observer) }
    internal fun snapshot() = ProbeSnapshot(active, message, ledger?.checkpoint ?: saved,
        permissionTicket, permissionsNeeded, selectedPeer?.sessionID)

    internal fun permissionResult(ticket: Long, granted: Boolean) = onMain {
        if (!active || ticket != permissionTicket || permissionsNeeded.isEmpty()) return@onMain
        val missing = permissionsNeeded.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        permissionsNeeded = emptyList()
        if (!granted || missing.isNotEmpty()) {
            event("permission_denied")
            pause("Required Nearby or Location permission denied. Allow it in Settings, then tap Resume.")
        } else {
            event("permission_granted")
            startRadio()
        }
    }

    internal fun stopByUser() = onMain {
        permissionsNeeded = emptyList()
        permissionTicket++
        scope.stop()
        active = false
        cancelTimers()
        stopSdk()
        unregisterMonitoring()
        try {
            ledger?.record(ProbeEvent("session_stopped", Instant.now().toString()))
            ledger?.close()
            if (ledger == null && saved?.open == true) {
                saved = saved!!.copy(open = false)
                journal.save(saved!!)
            }
            saved = ledger?.checkpoint ?: saved
            status("Session stopped by user.")
        } catch (_: IOException) {
            status("Session stopped. The checkpoint could not be updated.")
        }
        leaveForeground()
        stopSelf()
    }

    private fun start(resume: Boolean, size: Int) {
        if (active) { publish(); return }
        try {
            val initial = if (resume) (ledger?.checkpoint ?: saved)?.takeIf { it.open }
                ?: throw IllegalArgumentException("no resumable session")
            else SessionCheckpoint(UUID.randomUUID().toString().replace("-", ""), size)
            ledger = SessionLedger(initial, journal::save)
            if (resume) ledger!!.resume()
            journal.save(ledger!!.checkpoint)
            saved = ledger!!.checkpoint
            scope.start()
            active = true
            radioFailures = 0
            permissionTicket++
            permissionsNeeded = emptyList()
            registerMonitoring()
            event(if (resume) "session_resumed" else "session_started", "payload_size_bytes" to "${initial.payloadSize}")
            startRadio()
        } catch (_: IOException) {
            freezeStorage()
        } catch (_: Exception) {
            pause("The active test session could not start. Check permissions and tap Start or Resume while this screen is open.")
        }
    }

    private fun promote() {
        val notification = notification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else startForeground(NOTIFICATION_ID, notification)
        foreground = true
    }

    private fun notification(): Notification {
        val reopen = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ProbeSessionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("TrailMesh transport test active")
            .setContentText(message.take(160)).setContentIntent(reopen).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
    }

    private fun startRadio() {
        if (!active) return
        resetRadio()
        val missing = NearbyPermissionPolicy.permissionsToRequest(Build.VERSION.SDK_INT,
            NearbyPermissionPolicy.requiredPermissions(Build.VERSION.SDK_INT).filter {
                checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }.toSet())
        if (missing.isNotEmpty()) { askPermissions(missing); return }
        if (!bluetoothEnabled()) {
            waitingForRadio = true
            status("Bluetooth is off. Enable it in Settings to continue; internet access is not required.")
            return
        }
        waitingForRadio = false
        val context = localContext()
        if (ledger!!.checkpoint.peers.size >= SessionLedger.MAX_PEERS &&
            ledger!!.checkpoint.peers.all { it.complete || it.exhausted }) {
            pause("This session reached its eight-peer limit. Start a new session for more peers.")
            return
        }
        val token = scope.capture()
        val advertising = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_POINT_TO_POINT)
            .setConnectionType(ConnectionType.NON_DISRUPTIVE).setLowPower(true).build()
        val discovery = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_POINT_TO_POINT).setLowPower(true).build()
        status("Finding compatible nearby probes. Each connection tests 20 payloads in both directions.")
        client.startAdvertising(context.encode(), SERVICE_ID, lifecycle(token), advertising)
            .addOnFailureListener { onMain { if (scope.acceptsRadio(token) && selectedEndpoint == null) nearbyFailure("Advertising", it) } }
        client.startDiscovery(SERVICE_ID, discovery(token), discovery)
            .addOnFailureListener { onMain { if (scope.acceptsRadio(token) && selectedEndpoint == null) nearbyFailure("Discovery", it) } }
        event("radio_cycle_started", "connection_policy" to "non_disruptive", "discovery_policy" to "low_power")
    }

    private fun discovery(token: CallbackToken) = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) = onMain {
            if (!scope.acceptsRadio(token) || selectedEndpoint != null || timers.containsKey("recovery")) return@onMain
            val peer = ProbePeerContext.parse(info.endpointName) ?: return@onMain
            if (!eligible(peer) || !localContext().canInitiate(peer)) return@onMain
            if (candidates.size < SessionLedger.MAX_PEERS) candidates[peer.sessionID] = endpointId to peer
            chooseCandidate()
        }
        override fun onEndpointLost(endpointId: String) = onMain {
            if (!scope.acceptsRadio(token)) return@onMain
            candidates.entries.removeAll { it.value.first == endpointId }
        }
    }

    private fun eligible(peer: ProbePeerContext, incoming: Boolean = false): Boolean {
        if (!localContext().isCompatible(peer)) return false
        val stored = ledger!!.peer(peer.sessionID)
        return stored?.let { !it.exhausted && (!it.complete || incoming &&
            ledger!!.canReplayCompletion(it.sessionID, System.currentTimeMillis())) }
            ?: (ledger!!.checkpoint.peers.size < SessionLedger.MAX_PEERS)
    }

    private fun chooseCandidate() {
        if (!active || selectedEndpoint != null || candidates.isEmpty()) return
        val candidate = candidates.values.first()
        if (!select(candidate.first, candidate.second)) return
        val token = scope.capture()
        val options = ConnectionOptions.Builder().setConnectionType(ConnectionType.NON_DISRUPTIVE)
            .setLowPower(true).build()
        event("connection_requested", "peer_platform" to candidate.second.platform.name.lowercase())
        client.requestConnection(localContext().encode(), candidate.first, lifecycle(token), options)
            .addOnFailureListener { onMain { if (scope.accepts(token)) nearbyFailure("Connection", it) } }
    }

    private fun select(endpointId: String, peer: ProbePeerContext, incoming: Boolean = false): Boolean {
        if (!active || selectedEndpoint != null || !eligible(peer, incoming)) return false
        if (!durable {
            if (ledger!!.peer(peer.sessionID)?.complete == true) {
                require(ledger!!.beginCompletionReplay(peer.sessionID, System.currentTimeMillis()))
            } else ledger!!.selectPeer(peer.sessionID, peer.platform.name.lowercase())
        } || !active) return false
        selectedEndpoint = endpointId
        selectedPeer = peer
        scope.select(endpointId)
        linkToken = scope.capture()
        client.stopDiscovery()
        status("Connecting to a compatible ${peer.platform.name.lowercase()} probe.")
        schedule("connection", CONNECTION_TIMEOUT) { recover("connection_timeout") }
        return true
    }

    private fun lifecycle(origin: CallbackToken) = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) = onMain {
            if (!scope.acceptsRadio(origin)) return@onMain
            val peer = ProbePeerContext.parse(info.endpointName)
            if (peer == null || !eligible(peer, incoming = true) ||
                (selectedEndpoint != null && (selectedEndpoint != endpointId || selectedPeer != peer))) {
                client.rejectConnection(endpointId)
                event("connection_rejected", "reason" to "incompatible_or_busy")
                return@onMain
            }
            if (selectedEndpoint == null && !select(endpointId, peer, incoming = true)) { client.rejectConnection(endpointId); return@onMain }
            if (accepted) return@onMain
            accepted = true
            val token = scope.capture()
            event("connection_accepted", "authentication" to "unauthenticated_generated_bytes_only")
            client.acceptConnection(endpointId, payloadCallback(token)).addOnFailureListener {
                onMain { if (scope.accepts(token, endpointId)) nearbyFailure("Connection", it) }
            }
        }
        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) = onMain {
            val token = linkToken ?: return@onMain
            if (!scope.acceptsRadio(origin) || !scope.accepts(token, endpointId)) return@onMain
            if (result.status.statusCode != ConnectionsStatusCodes.STATUS_OK) {
                event("connection_failed", "status_code" to "${result.status.statusCode}")
                recover("connection_failed")
                return@onMain
            }
            // A healthy link ends the consecutive radio-failure streak. Resetting on
            // just one start callback could retry forever when the other operation fails.
            radioFailures = 0
            if (connected) return@onMain
            connected = true
            cancel("connection")
            schedule("exchange_deadline", 180_000) { recover("exchange_deadline") }
            client.stopDiscovery()
            event("connected", "peer_platform" to selectedPeer!!.platform.name.lowercase())
            status("Connected. Exchanging generated bytes in both directions.")
            sendControl(ForegroundFrame.encodeHelloMessage(localContext().sessionID, selectedPeer!!.sessionID,
                localContext().payloadSize), "hello")
            schedule("hello", HELLO_TIMEOUT) { recover("hello_timeout") }
            if (helloReceived) { cancel("hello"); sendNext() }
        }
        override fun onDisconnected(endpointId: String) = onMain {
            val token = linkToken ?: return@onMain
            if (!scope.acceptsRadio(origin) || !scope.accepts(token, endpointId)) return@onMain
            event("disconnected")
            if (ledger!!.peer(selectedPeer!!.sessionID)?.complete == true) startRadio()
            else recover("peer_disconnected")
        }
        override fun onBandwidthChanged(endpointId: String, bandwidthInfo: BandwidthInfo) = onMain {
            val token = linkToken ?: return@onMain
            if (scope.acceptsRadio(origin) && scope.accepts(token, endpointId))
                event("bandwidth_changed", "quality" to "${bandwidthInfo.quality}")
        }
    }

    private fun payloadCallback(token: CallbackToken) = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) = onMain {
            if (!scope.accepts(token, endpointId)) return@onMain
            if (!exchange.acceptPacket()) {
                event("peer_frame_limit")
                val peer = selectedPeer ?: return@onMain
                if (!durable { ledger!!.abandon(peer.sessionID) }) return@onMain
                resetRadio()
                status("Peer sent too many frames. Finding other peers; Resume can retry saved progress.")
                schedule("recovery", 1_500) { startRadio() }
                return@onMain
            }
            val bytes = payload.asBytes() ?: run {
                client.cancelPayload(payload.id)
                event("invalid_frame", "reason" to "non_bytes_cancelled")
                return@onMain
            }
            try {
                when {
                    ForegroundFrame.isHelloMessage(bytes) -> hello(ForegroundFrame.decodeHelloMessage(bytes))
                    ForegroundFrame.isFinishMessage(bytes) -> finish(ForegroundFrame.decodeFinishMessage(bytes))
                    ForegroundFrame.isSessionAckMessage(bytes) -> acknowledge(ForegroundFrame.decodeSessionAckMessage(bytes))
                    else -> receive(ForegroundFrame.decodeSessionDataMessage(bytes))
                }
            } catch (_: IllegalArgumentException) { event("invalid_frame", "reason" to "validation_failed") }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) = onMain {
            if (!scope.accepts(token, endpointId)) return@onMain
            if (update.status == PayloadTransferUpdate.Status.IN_PROGRESS) return@onMain
            val transfer = transfers.remove(update.payloadId) ?: return@onMain
            if (!scope.accepts(transfer.token, endpointId)) return@onMain
            if (update.status == PayloadTransferUpdate.Status.SUCCESS) {
                if (transfer.purpose == "finish_ack") { exchange.finishAckDelivered(); maybeCompletePeer() }
            } else if (transfer.purpose == "data") {
                if (pendingSend?.serial == transfer.sendSerial) retryAttempt("payload_transfer_failed")
            } else if (transfer.purpose == "hello" || transfer.purpose == "finish") {
                recover("control_transfer_failed")
            } else event("acknowledgement_transfer_failed")
        }
    }

    private fun hello(value: ForegroundFrame.HelloMessage) {
        if (helloReceived) return
        exchange.hello(value, localContext(), selectedPeer!!)
        cancel("hello")
        event("hello_validated")
        if (connected) sendNext()
    }

    private fun receive(value: ForegroundFrame.SessionDataMessage) {
        require(helloReceived && value.sessionID == selectedPeer!!.sessionID &&
            value.attemptIndex in 0 until SessionLedger.ATTEMPTS && value.frame.payload.size == localContext().payloadSize)
        val expected = ForegroundFrame.makeTestPayload(localContext().payloadSize, value.attemptIndex)
        val matches = expected.contentEquals(value.frame.payload)
        val previous = ledger!!.peer(value.sessionID)!!.incoming[value.attemptIndex]
        val accepted = if (previous != 0) previous == 1 else matches
        val evidence = evidence(if (previous != 0) "payload_duplicate" else "payload_received", "attempt_index" to "${value.attemptIndex}",
            "payload_size_bytes" to "${value.frame.payload.size}", "success" to "$accepted",
            "direction" to direction(false), "expected_sha256" to ForegroundFrame.sha256Hex(expected),
            "received_sha256" to ForegroundFrame.hex(value.frame.digest))
        if (!durable { ledger!!.receive(value.sessionID, value.attemptIndex, matches, evidence) }) return
        if (previous == 0 && accepted && timers.containsKey("finish_wait")) {
            schedule("finish_wait", 60_000) { recover("reciprocal_progress_timeout") }
        }
        if (!active) return
        sendControl(ForegroundFrame.encodeSessionAckMessage(value.sessionID, value.attemptIndex,
            accepted, value.frame.digest), "ack")
        publish()
    }

    private fun acknowledge(value: ForegroundFrame.SessionAckMessage) {
        if (pendingSend == null) return
        if (!exchange.matchesAck(value, localContext().sessionID)) {
            event("stale_acknowledgement_ignored")
            return
        }
        completeAttempt(value.accepted, if (value.accepted) "acknowledged" else "peer_rejected", value.digest)
    }

    private fun sendNext() {
        if (!active || !connected || !helloReceived || pendingSend != null) return
        val peer = ledger!!.peer(selectedPeer!!.sessionID)!!
        if (peer.nextOutgoing >= SessionLedger.ATTEMPTS) { sendFinish(); return }
        if (peer.transmissions >= SessionLedger.MAX_TRANSMISSIONS) { completeAttempt(false, "transmission_limit"); return }
        if (!durable { ledger!!.beginTransmission(peer.sessionID) }) return
        val bytes = ForegroundFrame.makeTestPayload(localContext().payloadSize, peer.nextOutgoing)
        val pending = exchange.beginSend(peer.nextOutgoing, ForegroundFrame.sha256(bytes))
        event("payload_sent", "attempt_index" to "${pending.index}", "transmission" to "${peer.transmissions + 1}",
            "payload_size_bytes" to "${bytes.size}", "direction" to direction(true), "expected_sha256" to ForegroundFrame.hex(pending.digest))
        if (!active) return
        sendBytes(ForegroundFrame.encodeSessionDataMessage(localContext().sessionID, pending.index, bytes), "data", pending.serial)
        schedule("ack", ACK_TIMEOUT) { if (pendingSend?.serial == pending.serial) retryAttempt("acknowledgement_timeout") }
    }

    private fun retryAttempt(reason: String) {
        if (!active || pendingSend == null) return
        val peer = ledger!!.peer(selectedPeer!!.sessionID)!!
        if (peer.transmissions >= SessionLedger.MAX_TRANSMISSIONS) completeAttempt(false, reason)
        else {
            cancel("ack")
            exchange.clearPending()
            event("attempt_retry", "reason" to reason)
            schedule("next_send", 300) { sendNext() }
        }
    }

    private fun completeAttempt(success: Boolean, reason: String, receivedDigest: ByteArray? = null) {
        val peer = selectedPeer ?: return
        val index = ledger!!.peer(peer.sessionID)!!.nextOutgoing
        cancel("ack")
        val digest = ForegroundFrame.sha256(ForegroundFrame.makeTestPayload(localContext().payloadSize, index))
        val result = evidence("attempt_result", "attempt_index" to "$index", "payload_size_bytes" to "${localContext().payloadSize}",
            "direction" to direction(true), "success" to "$success", "failure_reason" to if (success) "none" else reason,
            "expected_sha256" to ForegroundFrame.hex(digest), "received_sha256" to (receivedDigest?.let(ForegroundFrame::hex) ?: "unavailable"))
        if (!durable { ledger!!.completeOutgoing(peer.sessionID, success, result) }) return
        exchange.clearPending()
        transfers.entries.removeAll { it.value.purpose == "data" }
        schedule("next_send", 100) { sendNext() }
        publish()
    }

    private fun sendFinish() {
        if (!active || localFinishAcknowledged || timers.containsKey("finish")) { maybeCompletePeer(); return }
        if (finishTransmissions >= SessionLedger.MAX_TRANSMISSIONS) { recover("finish_timeout"); return }
        val peer = ledger!!.peer(selectedPeer!!.sessionID)!!
        if (peer.nextOutgoing != SessionLedger.ATTEMPTS) return
        finishTransmissions++
        sendControl(ForegroundFrame.encodeFinishMessage(localContext().sessionID, peer.sessionID, false,
            peer.successfulOutgoing, peer.failedOutgoing), "finish")
        schedule("finish", FINISH_TIMEOUT) { sendFinish() }
    }

    private fun finish(value: ForegroundFrame.FinishMessage) {
        require(helloReceived && value.sessionID == selectedPeer!!.sessionID && value.peerSessionID == localContext().sessionID)
        val peer = ledger!!.peer(selectedPeer!!.sessionID)!!
        if (value.acknowledgement) {
            exchange.finishAck(value, localContext().sessionID, peer)
            cancel("finish")
            event("finish_acknowledged")
        } else {
            if (!durable { ledger!!.remoteFinished(peer.sessionID, value.successfulAttempts, value.failedAttempts) }) return
            cancel("departure")
            finishingGrace = false
            exchange.remoteFinished()
            event("remote_finished", "successful_attempts" to "${value.successfulAttempts}", "failed_attempts" to "${value.failedAttempts}")
            if (!active) return
            sendControl(ForegroundFrame.encodeFinishMessage(localContext().sessionID, peer.sessionID, true,
                value.successfulAttempts, value.failedAttempts), "finish_ack")
        }
        maybeCompletePeer()
    }

    private fun maybeCompletePeer() {
        if (!active || !connected || finishingGrace) return
        val complete = ledger!!.peer(selectedPeer!!.sessionID)!!.nextOutgoing == SessionLedger.ATTEMPTS
        if (!exchange.canDepart(complete) || transfers.values.any { it.purpose == "finish_ack" }) {
            if (complete && !timers.containsKey("finish_wait")) schedule("finish_wait", 60_000) { recover("reciprocal_progress_timeout") }
            return
        }
        cancel("finish_wait")
        finishingGrace = true
        schedule("departure", 2_000) {
            val peer = selectedPeer ?: return@schedule
            if (!exchange.canDepart(ledger!!.peer(peer.sessionID)!!.nextOutgoing == SessionLedger.ATTEMPTS) ||
                transfers.values.any { it.purpose == "finish_ack" }) {
                finishingGrace = false
                maybeCompletePeer()
                return@schedule
            }
            if (!durable { ledger!!.markComplete(peer.sessionID) }) return@schedule
            event("peer_batch_complete", "sent_successes" to "${ledger!!.peer(peer.sessionID)!!.successfulOutgoing}",
                "sent_failures" to "${ledger!!.peer(peer.sessionID)!!.failedOutgoing}",
                "received_unique" to "${ledger!!.peer(peer.sessionID)!!.receivedAccepted}")
            status("Both directions finished. Finding the next compatible peer.")
            startRadio()
        }
    }

    private fun sendControl(bytes: ByteArray, purpose: String) { if (active) sendBytes(bytes, purpose) }
    private fun sendBytes(bytes: ByteArray, purpose: String, serial: Long? = null) {
        val endpoint = selectedEndpoint ?: return
        val token = scope.capture()
        val payload = Payload.fromBytes(bytes)
        transfers[payload.id] = Transfer(token, purpose, serial)
        client.sendPayload(endpoint, payload).addOnFailureListener { onMain {
            val transfer = transfers.remove(payload.id) ?: return@onMain
            if (!scope.accepts(transfer.token, endpoint)) return@onMain
            event("payload_send_failed", "kind" to purpose)
            if (purpose == "data" && pendingSend?.serial == serial) retryAttempt("payload_send_failed")
            else if (purpose == "hello" || purpose == "finish") recover("control_send_failed")
        } }
    }

    private fun recover(reason: String) {
        if (!active) return
        val peer = selectedPeer
        event("connection_recovery", "reason" to reason)
        if (peer != null && ledger!!.peer(peer.sessionID)?.complete == true) {
            resetRadio()
            schedule("recovery", 1_000) { startRadio() }
            return
        }
        var delay: Long? = null
        if (peer != null && !durable { delay = ledger!!.nextRecovery(peer.sessionID) }) return
        resetRadio()
        if (!active) return
        if (peer != null && delay == null) {
            if (!durable { ledger!!.abandon(peer.sessionID) }) return
            event("peer_recovery_exhausted")
            status("Peer recovery limit reached. Progress is saved; finding other peers.")
            schedule("recovery", 1_000) { startRadio() }
        } else {
            val wait = (delay ?: 1_000L) + Random.nextLong(0, 501)
            status("Connection interrupted. Retrying automatically with saved progress.")
            schedule("recovery", wait) { startRadio() }
        }
    }

    private fun nearbyFailure(operation: String, exception: Exception) {
        val code = (exception as? ApiException)?.statusCode
        event("nearby_operation_failed", "operation" to operation.lowercase(), "status_code" to (code?.toString() ?: "unknown"),
            "status_name" to (code?.let(ConnectionsStatusCodes::getStatusCodeString)?.take(160) ?: "unknown"),
            "exception_type" to exception.javaClass.simpleName.take(64))
        if (!active) return
        val granted = listOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
            .filter { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }.toSet()
        val compatibility = NearbyPermissionPolicy.permissionsForCompatibilityFailure(Build.VERSION.SDK_INT, operation, code, granted)
        if (compatibility.isNotEmpty()) { askPermissions(compatibility); return }
        if (selectedPeer != null) recover("nearby_operation_failed")
        else if (++radioFailures <= SessionLedger.MAX_RECOVERIES) {
            resetRadio()
            status("Nearby could not start. Retrying automatically; see the redacted log for its status code.")
            schedule("recovery", (1_000L shl (radioFailures - 1)) + Random.nextLong(0, 501)) { startRadio() }
        } else pause("Nearby could not start after five recoveries. Check radio settings and permissions, then Resume.")
    }

    private fun askPermissions(permissions: List<String>) {
        resetRadio()
        permissionsNeeded = permissions
        permissionTicket++
        status("Nearby requires additional Location or device permission. Return to this screen to allow it and continue.")
        event("permission_required", "permissions" to permissions.joinToString(",").take(160))
    }

    private fun resetRadio() {
        scope.restartRadio()
        cancelTimers()
        stopSdk()
        candidates.clear()
        selectedEndpoint = null
        selectedPeer = null
        linkToken = null
        accepted = false
        connected = false
        exchange = LinkExchange()
        transfers.clear()
        finishingGrace = false
        finishTransmissions = 0
    }

    private fun stopSdk() {
        try { client.stopDiscovery(); client.stopAdvertising(); client.stopAllEndpoints() } catch (_: Exception) { }
    }

    private fun pause(reason: String) {
        active = false
        scope.stop()
        cancelTimers()
        stopSdk()
        unregisterMonitoring()
        permissionsNeeded = emptyList()
        status(reason)
        leaveForeground()
        stopSelf()
    }

    private fun freezeStorage() { pause("Storage checkpoint failed. The session is paused; no success acknowledgement was sent. Check storage, then Resume.") }

    private fun durable(block: () -> Unit): Boolean = try {
        block()
        saved = ledger?.checkpoint
        true
    } catch (_: IOException) { freezeStorage(); false }

    private fun evidence(name: String, vararg fields: Pair<String, String>): ProbeEvent =
        ProbeEvent(name, Instant.now().toString(), mapOf(*fields) +
            (selectedPeer?.let { mapOf("peer_session_id" to it.sessionID) } ?: emptyMap()))

    private fun direction(outgoing: Boolean): String {
        val peer = if (selectedPeer?.platform == ProbePlatform.IOS) "iphone" else "android"
        return if (outgoing) "android-to-$peer" else "$peer-to-android"
    }

    private fun event(name: String, vararg fields: Pair<String, String>) {
        if (ledger == null) return
        durable { ledger!!.record(evidence(name, *fields)) }
    }

    private fun localContext() = ProbePeerContext(ProbePlatform.ANDROID, ledger!!.checkpoint.sessionID, ledger!!.checkpoint.payloadSize)
    private fun bluetoothEnabled(): Boolean = try { getSystemService(BluetoothManager::class.java).adapter?.isEnabled == true }
        catch (_: SecurityException) { false }

    private fun status(value: String) { message = value; publish() }
    private fun publish() {
        val state = snapshot()
        observers.toList().forEach { it(state) }
        if (foreground) getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    private fun schedule(name: String, delay: Long, block: () -> Unit) {
        if (!active) return
        cancel(name)
        val token = scope.capture()
        val callback = Runnable {
            timers.remove(name)
            if (scope.accepts(token)) block()
        }
        timers[name] = callback
        handler.postDelayed(callback, delay)
    }
    private fun cancel(name: String) { timers.remove(name)?.let(handler::removeCallbacks) }
    private fun cancelTimers() { timers.values.forEach(handler::removeCallbacks); timers.clear() }
    private fun onMain(block: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) block() else handler.post(block) }

    private fun recordNetwork(present: Boolean) = onMain {
        if (!active || lastNetworkPresent == present) return@onMain
        lastNetworkPresent = present
        event("default_network_changed", "available" to "$present")
        // Network association is diagnostic information, never a reason to drop a working SDK link.
    }
    private fun registerMonitoring() {
        if (monitoring) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED).apply { addAction(WifiManager.WIFI_STATE_CHANGED_ACTION) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(radioReceiver, filter, RECEIVER_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(radioReceiver, filter)
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
        monitoring = true
    }
    private fun unregisterMonitoring() {
        if (!monitoring) return
        unregisterReceiver(radioReceiver)
        getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback)
        monitoring = false
        lastNetworkPresent = null
    }
    private fun leaveForeground() {
        if (foreground) { stopForeground(STOP_FOREGROUND_REMOVE); foreground = false }
    }

    internal fun exportedLog(): String {
        val state = snapshot()
        val info = packageManager.getPackageInfo(packageName, 0)
        val events = JSONArray()
        state.checkpoint?.events?.forEach { event ->
            val record = JSONObject().put("event", event.name).put("observed_at", event.time)
            event.fields.forEach { (key, value) -> record.put(key, when {
                key in setOf("success", "duplicate", "available") -> value == "true"
                key in setOf("attempt_index", "payload_size_bytes", "transmission", "successful_attempts", "failed_attempts", "quality", "status_code") ->
                    value.toIntOrNull() ?: JSONObject.NULL
                key in setOf("received_sha256", "failure_reason") && value in setOf("unavailable", "none") -> JSONObject.NULL
                else -> value
            }) }
            events.put(record)
        }
        return JSONObject().put("schema", "trailmesh.foreground-probe-log").put("version", 2)
            .put("platform", "android").put("device", JSONObject().put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("os_version", Build.VERSION.RELEASE).put("sdk_int", Build.VERSION.SDK_INT)
                .put("app_version", info.versionName).put("app_build", if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else 2))
            .put("transport", "Google Nearby Connections 19.5.0").put("strategy", "P2P_POINT_TO_POINT")
            .put("probe_protocol", 2).put("session_id", state.checkpoint?.sessionID ?: JSONObject.NULL)
            .put("pairing_mode", "automatic").put("connection_policy", "non_disruptive")
            .put("underlying_medium", "SDK selected; quality is not a medium identifier")
            .put("automatic_test_acceptance", true).put("internet_disabled", JSONObject.NULL)
            .put("evicted_records", state.checkpoint?.evictedRecords ?: 0)
            .put("active", state.active).put("status", state.status).put("attempts", events).toString(2)
    }

    companion object {
        const val ACTION_START = "org.trailmesh.foregroundprobe.START"
        const val ACTION_RESUME = "org.trailmesh.foregroundprobe.RESUME"
        const val ACTION_STOP = "org.trailmesh.foregroundprobe.STOP"
        const val EXTRA_SIZE = "payload_size"
        private const val SERVICE_ID = "org.trailmesh.foregroundprobe"
        private const val CHANNEL = "active_transport_test"
        private const val NOTIFICATION_ID = 24
        private const val CONNECTION_TIMEOUT = 20_000L
        private const val HELLO_TIMEOUT = 15_000L
        private const val ACK_TIMEOUT = 15_000L
        private const val FINISH_TIMEOUT = 5_000L
    }
}

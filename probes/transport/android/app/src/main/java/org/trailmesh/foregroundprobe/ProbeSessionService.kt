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
import android.os.SystemClock
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
    val activePeers: Int, val waitingPeers: Int,
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
    private val scheduler = PeerScheduler()
    private val registry = ProbeLinkRegistry(scope)
    private val links get() = registry.links
    // The shared advertising delegate cannot identify an old attempt after endpoint reuse.
    // Keep retired IDs until the radio rotates, after all healthy links have drained.
    private val cooldowns = mutableMapOf<String, Long>()
    private var restartWhenIdle = false
    private var radioFailures = 0
    private var waitingForRadio = false
    private var permissionTicket = System.nanoTime()
    private var permissionsNeeded = emptyList<String>()
    private var monitoring = false
    private var lastNetworkPresent: Boolean? = null

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
        links.values.forEach { it.cancelTimers(handler); it.transfers.clear() }
        registry.clear()
        scheduler.clear()
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
        permissionTicket, permissionsNeeded, links.size, scheduler.waitingCount)

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
        links.values.forEach { it.cancelTimers(handler); it.transfers.clear() }
        registry.clear()
        scheduler.clear()
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
            cooldowns.clear()
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
            pause("This controlled test run reached its eight-peer journal limit. Start a new run for more peers.")
            return
        }
        val token = scope.capture()
        val advertising = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER)
            .setConnectionType(ConnectionType.NON_DISRUPTIVE).setLowPower(true).build()
        val discovery = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).setLowPower(true).build()
        status("Finding cluster probes. Up to four links run together; this controlled test records eight peers.")
        client.startAdvertising(context.encode(), SERVICE_ID, lifecycle(token), advertising)
            .addOnFailureListener { onMain { if (scope.acceptsRadio(token)) nearbyFailure("Advertising", it) } }
        client.startDiscovery(SERVICE_ID, discovery(token), discovery)
            .addOnFailureListener { onMain { if (scope.acceptsRadio(token)) nearbyFailure("Discovery", it) } }
        event("radio_cycle_started", "connection_policy" to "non_disruptive", "discovery_policy" to "low_power")
    }

    private fun discovery(token: CallbackToken) = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) = onMain {
            if (!scope.acceptsRadio(token) || timers.containsKey("recovery")) return@onMain
            val peer = ProbePeerContext.parse(info.endpointName) ?: return@onMain
            if (!eligible(peer) || !localContext().canInitiate(peer)) return@onMain
            scheduler.discover(endpointId, peer, cooldowns[peer.sessionID] ?: 0)
            chooseCandidates()
        }
        override fun onEndpointLost(endpointId: String) = onMain {
            if (!scope.acceptsRadio(token)) return@onMain
            scheduler.lost(endpointId)
            publish()
        }
    }

    private fun eligible(peer: ProbePeerContext, incoming: Boolean = false): Boolean {
        if (!localContext().isCompatible(peer)) return false
        if (incoming && SystemClock.elapsedRealtime() < (cooldowns[peer.sessionID] ?: 0)) return false
        val stored = ledger!!.peer(peer.sessionID)
        return stored?.let { !it.exhausted && (!it.complete || incoming &&
            ledger!!.canReplayCompletion(it.sessionID, System.currentTimeMillis())) }
            ?: (ledger!!.checkpoint.peers.size < SessionLedger.MAX_PEERS)
    }

    private fun chooseCandidates() {
        if (!active || timers.containsKey("recovery")) return
        cancel("candidate_retry")
        if (links.isEmpty() && ledger!!.checkpoint.peers.size >= SessionLedger.MAX_PEERS &&
            ledger!!.checkpoint.peers.all { it.complete || it.exhausted }) {
            pause("This controlled test run reached its eight-peer journal limit. Start a new run for more peers.")
            return
        }
        while (links.size < PeerScheduler.MAX_LINKS) {
            val candidate = scheduler.takeNext(SystemClock.elapsedRealtime(),
                { eligible(it.peer) }, { !registry.wasRetired(it.endpoint) }) ?: break
            val link = select(candidate.endpoint, candidate.peer)
            if (link == null) {
                scheduler.release(candidate.endpoint)
                if (!active) return
                continue
            }
            val options = ConnectionOptions.Builder().setConnectionType(ConnectionType.NON_DISRUPTIVE)
                .setLowPower(true).build()
            event(link, "connection_requested", "peer_platform" to link.peer.platform.name.lowercase())
            if (!current(link)) return
            client.requestConnection(localContext().encode(), link.endpoint, lifecycle(scope.capture(), link.token), options)
                .addOnFailureListener { onMain { if (current(link)) nearbyFailure("Connection", it, link) } }
        }
        if (links.isEmpty() && (restartWhenIdle || scheduler.waitingCount > 0 || registry.hasRetiredEndpoints)) {
            val readyAt = scheduler.nextReadyAt ?: SystemClock.elapsedRealtime()
            schedule("candidate_retry", maxOf(1_000, readyAt - SystemClock.elapsedRealtime())) { startRadio() }
        }
        publish()
    }

    private fun select(endpointId: String, peer: ProbePeerContext, incoming: Boolean = false): ProbeLink? {
        if (!active || registry.wasRetired(endpointId) || links.containsKey(endpointId) || !eligible(peer, incoming)) return null
        if (!durable {
            if (ledger!!.peer(peer.sessionID)?.complete == true) {
                require(ledger!!.beginCompletionReplay(peer.sessionID, System.currentTimeMillis()))
            } else requireNotNull(ledger!!.selectPeer(peer.sessionID, peer.platform.name.lowercase()))
        } || !active) return null
        val link = registry.add(endpointId, peer) ?: return null
        status("${links.size}/4 links connecting or exchanging; ${scheduler.waitingCount} waiting.")
        schedule(link, "connection", CONNECTION_TIMEOUT) { recover(link, "connection_timeout") }
        return link
    }

    private fun current(link: ProbeLink): Boolean = active && registry.current(link.token) === link

    private fun lifecycle(origin: CallbackToken, requested: CallbackToken? = null) = object : ConnectionLifecycleCallback() {
        // Tokens are captured when this callback accepts its first initiation for an endpoint.
        // A delayed result/disconnect never borrows a replacement link's token.
        private val callbacks = LinkCallbacks(requested)
        private fun linkFor(endpoint: String): ProbeLink? {
            if (!scope.acceptsRadio(origin)) return null
            val token = callbacks.token(endpoint) ?: return null
            return registry.current(token, endpoint)
        }

        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) = onMain {
            if (!scope.acceptsRadio(origin)) return@onMain
            if (requested != null && !scope.accepts(requested, endpointId)) return@onMain
            val peer = ProbePeerContext.parse(info.endpointName)
            var link = links[endpointId]
            if (peer == null || registry.wasRetired(endpointId) ||
                (link != null && link.peer != peer) || !eligible(peer, incoming = true)) {
                client.rejectConnection(endpointId)
                event("connection_rejected", "reason" to "incompatible_or_busy")
                return@onMain
            }
            if (link == null) {
                if (!scheduler.reserveIncoming(endpointId, peer)) {
                    client.rejectConnection(endpointId)
                    return@onMain
                }
                link = select(endpointId, peer, incoming = true)
                if (link == null) {
                    scheduler.release(endpointId)
                    client.rejectConnection(endpointId)
                    return@onMain
                }
            }
            val selected = link
            if (!callbacks.initiate(selected)) return@onMain
            if (selected.accepted) return@onMain
            selected.accepted = true
            event(selected, "connection_accepted", "authentication" to "unauthenticated_generated_bytes_only")
            if (!current(selected)) return@onMain
            client.acceptConnection(endpointId, payloadCallback(selected)).addOnFailureListener {
                onMain { if (current(selected)) nearbyFailure("Connection", it, selected) }
            }
        }
        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) = onMain {
            val link = linkFor(endpointId) ?: return@onMain
            if (result.status.statusCode != ConnectionsStatusCodes.STATUS_OK) {
                event(link, "connection_failed", "status_code" to "${result.status.statusCode}")
                recover(link, "connection_failed")
                return@onMain
            }
            // A healthy link ends the consecutive radio-failure streak. Resetting on
            // just one start callback could retry forever when the other operation fails.
            radioFailures = 0
            if (link.connected) return@onMain
            link.connected = true
            cancel(link, "connection")
            schedule(link, "exchange_deadline", 180_000) { recover(link, "exchange_deadline") }
            event(link, "connected", "peer_platform" to link.peer.platform.name.lowercase())
            if (!current(link)) return@onMain
            status("${links.size}/4 cluster links connected or connecting. Exchanging generated bytes.")
            if (!current(link)) return@onMain
            sendControl(link, ForegroundFrame.encodeHelloMessage(localContext().sessionID, link.peer.sessionID,
                localContext().payloadSize), "hello")
            schedule(link, "hello", HELLO_TIMEOUT) { recover(link, "hello_timeout") }
            if (link.helloReceived) { cancel(link, "hello"); sendNext(link) }
        }
        override fun onDisconnected(endpointId: String) = onMain {
            val link = linkFor(endpointId) ?: return@onMain
            event(link, "disconnected")
            if (ledger!!.peer(link.peer.sessionID)?.complete == true) depart(link)
            else recover(link, "peer_disconnected")
        }
        override fun onBandwidthChanged(endpointId: String, bandwidthInfo: BandwidthInfo) = onMain {
            val link = linkFor(endpointId) ?: return@onMain
            event(link, "bandwidth_changed", "quality" to "${bandwidthInfo.quality}")
        }
    }

    private fun payloadCallback(link: ProbeLink) = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) = onLinkMain(link) {
            if (!current(link) || endpointId != link.endpoint) return@onLinkMain
            if (!link.exchange.acceptPacket()) {
                event(link, "peer_frame_limit")
                if (!current(link)) return@onLinkMain
                val peer = link.peer
                if (!durable { ledger!!.abandon(peer.sessionID) }) return@onLinkMain
                depart(link)
                if (!active) return@onLinkMain
                status("Peer sent too many frames. Other cluster links continue; Resume can retry saved progress.")
                return@onLinkMain
            }
            val bytes = payload.asBytes() ?: run {
                client.cancelPayload(payload.id)
                event(link, "invalid_frame", "reason" to "non_bytes_cancelled")
                return@onLinkMain
            }
            try {
                when {
                    ForegroundFrame.isHelloMessage(bytes) -> hello(link, ForegroundFrame.decodeHelloMessage(bytes))
                    ForegroundFrame.isFinishMessage(bytes) -> finish(link, ForegroundFrame.decodeFinishMessage(bytes))
                    ForegroundFrame.isSessionAckMessage(bytes) -> acknowledge(link, ForegroundFrame.decodeSessionAckMessage(bytes))
                    else -> receive(link, ForegroundFrame.decodeSessionDataMessage(bytes))
                }
            } catch (_: IllegalArgumentException) { event(link, "invalid_frame", "reason" to "validation_failed") }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) = onLinkMain(link) {
            if (!current(link) || endpointId != link.endpoint) return@onLinkMain
            if (update.status == PayloadTransferUpdate.Status.IN_PROGRESS) return@onLinkMain
            val transfer = link.transfers.remove(update.payloadId) ?: return@onLinkMain
            if (!scope.accepts(transfer.token, endpointId)) return@onLinkMain
            if (update.status == PayloadTransferUpdate.Status.SUCCESS) {
                if (transfer.purpose == "finish_ack") { link.exchange.finishAckDelivered(); maybeCompletePeer(link) }
            } else if (transfer.purpose == "data") {
                if (link.pendingSend?.serial == transfer.sendSerial) retryAttempt(link, "payload_transfer_failed")
            } else if (transfer.purpose == "hello" || transfer.purpose == "finish") {
                recover(link, "control_transfer_failed")
            } else event(link, "acknowledgement_transfer_failed")
        }
    }

    private fun hello(link: ProbeLink, value: ForegroundFrame.HelloMessage) {
        if (link.helloReceived) return
        link.exchange.hello(value, localContext(), link.peer)
        cancel(link, "hello")
        event(link, "hello_validated")
        if (link.connected) sendNext(link)
    }

    private fun receive(link: ProbeLink, value: ForegroundFrame.SessionDataMessage) {
        require(link.helloReceived && value.sessionID == link.peer.sessionID &&
            value.attemptIndex in 0 until SessionLedger.ATTEMPTS && value.frame.payload.size == localContext().payloadSize)
        val expected = ForegroundFrame.makeTestPayload(localContext().payloadSize, value.attemptIndex)
        val matches = expected.contentEquals(value.frame.payload)
        val previous = ledger!!.peer(value.sessionID)!!.incoming[value.attemptIndex]
        val accepted = if (previous != 0) previous == 1 else matches
        val evidence = evidence(link, if (previous != 0) "payload_duplicate" else "payload_received", "attempt_index" to "${value.attemptIndex}",
            "payload_size_bytes" to "${value.frame.payload.size}", "success" to "$accepted",
            "direction" to direction(link, false), "expected_sha256" to ForegroundFrame.sha256Hex(expected),
            "received_sha256" to ForegroundFrame.hex(value.frame.digest))
        if (!durable { ledger!!.receive(value.sessionID, value.attemptIndex, matches, evidence) }) return
        if (previous == 0 && accepted && link.timers.containsKey("finish_wait")) {
            schedule(link, "finish_wait", 60_000) { recover(link, "reciprocal_progress_timeout") }
        }
        if (!current(link)) return
        sendControl(link, ForegroundFrame.encodeSessionAckMessage(value.sessionID, value.attemptIndex,
            accepted, value.frame.digest), "ack")
        publish()
    }

    private fun acknowledge(link: ProbeLink, value: ForegroundFrame.SessionAckMessage) {
        if (link.pendingSend == null) return
        if (!link.exchange.matchesAck(value, localContext().sessionID)) {
            event(link, "stale_acknowledgement_ignored")
            return
        }
        completeAttempt(link, value.accepted, if (value.accepted) "acknowledged" else "peer_rejected", value.digest)
    }

    private fun sendNext(link: ProbeLink) {
        if (!current(link) || !link.connected || !link.helloReceived || link.pendingSend != null) return
        val peer = ledger!!.peer(link.peer.sessionID)!!
        if (peer.nextOutgoing >= SessionLedger.ATTEMPTS) { sendFinish(link); return }
        if (peer.transmissions >= SessionLedger.MAX_TRANSMISSIONS) { completeAttempt(link, false, "transmission_limit"); return }
        if (!durable { ledger!!.beginTransmission(peer.sessionID) }) return
        val bytes = ForegroundFrame.makeTestPayload(localContext().payloadSize, peer.nextOutgoing)
        val pending = link.exchange.beginSend(peer.nextOutgoing, ForegroundFrame.sha256(bytes))
        event(link, "payload_sent", "attempt_index" to "${pending.index}", "transmission" to "${peer.transmissions + 1}",
            "payload_size_bytes" to "${bytes.size}", "direction" to direction(link, true), "expected_sha256" to ForegroundFrame.hex(pending.digest))
        if (!current(link)) return
        sendBytes(link, ForegroundFrame.encodeSessionDataMessage(localContext().sessionID, pending.index, bytes), "data", pending.serial)
        schedule(link, "ack", ACK_TIMEOUT) { if (link.pendingSend?.serial == pending.serial) retryAttempt(link, "acknowledgement_timeout") }
    }

    private fun retryAttempt(link: ProbeLink, reason: String) {
        if (!current(link) || link.pendingSend == null) return
        val peer = ledger!!.peer(link.peer.sessionID)!!
        if (peer.transmissions >= SessionLedger.MAX_TRANSMISSIONS) completeAttempt(link, false, reason)
        else {
            cancel(link, "ack")
            link.exchange.clearPending()
            event(link, "attempt_retry", "reason" to reason)
            schedule(link, "next_send", 300) { sendNext(link) }
        }
    }

    private fun completeAttempt(link: ProbeLink, success: Boolean, reason: String, receivedDigest: ByteArray? = null) {
        val peer = link.peer
        val index = ledger!!.peer(peer.sessionID)!!.nextOutgoing
        cancel(link, "ack")
        val digest = ForegroundFrame.sha256(ForegroundFrame.makeTestPayload(localContext().payloadSize, index))
        val result = evidence(link, "attempt_result", "attempt_index" to "$index", "payload_size_bytes" to "${localContext().payloadSize}",
            "direction" to direction(link, true), "success" to "$success", "failure_reason" to if (success) "none" else reason,
            "expected_sha256" to ForegroundFrame.hex(digest), "received_sha256" to (receivedDigest?.let(ForegroundFrame::hex) ?: "unavailable"))
        if (!durable { ledger!!.completeOutgoing(peer.sessionID, success, result) }) return
        link.exchange.clearPending()
        link.transfers.entries.removeAll { it.value.purpose == "data" }
        schedule(link, "next_send", 100) { sendNext(link) }
        publish()
    }

    private fun sendFinish(link: ProbeLink) {
        if (!active || link.localFinishAcknowledged || link.timers.containsKey("finish")) { maybeCompletePeer(link); return }
        if (link.finishTransmissions >= SessionLedger.MAX_TRANSMISSIONS) { recover(link, "finish_timeout"); return }
        val peer = ledger!!.peer(link.peer.sessionID)!!
        if (peer.nextOutgoing != SessionLedger.ATTEMPTS) return
        link.finishTransmissions++
        sendControl(link, ForegroundFrame.encodeFinishMessage(localContext().sessionID, peer.sessionID, false,
            peer.successfulOutgoing, peer.failedOutgoing), "finish")
        schedule(link, "finish", FINISH_TIMEOUT) { sendFinish(link) }
    }

    private fun finish(link: ProbeLink, value: ForegroundFrame.FinishMessage) {
        require(link.helloReceived && value.sessionID == link.peer.sessionID && value.peerSessionID == localContext().sessionID)
        val peer = ledger!!.peer(link.peer.sessionID)!!
        if (value.acknowledgement) {
            link.exchange.finishAck(value, localContext().sessionID, peer)
            cancel(link, "finish")
            event(link, "finish_acknowledged")
        } else {
            if (!durable { ledger!!.remoteFinished(peer.sessionID, value.successfulAttempts, value.failedAttempts) }) return
            cancel(link, "departure")
            link.finishingGrace = false
            link.exchange.remoteFinished()
            event(link, "remote_finished", "successful_attempts" to "${value.successfulAttempts}", "failed_attempts" to "${value.failedAttempts}")
            if (!current(link)) return
            sendControl(link, ForegroundFrame.encodeFinishMessage(localContext().sessionID, peer.sessionID, true,
                value.successfulAttempts, value.failedAttempts), "finish_ack")
        }
        maybeCompletePeer(link)
    }

    private fun maybeCompletePeer(link: ProbeLink) {
        if (!current(link) || !link.connected || link.finishingGrace) return
        val complete = ledger!!.peer(link.peer.sessionID)!!.nextOutgoing == SessionLedger.ATTEMPTS
        if (!link.exchange.canDepart(complete) || link.transfers.values.any { it.purpose == "finish_ack" }) {
            if (complete && !link.timers.containsKey("finish_wait")) schedule(link, "finish_wait", 60_000) { recover(link, "reciprocal_progress_timeout") }
            return
        }
        cancel(link, "finish_wait")
        link.finishingGrace = true
        schedule(link, "departure", 2_000) {
            val peer = link.peer
            if (!link.exchange.canDepart(ledger!!.peer(peer.sessionID)!!.nextOutgoing == SessionLedger.ATTEMPTS) ||
                link.transfers.values.any { it.purpose == "finish_ack" }) {
                link.finishingGrace = false
                maybeCompletePeer(link)
                return@schedule
            }
            if (!durable { ledger!!.markComplete(peer.sessionID) }) return@schedule
            event(link, "peer_batch_complete", "sent_successes" to "${ledger!!.peer(peer.sessionID)!!.successfulOutgoing}",
                "sent_failures" to "${ledger!!.peer(peer.sessionID)!!.failedOutgoing}",
                "received_unique" to "${ledger!!.peer(peer.sessionID)!!.receivedAccepted}")
            if (!current(link)) return@schedule
            status("Peer finished. Other cluster links continue; finding the next compatible peer.")
            depart(link)
        }
    }

    private fun sendControl(link: ProbeLink, bytes: ByteArray, purpose: String) { if (current(link)) sendBytes(link, bytes, purpose) }
    private fun sendBytes(link: ProbeLink, bytes: ByteArray, purpose: String, serial: Long? = null) {
        if (!current(link)) return
        if (link.transfers.size >= 64) { recover(link, "pending_payload_limit"); return }
        val endpoint = link.endpoint
        val token = link.token
        val payload = Payload.fromBytes(bytes)
        link.transfers[payload.id] = ProbeTransfer(token, purpose, serial)
        client.sendPayload(endpoint, payload).addOnFailureListener { onMain {
            val transfer = link.transfers.remove(payload.id) ?: return@onMain
            if (!scope.accepts(transfer.token, endpoint)) return@onMain
            event(link, "payload_send_failed", "kind" to purpose)
            if (purpose == "data" && link.pendingSend?.serial == serial) retryAttempt(link, "payload_send_failed")
            else if (purpose == "hello" || purpose == "finish") recover(link, "control_send_failed")
        } }
    }

    private fun depart(link: ProbeLink, retryAt: Long? = null) {
        if (!current(link)) return
        registry.retire(link)
        link.cancelTimers(handler)
        link.transfers.clear()
        scheduler.release(link.endpoint, retryAt)
        try { client.disconnectFromEndpoint(link.endpoint) } catch (_: Exception) { }
        if (retryAt != null) restartWhenIdle = true
        chooseCandidates()
    }

    private fun recover(link: ProbeLink, reason: String) {
        if (!current(link)) return
        event(link, "connection_recovery", "reason" to reason)
        if (!current(link)) return
        if (ledger!!.peer(link.peer.sessionID)?.complete == true) {
            depart(link)
            return
        }
        var delay: Long? = null
        if (!durable { delay = ledger!!.nextRecovery(link.peer.sessionID) }) return
        if (delay == null) {
            if (!durable { ledger!!.abandon(link.peer.sessionID) }) return
            event(link, "peer_recovery_exhausted")
            if (!current(link)) return
            depart(link)
            if (!active) return
            status("A peer exhausted recovery. Other cluster links continue; progress is saved.")
        } else {
            val readyAt = SystemClock.elapsedRealtime() + delay!! + Random.nextLong(0, 501)
            cooldowns[link.peer.sessionID] = readyAt
            depart(link, readyAt)
            if (!active) return
            status("One peer interrupted. Healthy links continue; its retry waits for a safe radio cycle.")
        }
    }

    private fun nearbyFailure(operation: String, exception: Exception, link: ProbeLink? = null) {
        val code = (exception as? ApiException)?.statusCode
        val granted = listOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
            .filter { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }.toSet()
        val grantEvidence = NearbyPermissionPolicy.locationGrantEvidence(granted)
        event("nearby_operation_failed", "operation" to operation.lowercase(), "status_code" to (code?.toString() ?: "unknown"),
            "status_name" to (code?.let(ConnectionsStatusCodes::getStatusCodeString)?.take(160) ?: "unknown"),
            "exception_type" to exception.javaClass.simpleName.take(64), *grantEvidence.toList().toTypedArray())
        if (!active) return
        val compatibility = NearbyPermissionPolicy.permissionsForCompatibilityFailure(Build.VERSION.SDK_INT, operation, code, granted)
        if (compatibility.isNotEmpty()) { askPermissions(compatibility); return }
        if (link != null) recover(link, "nearby_operation_failed")
        else if (links.isNotEmpty()) {
            restartWhenIdle = true
            status("Nearby discovery or advertising failed. Existing links continue; recovery waits for them.")
        } else if (++radioFailures <= SessionLedger.MAX_RECOVERIES) {
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
        links.values.forEach { it.cancelTimers(handler); it.transfers.clear() }
        registry.clear()
        scheduler.clear()
        restartWhenIdle = false
        stopSdk()
    }

    private fun stopSdk() {
        try { client.stopDiscovery(); client.stopAdvertising(); client.stopAllEndpoints() } catch (_: Exception) { }
    }

    private fun pause(reason: String) {
        active = false
        scope.stop()
        cancelTimers()
        links.values.forEach { it.cancelTimers(handler); it.transfers.clear() }
        registry.clear()
        scheduler.clear()
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

    private fun evidence(link: ProbeLink?, name: String, vararg fields: Pair<String, String>): ProbeEvent =
        ProbeEvent(name, Instant.now().toString(), mapOf(*fields) +
            (link?.let { mapOf("peer_session_id" to it.peer.sessionID) } ?: emptyMap()))

    private fun direction(link: ProbeLink, outgoing: Boolean): String {
        val peer = if (link.peer.platform == ProbePlatform.IOS) "iphone" else "android"
        return if (outgoing) "android-to-$peer" else "$peer-to-android"
    }

    private fun event(name: String, vararg fields: Pair<String, String>) = recordEvent(null, name, fields)
    private fun event(link: ProbeLink, name: String, vararg fields: Pair<String, String>) = recordEvent(link, name, fields)
    private fun recordEvent(link: ProbeLink?, name: String, fields: Array<out Pair<String, String>>) {
        if (ledger == null) return
        durable { ledger!!.record(evidence(link, name, *fields)) }
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
            if (scope.acceptsRadio(token)) block()
        }
        timers[name] = callback
        handler.postDelayed(callback, delay)
    }
    private fun schedule(link: ProbeLink, name: String, delay: Long, block: () -> Unit) {
        if (!current(link)) return
        cancel(link, name)
        val callback = Runnable {
            link.timers.remove(name)
            if (current(link)) block()
        }
        link.timers[name] = callback
        handler.postDelayed(callback, delay)
    }
    private fun cancel(link: ProbeLink, name: String) { link.timers.remove(name)?.let(handler::removeCallbacks) }
    private fun cancel(name: String) { timers.remove(name)?.let(handler::removeCallbacks) }
    private fun cancelTimers() { timers.values.forEach(handler::removeCallbacks); timers.clear() }
    private fun onLinkMain(link: ProbeLink, block: () -> Unit) {
        if (!link.ingress.acquire()) {
            if (link.ingress.claimOverflowNotice()) onMain {
                if (current(link)) recover(link, "callback_queue_limit")
            }
            return
        }
        onMain {
            try { if (current(link)) block() }
            finally { link.ingress.release() }
        }
    }
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
            .put("transport", "Google Nearby Connections 19.5.1").put("strategy", "P2P_CLUSTER")
            .put("max_concurrent_peers", PeerScheduler.MAX_LINKS).put("max_candidates", PeerScheduler.MAX_CANDIDATES)
            .put("max_test_run_peers", SessionLedger.MAX_PEERS)
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
        private const val SERVICE_ID = "org.trailmesh.clusterprobe"
        private const val CHANNEL = "active_transport_test"
        private const val NOTIFICATION_ID = 24
        private const val CONNECTION_TIMEOUT = 20_000L
        private const val HELLO_TIMEOUT = 15_000L
        private const val ACK_TIMEOUT = 15_000L
        private const val FINISH_TIMEOUT = 5_000L
    }
}

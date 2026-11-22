package org.trailmesh.app.session

import android.content.Context
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import java.util.concurrent.ConcurrentHashMap

/**
 * Distinct product service; Nearby peers are unverified participants, never authenticated people.
 */
class NearbyReportRadio(
    context: Context,
    private val owner: () -> ReportSessionCoordinator,
    private val permissionsRequired: (List<String>) -> Unit = {},
    private val serviceId: String = ReportAdvertisement.SERVICE,
    private val ownsRadio: () -> Boolean = { true },
) : ReportSessionRadio {
    private val client = Nearby.getConnectionsClient(context.applicationContext)
    private val transfers =
        ConcurrentHashMap<ReportLinkToken, ConcurrentHashMap<Long, (Boolean) -> Unit>>()

    override fun start(epoch: Long, advertisement: String) {
        try {
            client
                .startAdvertising(
                    advertisement,
                    serviceId,
                    lifecycle(epoch),
                    AdvertisingOptions.Builder()
                        .setStrategy(Strategy.P2P_CLUSTER)
                        .setConnectionType(ConnectionType.NON_DISRUPTIVE)
                        .setLowPower(true)
                        .build(),
                )
                .addOnFailureListener { failure(epoch, it) }
            client
                .startDiscovery(
                    serviceId,
                    object : EndpointDiscoveryCallback() {
                        override fun onEndpointFound(
                            endpointId: String,
                            info: DiscoveredEndpointInfo,
                        ) {
                            owner().found(epoch, endpointId, info.endpointName)
                        }

                        override fun onEndpointLost(endpointId: String) {
                            owner().lost(epoch, endpointId)
                        }
                    },
                    DiscoveryOptions.Builder()
                        .setStrategy(Strategy.P2P_CLUSTER)
                        .setLowPower(true)
                        .build(),
                )
                .addOnFailureListener { failure(epoch, it) }
        } catch (_: SecurityException) {
            if (owner().epoch == epoch) owner().pause(ReportSessionState.permissionDenied)
        } catch (_: Exception) {
            unavailable(epoch)
        }
    }

    private fun failure(epoch: Long, error: Exception) {
        if (owner().epoch != epoch) return
        val extra =
            ReportNearbyPermissions.compatibility(
                android.os.Build.VERSION.SDK_INT,
                (error as? com.google.android.gms.common.api.ApiException)?.statusCode,
            )
        if (extra.isNotEmpty()) {
            permissionsRequired(extra)
            owner().pause(ReportSessionState.permissionDenied)
        } else unavailable(epoch)
    }

    private fun unavailable(epoch: Long) {
        owner().radioFailed(epoch)
    }

    override fun stop() {
        transfers.clear()
        if (!ownsRadio()) return
        try {
            client.stopAdvertising()
            client.stopDiscovery()
            client.stopAllEndpoints()
        } catch (_: Exception) {}
    }

    override fun request(token: ReportLinkToken, advertisement: String) {
        if (!owner().isLive(token)) return
        try {
            client
                .requestConnection(
                    advertisement,
                    token.endpoint,
                    lifecycle(token.epoch, token),
                    ConnectionOptions.Builder()
                        .setConnectionType(ConnectionType.NON_DISRUPTIVE)
                        .setLowPower(true)
                        .build(),
                )
                .addOnFailureListener {
                    if (owner().isLive(token)) {
                        val extra =
                            ReportNearbyPermissions.compatibility(
                                android.os.Build.VERSION.SDK_INT,
                                (it as? com.google.android.gms.common.api.ApiException)?.statusCode,
                            )
                        if (extra.isNotEmpty()) {
                            permissionsRequired(extra)
                            owner().pauseIfLive(token, ReportSessionState.permissionDenied)
                        } else owner().failed(token)
                    }
                }
        } catch (_: SecurityException) {
            owner().pauseIfLive(token, ReportSessionState.permissionDenied)
        } catch (_: Exception) {
            owner().failed(token)
        }
    }

    private fun lifecycle(epoch: Long, requested: ReportLinkToken? = null) =
        object : ConnectionLifecycleCallback() {
            private val captured = ConcurrentHashMap<String, ReportLinkToken>()

            override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
                if (owner().epoch != epoch || (requested != null && !owner().isLive(requested)))
                    return
                val token = owner().initiated(epoch, endpointId, info.endpointName)
                if (token == null || (requested != null && token != requested)) {
                    reject(endpointId)
                    return
                }
                // The same shared delegate never borrows a replacement endpoint generation.
                captured.putIfAbsent(endpointId, token)
                owner().acceptInitiation(token)
            }

            override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
                val token = captured[endpointId] ?: return
                if (!owner().isLive(token)) return
                if (resolution.status.statusCode == ConnectionsStatusCodes.STATUS_OK)
                    owner().connected(token)
                else owner().failed(token)
            }

            override fun onDisconnected(endpointId: String) {
                captured[endpointId]?.let { owner().disconnected(it) }
            }
        }

    override fun accept(token: ReportLinkToken) {
        if (!owner().isLive(token)) return
        try {
            client
                .acceptConnection(
                    token.endpoint,
                    object : PayloadCallback() {
                        override fun onPayloadReceived(endpointId: String, payload: Payload) {
                            if (endpointId != token.endpoint || !owner().isLive(token)) return
                            if (payload.type != Payload.Type.BYTES) {
                                owner().failed(token)
                                return
                            }
                            val bytes = payload.asBytes() ?: return
                            owner().receive(token, bytes)
                        }

                        override fun onPayloadTransferUpdate(
                            endpointId: String,
                            update: PayloadTransferUpdate,
                        ) {
                            if (endpointId != token.endpoint || !owner().isLive(token)) return
                            if (
                                update.status == PayloadTransferUpdate.Status.SUCCESS ||
                                    update.status == PayloadTransferUpdate.Status.FAILURE ||
                                    update.status == PayloadTransferUpdate.Status.CANCELED
                            )
                                transfers[token]
                                    ?.remove(update.payloadId)
                                    ?.invoke(update.status == PayloadTransferUpdate.Status.SUCCESS)
                        }
                    },
                )
                .addOnFailureListener {
                    if (owner().isLive(token)) {
                        val extra =
                            ReportNearbyPermissions.compatibility(
                                android.os.Build.VERSION.SDK_INT,
                                (it as? com.google.android.gms.common.api.ApiException)?.statusCode,
                            )
                        if (extra.isNotEmpty()) {
                            permissionsRequired(extra)
                            owner().pauseIfLive(token, ReportSessionState.permissionDenied)
                        } else owner().failed(token)
                    }
                }
        } catch (_: SecurityException) {
            owner().pauseIfLive(token, ReportSessionState.permissionDenied)
        } catch (_: Exception) {
            owner().failed(token)
        }
    }

    override fun reject(endpoint: String) {
        try {
            client.rejectConnection(endpoint)
        } catch (_: Exception) {}
    }

    override fun disconnect(token: ReportLinkToken) {
        transfers.remove(token)
        try {
            client.disconnectFromEndpoint(token.endpoint)
        } catch (_: Exception) {}
    }

    override fun send(token: ReportLinkToken, bytes: ByteArray, completion: (Boolean) -> Unit) {
        if (!owner().isLive(token)) return
        val pending = transfers.getOrPut(token) { ConcurrentHashMap() }
        if (pending.size >= ReportSessionLimits.OUTBOUND_PAYLOADS) {
            completion(false)
            return
        }
        val payload = Payload.fromBytes(bytes)
        pending[payload.id] = completion
        if (!owner().isLive(token)) {
            pending.remove(payload.id)
            return
        }
        try {
            client.sendPayload(token.endpoint, payload).addOnFailureListener {
                pending.remove(payload.id)?.invoke(false)
            }
        } catch (_: Exception) {
            pending.remove(payload.id)?.invoke(false)
        }
    }
}

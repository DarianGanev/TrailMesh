package org.trailmesh.app.exchange

import org.trailmesh.app.persistence.ReportRepository
import org.trailmesh.app.persistence.StoreOutcome

data class ReportDescriptor(val id: String, val total: Int, val hops: Int)

data class InventoryPage(
    val reports: List<ReportDescriptor>,
    val nextCursor: String?,
    val hasMore: Boolean,
)

class OutgoingReport(val descriptor: ReportDescriptor, wire: ByteArray) {
    private val bytes = wire.copyOf()
    val wire
        get() = bytes.copyOf()
}

interface ReportExchangeStore {
    suspend fun initialCursor(now: Long): String? = null

    suspend fun inventoryPage(afterID: String?, limit: Int, now: Long): InventoryPage

    suspend fun currentIDs(ids: List<String>, now: Long): Set<String>

    suspend fun load(id: String, now: Long): OutgoingReport?

    suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long): StoreOutcome
}

class RepositoryExchangeStore(private val repository: ReportRepository) : ReportExchangeStore {
    override suspend fun initialCursor(now: Long) = repository.exchangeInventoryCursor(now)

    override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long): InventoryPage {
        return repository.inventoryPage(afterID, limit, now)
    }

    override suspend fun currentIDs(ids: List<String>, now: Long) = repository.currentIDs(ids, now)

    override suspend fun load(id: String, now: Long) = repository.loadForExchange(id, now)

    override suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long) =
        repository.ingestTransferred(wire, remainingHops, clock)
}

/** One immutable local context per encounter; cancel the encounter when configuration changes. */
class SelectedRepositoryExchangeStore(
    private val repository: ReportRepository,
    private val context: org.trailmesh.app.relevance.RelevanceContext?,
    private val clock: (() -> Long)? = null,
    private val productOnly: Boolean = false,
) : ReportExchangeStore {
    override suspend fun initialCursor(now: Long) = repository.exchangeInventoryCursor(clock ?: {now})
    override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) = repository.selectedInventoryPage(afterID,limit,clock ?: {now},context,productOnly)
    override suspend fun currentIDs(ids: List<String>, now: Long) = repository.currentIDs(ids,clock ?: {now})
    override suspend fun load(id: String, now: Long) = repository.loadSelectedForExchange(id,clock ?: {now},context,productOnly)
    override suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long) = repository.ingestTransferred(wire,remainingHops,clock)
}

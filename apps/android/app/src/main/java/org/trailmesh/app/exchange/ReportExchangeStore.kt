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
        val page = repository.inventoryPage(afterID, limit, now)
        repository.recordExchangeInventoryProgress(page.nextCursor, page.hasMore, now)
        return page
    }

    override suspend fun currentIDs(ids: List<String>, now: Long) = repository.currentIDs(ids, now)

    override suspend fun load(id: String, now: Long) = repository.loadForExchange(id, now)

    override suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long) =
        repository.ingestTransferred(wire, remainingHops, clock)
}

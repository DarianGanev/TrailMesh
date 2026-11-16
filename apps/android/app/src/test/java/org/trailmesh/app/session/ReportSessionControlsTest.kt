package org.trailmesh.app.session

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.widget.CheckBox
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import org.robolectric.util.ReflectionHelpers
import org.trailmesh.app.MainActivity
import org.trailmesh.app.exchange.*
import org.trailmesh.app.persistence.ReportRepository
import org.trailmesh.app.persistence.StoreOutcome

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class ReportSessionControlsTest {
    private class Radio : ReportSessionRadio {
        var stopped = false
        val requests = mutableListOf<ReportLinkToken>()

        override fun start(epoch: Long, advertisement: String) {
            stopped = false
        }

        override fun stop() {
            stopped = true
        }

        override fun request(token: ReportLinkToken, advertisement: String) {
            requests.add(token)
        }

        override fun accept(token: ReportLinkToken) {}

        override fun reject(endpoint: String) {}

        override fun disconnect(token: ReportLinkToken) {}

        override fun send(
            token: ReportLinkToken,
            bytes: ByteArray,
            completion: (Boolean) -> Unit,
        ) {}
    }

    private object EmptyStore : ReportExchangeStore {
        override suspend fun inventoryPage(afterID: String?, limit: Int, now: Long) =
            InventoryPage(emptyList(), null, false)

        override suspend fun currentIDs(ids: List<String>, now: Long) = emptySet<String>()

        override suspend fun load(id: String, now: Long): OutgoingReport? = null

        override suspend fun ingest(wire: ByteArray, remainingHops: Int, clock: () -> Long) =
            StoreOutcome.Rejected("invalid")
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val pending = ConcurrentLinkedQueue<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            pending.add(block)
        }

        fun runQueued() {
            while (true) (pending.poll() ?: return).run()
        }
    }

    private fun coordinator(radio: Radio, scope: CoroutineScope) =
        ReportSessionCoordinator(
                radio,
                { EmptyStore },
                scope,
                System::currentTimeMillis,
                { 0L },
                { "1".repeat(32) },
            )
            .also {
                it.start(ReportSessionService.TEST_CONTEXT, true)
                it.found(it.epoch, "peer", "TMR1|" + "2".repeat(32))
            }

    @Test
    fun activeBindingReflectsConsentAndUncheckingStopsSharingImmediately() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.applicationInfo.flags =
            context.applicationInfo.flags or ApplicationInfo.FLAG_DEBUGGABLE
        val service = Robolectric.buildService(ReportSessionService::class.java).get()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val radio = Radio()
        val owner = coordinator(radio, scope)
        ReflectionHelpers.setField(service, "coordinator", owner)
        ReflectionHelpers.setField(service, "ready", true)
        val preferences =
            service.getSharedPreferences("public-report-session", Context.MODE_PRIVATE)
        preferences.edit().putBoolean("open_intent", true).commit()
        val controller = Robolectric.buildActivity(MainActivity::class.java).create()
        try {
            val activity = controller.get()
            val connection = ReflectionHelpers.getField<ServiceConnection>(activity, "connection")
            connection.onServiceConnected(
                ComponentName(activity, ReportSessionService::class.java),
                service.onBind(null),
            )
            val consent = ReflectionHelpers.getField<CheckBox>(activity, "consent")
            assertTrue(
                "A bound active session must reflect its existing consent",
                consent.isChecked,
            )
            val token = radio.requests.single()
            assertTrue(owner.isLive(token))

            consent.isChecked = false

            assertEquals(ReportSessionState.stopped, owner.state)
            assertFalse(owner.isLive(token))
            assertTrue(radio.stopped)
            assertFalse(preferences.getBoolean("open_intent", true))
            assertTrue(shadowOf(service).isStoppedBySelf)
        } finally {
            controller.destroy()
            scope.cancel()
        }
    }

    @Test
    fun uncheckingConsentBeforeBindingRequestsServiceShutdown() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.applicationInfo.flags =
            context.applicationInfo.flags or ApplicationInfo.FLAG_DEBUGGABLE
        val controller = Robolectric.buildActivity(MainActivity::class.java).create()
        try {
            val activity = controller.get()
            shadowOf(activity).clearStartedServices()
            val consent = ReflectionHelpers.getField<CheckBox>(activity, "consent")
            consent.isChecked = true

            consent.isChecked = false

            val stop = shadowOf(activity).nextStartedService
            assertEquals(
                ComponentName(activity, ReportSessionService::class.java),
                stop.component,
            )
            assertEquals(ReportSessionService.ACTION_STOP, stop.action)
        } finally {
            controller.destroy()
        }
    }

    @Test
    fun delayedBindingCannotRestoreWithdrawnConsent() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.applicationInfo.flags =
            context.applicationInfo.flags or ApplicationInfo.FLAG_DEBUGGABLE
        val service = Robolectric.buildService(ReportSessionService::class.java).get()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val radio = Radio()
        val owner = coordinator(radio, scope)
        ReflectionHelpers.setField(service, "coordinator", owner)
        ReflectionHelpers.setField(service, "ready", true)
        val controller = Robolectric.buildActivity(MainActivity::class.java).create()
        try {
            val activity = controller.get()
            val consent = ReflectionHelpers.getField<CheckBox>(activity, "consent")
            consent.isChecked = true
            consent.isChecked = false

            ReflectionHelpers.getField<ServiceConnection>(activity, "connection")
                .onServiceConnected(
                    ComponentName(activity, ReportSessionService::class.java),
                    service.onBind(null),
                )

            assertFalse("A delayed binding must not restore withdrawn consent", consent.isChecked)
            assertEquals(ReportSessionState.stopped, owner.state)
            assertFalse(owner.isLive(radio.requests.single()))
            assertTrue(radio.stopped)
        } finally {
            controller.destroy()
            scope.cancel()
        }
    }

    @Test
    fun clockRecoveryStopsBeforeWrite() = runBlocking {
        val service = Robolectric.buildService(ReportSessionService::class.java).get()
        val repository = ReportRepository.open(service, UUID.randomUUID().toString().take(8))
        val dispatcher = QueuedDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val radio = Radio()
        val owner = coordinator(radio, scope)
        ReflectionHelpers.setField(service, "scope", scope)
        ReflectionHelpers.setField(service, "coordinator", owner)
        ReflectionHelpers.setField(service, "repository", repository)
        ReflectionHelpers.setField(service, "promoted", true)
        val preferences =
            service.getSharedPreferences("public-report-session", Context.MODE_PRIVATE)
        preferences.edit().putBoolean("open_intent", true).commit()
        val future = System.currentTimeMillis() + 60_000
        repository.currentIDs(emptyList(), future)
        fun storedClock(): Long =
            repository.database.openHelper.readableDatabase
                .query("SELECT last_now_ms FROM repository_clock WHERE singleton=1")
                .use {
                    assertTrue(it.moveToFirst())
                    it.getLong(0)
                }
        try {
            val token = radio.requests.single()
            service.recoverClockAfterConfirmation()

            // The coroutine has not run: these effects must be synchronous, before quarantine.
            assertEquals(future, storedClock())
            assertEquals(ReportSessionState.stopped, owner.state)
            assertFalse(owner.isLive(token))
            assertTrue(radio.stopped)
            assertFalse(preferences.getBoolean("open_intent", true))
            assertFalse(ReflectionHelpers.getField<Boolean>(service, "promoted"))
            assertFalse(
                "Recovery must keep the bound service alive",
                shadowOf(service).isStoppedBySelf,
            )

            val recovery = scope.coroutineContext[Job]!!.children.single()
            val deadline = System.nanoTime() + 10_000_000_000L
            while (!recovery.isCompleted && System.nanoTime() < deadline) {
                dispatcher.runQueued()
                if (!recovery.isCompleted) Thread.sleep(1)
            }
            assertTrue(
                "The recovery transaction must finish after radio shutdown",
                recovery.isCompleted,
            )
            assertTrue(storedClock() < future)
            assertEquals(
                "Clock recovery confirmed. Existing reports are quarantined history.",
                service.message,
            )
            assertEquals(ReportSessionState.stopped, owner.state)
        } finally {
            scope.cancel()
            dispatcher.runQueued()
            repository.close()
        }
    }
}

package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test

class ServiceDiscoverySetupTest {
    private class Clock {
        private var time = 0L
        private val tasks = mutableListOf<Pair<Long, () -> Unit>>()
        fun schedule(delay: Long, task: () -> Unit) { tasks.add(time + delay to task) }
        fun advance(delay: Long) {
            val end = time + delay
            while (true) {
                val next = tasks.filter { it.first <= end }.minByOrNull { it.first } ?: break
                tasks.remove(next); time = next.first; next.second()
            }
            time = end
        }
    }
    private class Harness {
        val clock = Clock()
        val calls = mutableListOf<String>()
        val failures = mutableListOf<Pair<String, Int>>()
        val retries = mutableListOf<String>()
        var current = true
        var started = 0
        val behavior = mutableMapOf<String, ((Int?) -> Unit) -> Unit>()
        val names = listOf("activate-p2p", "stop-peer-discovery", "clear-service-requests", "add-service-request", "discover-services")
        fun setup() = ServiceDiscoverySetup(
            names.map { name -> ServiceDiscoverySetup.Step(name) { done ->
                calls.add(name)
                behavior[name]?.invoke(done) ?: done(null)
            } },
            { current }, clock::schedule,
            { started++ }, { stage, reason -> failures.add(stage to reason) },
            { stage, _, _ -> retries.add(stage) },
        )
    }

    @Test fun coldP2pIsActivatedBeforeCleanupAndServiceDiscovery() {
        val h = Harness(); var active = false
        h.behavior["activate-p2p"] = { done -> active = true; done(null) }
        h.behavior["clear-service-requests"] = { done ->
            assertTrue("Cleanup cannot activate a disabled P2P interface", active); done(null)
        }
        val setup = h.setup(); setup.start(); setup.start()
        assertEquals(listOf("activate-p2p", "stop-peer-discovery"), h.calls)
        h.clock.advance(200)
        assertEquals(h.names, h.calls)
        assertEquals(1, h.started)
        assertTrue(h.failures.isEmpty())
    }

    @Test fun busyDuringActivationWaitsBeforeAnyServiceRequest() {
        val h = Harness(); var attempts = 0
        h.behavior["activate-p2p"] = { done -> done(if (++attempts < 3) 2 else null) }
        h.setup().start()
        h.clock.advance(399)
        assertEquals(listOf("activate-p2p"), h.calls)
        h.clock.advance(1_001)
        assertEquals(1, h.started)
        assertEquals(1, h.calls.count { it == "clear-service-requests" })
        assertEquals(listOf("activate-p2p", "activate-p2p"), h.retries)
    }

    @Test fun busyServiceStartDoesNotClearAndRebuildRequestsEachTime() {
        val h = Harness(); var attempts = 0
        h.behavior["discover-services"] = { done -> done(if (++attempts < 3) 2 else null) }
        h.setup().start(); h.clock.advance(2_000)
        assertEquals(1, h.started)
        assertEquals(1, h.calls.count { it == "activate-p2p" })
        assertEquals(1, h.calls.count { it == "clear-service-requests" })
        assertEquals(1, h.calls.count { it == "add-service-request" })
        assertEquals(3, h.calls.count { it == "discover-services" })
    }

    @Test fun persistentBusyAndNonBusyFailuresAreBoundedAndIdentifyTheStage() {
        val h = Harness()
        h.behavior["activate-p2p"] = { it(2) }
        h.setup().start(); h.clock.advance(20_000)
        assertEquals(listOf("activate-p2p" to 2), h.failures)
        assertEquals(5, h.calls.size)
        val nonBusy = Harness()
        nonBusy.behavior["add-service-request"] = { it(1) }
        nonBusy.setup().start(); nonBusy.clock.advance(20_000)
        assertEquals(listOf("add-service-request" to 1), nonBusy.failures)
        assertFalse(nonBusy.calls.contains("discover-services"))
    }

    @Test fun missingCallbackHasDeadlineAndLateSuccessCannotStartTheScan() {
        val h = Harness(); var reply: ((Int?) -> Unit)? = null
        h.behavior["activate-p2p"] = { reply = it }
        h.setup().start(); h.clock.advance(10_000)
        assertEquals(listOf("activate-p2p-timeout" to 0), h.failures)
        reply!!(null)
        assertEquals(0, h.started)
        assertEquals(listOf("activate-p2p"), h.calls)
    }

    @Test fun cancellationIgnoresCallbacksAndQueuedRetries() {
        val h = Harness()
        h.behavior["activate-p2p"] = { it(2) }
        h.setup().start(); h.current = false; h.clock.advance(20_000)
        assertEquals(1, h.calls.size)
        assertTrue(h.failures.isEmpty())
        assertEquals(0, h.started)
    }

    @Test fun duplicateOrContradictoryCallbacksCannotRepeatAStage() {
        val h = Harness()
        h.behavior["activate-p2p"] = { done -> done(null); done(2); done(null) }
        h.behavior["discover-services"] = { done -> done(null); done(2); done(null) }
        h.setup().start(); h.clock.advance(20_000)
        assertEquals(h.names, h.calls)
        assertEquals(1, h.started)
        assertTrue(h.failures.isEmpty())
        assertTrue(h.retries.isEmpty())
    }
}

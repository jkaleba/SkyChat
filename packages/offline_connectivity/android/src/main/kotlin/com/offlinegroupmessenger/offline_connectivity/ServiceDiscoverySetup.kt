package com.offlinegroupmessenger.offline_connectivity

/** Activate on-demand P2P before cleanup, then serialize DNS-SD setup. */
internal class ServiceDiscoverySetup(
    private val steps: List<Step>,
    private val isCurrent: () -> Boolean,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val onStarted: () -> Unit,
    private val onFailure: (String, Int) -> Unit,
    private val onRetry: (String, Int, Int) -> Unit,
) {
    class Step(val name: String, val run: ((Int?) -> Unit) -> Unit)
    private var started = false
    private var finished = false
    private var revision = 0
    private var stepIndex = 0
    private fun active() = !finished && isCurrent()

    fun start() {
        if (started || !active()) return
        require(steps.isNotEmpty())
        started = true
        // Independent of Android callbacks, within the enclosing 12-second cycle.
        schedule(10_000) { if (active()) fail("${steps[stepIndex].name}-timeout", 0) }
        runStep(0)
    }

    private fun fail(stage: String, reason: Int) {
        if (!active()) return
        finished = true
        onFailure(stage, reason)
    }

    private fun runStep(retries: Int) {
        if (!active()) return
        val operation = steps[stepIndex]
        val token = ++revision
        fun complete(reason: Int?) {
            if (!active() || token != revision) return
            val completed = ++revision // Consume duplicate/contradictory callbacks.
            if (reason == null) {
                if (stepIndex == steps.lastIndex) {
                    finished = true
                    onStarted()
                } else {
                    stepIndex++
                    // Let the driver settle after stopping the bootstrap peer scan.
                    if (operation.name == "stop-peer-discovery") {
                        schedule(200) { if (active() && revision == completed) runStep(0) }
                    } else runStep(0)
                }
            } else if (reason == 2 && retries < 4) { // WifiP2pManager.BUSY
                onRetry(operation.name, reason, retries + 1)
                schedule(400L * (retries + 1)) {
                    if (active() && revision == completed) runStep(retries + 1)
                }
            } else fail(operation.name, reason)
        }
        try { operation.run(::complete) }
        catch (_: RuntimeException) { complete(0) }
    }
}

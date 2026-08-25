import Foundation
import Metal

/// Real engine behind `.gpuCompute` — PLAN.md §3's `Benchmarks/` "GPU
/// (Metal compute)" and §4 M7's second task. Dispatches two small compute
/// kernels (embedded as an inline Metal Shading Language source string,
/// compiled at run time via `MTLDevice.makeLibrary(source:options:)` rather
/// than a `.metal` file needing its own Xcode build-phase entry) that
/// exercise two different things a GPU compute workload can be bottlenecked
/// on:
/// - **Compute** — an arithmetic-bound kernel (`compute_alu`) that runs a
///   long, data-dependent chain of `fma`s per thread over a small buffer,
///   reported in GFLOPS.
/// - **Bandwidth** — a memory-bound kernel (`bandwidth_copy`) that reads
///   and writes large buffers with almost no arithmetic per element,
///   reported in GB/s.
///
/// Both are genuinely *compute* dispatches (`MTLComputeCommandEncoder`, no
/// render pipeline, no rasterization) — this deliberately stays inside the
/// "Metal compute" scope PLAN.md's architecture list names, rather than
/// also standing up a graphics/rendering benchmark. Reporting two numbers
/// instead of one still gives `BenchmarksPage`'s card the same
/// two-metrics-one-card shape `.diskReadWrite`/`.internetSpeed` already
/// have, without fabricating a second reading — both are real, independently
/// measured throughput figures.
///
/// Each phase runs in a loop of small dispatches ("batches") for a fixed
/// wall-clock budget (`targetDurationPerPhase`) rather than a fixed
/// iteration count, summing each batch's own (work done, elapsed time) —
/// the same reason `CPUBenchmarkRunner` is time-boxed rather than
/// work-boxed: a fixed amount of GPU work could take a few milliseconds on
/// a fast Mac and much longer on an integrated GPU, and only a time budget
/// gives every Mac an honest, boundedly-long benchmark run. The batch sizes
/// below are tuned heuristically (large enough that `waitUntilCompleted`'s
/// CPU–GPU round-trip overhead doesn't dominate the timing on a fast Mac,
/// small enough that even a slow integrated GPU still completes several
/// batches within the budget) rather than derived from any hardware query
/// — like `CPUBenchmarkRunner`'s "Score," these numbers are self-consistent
/// for comparing this same Mac's own runs over time, not calibrated against
/// a published GPU benchmark's methodology.
final class GPUBenchmarkRunner: BenchmarkRunner {
    let kind: BenchmarkKind = .gpuCompute
    private let tokenBox = BenchmarkTokenBox()

    private static let targetDurationPerPhase: TimeInterval = 1.5
    private static let aluThreadCount = 1_048_576
    private static let aluIterationsPerBatch: UInt32 = 16_384
    /// `float4` elements per buffer — 16 MiB elements × 16 bytes = 256 MB
    /// per buffer (512 MB for the src+dst pair), large enough that each
    /// dispatch moves enough data for `waitUntilCompleted`'s round-trip
    /// overhead to stay a small fraction of the batch's own timing even on
    /// a very fast Mac.
    private static let bandwidthElementCount = 16_777_216

    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent> {
        let token = BenchmarkCancellationToken()
        tokenBox.set(token)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRun(token: token, continuation: continuation)
            }
        }
    }

    /// Mirrors `DiskSpaceScanner.cancelActiveScan()`. Takes effect between
    /// batches — an in-flight `MTLCommandBuffer` is always let finish
    /// (Metal has no mid-dispatch cancel), so worst-case latency is one
    /// batch's own duration, the same "checked between chunks, not inside
    /// one" shape `CPUBenchmarkRunner`/`DiskSpaceScanner` both use.
    func cancelActiveRun() {
        tokenBox.current?.cancel()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void compute_alu(device float *data [[buffer(0)]],
                             constant uint &iterations [[buffer(1)]],
                             constant uint &count [[buffer(2)]],
                             uint id [[thread_position_in_grid]]) {
        if (id >= count) { return; }
        float v = data[id];
        for (uint i = 0; i < iterations; i++) {
            v = fma(v, 1.0000001f, 0.0000001f);
            v = fma(v, 0.9999999f, -0.0000001f);
        }
        data[id] = v;
    }

    kernel void bandwidth_copy(device const float4 *src [[buffer(0)]],
                                device float4 *dst [[buffer(1)]],
                                constant uint &count [[buffer(2)]],
                                uint id [[thread_position_in_grid]]) {
        if (id >= count) { return; }
        dst[id] = src[id] * 2.0f + 1.0f;
    }
    """

    private static func performRun(token: BenchmarkCancellationToken, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            continuation.yield(.failed("No Metal-capable GPU was found on this Mac."))
            continuation.finish()
            return
        }
        guard let queue = device.makeCommandQueue() else {
            continuation.yield(.failed("Couldn\u{2019}t create a Metal command queue."))
            continuation.finish()
            return
        }

        let aluPipeline: MTLComputePipelineState
        let bandwidthPipeline: MTLComputePipelineState
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let aluFunction = library.makeFunction(name: "compute_alu"),
                  let bandwidthFunction = library.makeFunction(name: "bandwidth_copy") else {
                continuation.yield(.failed("The Metal compute shader didn\u{2019}t expose the expected kernel functions."))
                continuation.finish()
                return
            }
            aluPipeline = try device.makeComputePipelineState(function: aluFunction)
            bandwidthPipeline = try device.makeComputePipelineState(function: bandwidthFunction)
        } catch {
            continuation.yield(.failed("Compiling the Metal compute shader failed: \(error.localizedDescription)"))
            continuation.finish()
            return
        }

        guard
            let dataBuffer = device.makeBuffer(length: aluThreadCount * MemoryLayout<Float>.size, options: .storageModeShared),
            let srcBuffer = device.makeBuffer(length: bandwidthElementCount * MemoryLayout<SIMD4<Float>>.size, options: .storageModeShared),
            let dstBuffer = device.makeBuffer(length: bandwidthElementCount * MemoryLayout<SIMD4<Float>>.size, options: .storageModeShared)
        else {
            continuation.yield(.failed("Couldn\u{2019}t allocate Metal buffers for the compute benchmark."))
            continuation.finish()
            return
        }
        fill(buffer: dataBuffer, floatCount: aluThreadCount, value: 0.5)
        fill(buffer: srcBuffer, floatCount: bandwidthElementCount * 4, value: 0.5)

        continuation.yield(.progress(BenchmarkProgress(fraction: 0, phase: "Measuring compute throughput\u{2026}")))
        guard let aluFlopsPerSecond = runTimedPhase(
            targetDuration: targetDurationPerPhase,
            progressRange: (0, 0.5),
            phase: "Measuring compute throughput\u{2026}",
            token: token,
            continuation: continuation,
            runBatch: { runALUBatch(queue: queue, pipeline: aluPipeline, buffer: dataBuffer) }
        ) else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: 0.5, phase: "Measuring memory bandwidth\u{2026}")))
        guard let bandwidthBytesPerSecond = runTimedPhase(
            targetDuration: targetDurationPerPhase,
            progressRange: (0.5, 1.0),
            phase: "Measuring memory bandwidth\u{2026}",
            token: token,
            continuation: continuation,
            runBatch: { runBandwidthBatch(queue: queue, pipeline: bandwidthPipeline, src: srcBuffer, dst: dstBuffer) }
        ) else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        let result = BenchmarkResult(
            id: UUID(),
            kind: .gpuCompute,
            generatedAt: Date(),
            metrics: [
                BenchmarkMetric(label: "Compute", value: aluFlopsPerSecond / 1_000_000_000, unit: "GFLOPS"),
                BenchmarkMetric(label: "Bandwidth", value: bandwidthBytesPerSecond / 1_000_000_000, unit: "GB/s"),
            ],
            detail: device.name
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    // MARK: - Timed phase loop

    /// Runs `runBatch` repeatedly, accumulating `(work, elapsed)` pairs,
    /// until accumulated elapsed time reaches `targetDuration` or `token`
    /// is cancelled — yielding a `.progress` tick (scaled into
    /// `progressRange`) after every batch, the same "known target duration
    /// ⇒ an honest determinate fraction" reasoning `CPUBenchmarkRunner`'s
    /// own coordinator loop uses.
    /// - Returns: The overall rate (`work`/`elapsed`, e.g. flops/sec or
    ///   bytes/sec), or `nil` if cancelled, or if a batch itself failed
    ///   (`runBatch` returning `nil` — a Metal command buffer error).
    private static func runTimedPhase(
        targetDuration: TimeInterval,
        progressRange: (Double, Double),
        phase: String,
        token: BenchmarkCancellationToken,
        continuation: AsyncStream<BenchmarkRunEvent>.Continuation,
        runBatch: () -> (work: Double, elapsed: TimeInterval)?
    ) -> Double? {
        var totalWork: Double = 0
        var totalElapsed: TimeInterval = 0
        while totalElapsed < targetDuration {
            guard !token.isCancelled else { return nil }
            guard let (work, elapsed) = runBatch() else { return nil }
            totalWork += work
            totalElapsed += elapsed
            let localFraction = min(totalElapsed / targetDuration, 1)
            let overall = progressRange.0 + (progressRange.1 - progressRange.0) * localFraction
            continuation.yield(.progress(BenchmarkProgress(fraction: overall, phase: phase)))
        }
        guard totalElapsed > 0 else { return nil }
        return totalWork / totalElapsed
    }

    // MARK: - Batches

    private static func runALUBatch(queue: MTLCommandQueue, pipeline: MTLComputePipelineState, buffer: MTLBuffer) -> (work: Double, elapsed: TimeInterval)? {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var iterations = aluIterationsPerBatch
        encoder.setBytes(&iterations, length: MemoryLayout<UInt32>.size, index: 1)
        var count = UInt32(aluThreadCount)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
        dispatch(pipeline: pipeline, encoder: encoder, threadCount: aluThreadCount)
        encoder.endEncoding()

        let start = Date()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let elapsed = Date().timeIntervalSince(start)
        guard commandBuffer.error == nil, elapsed > 0 else { return nil }

        // 2 `fma`s/iteration × 2 flops/`fma` (multiply + add) = 4 flops/iteration.
        let flops = Double(aluThreadCount) * Double(aluIterationsPerBatch) * 4
        return (flops, elapsed)
    }

    private static func runBandwidthBatch(queue: MTLCommandQueue, pipeline: MTLComputePipelineState, src: MTLBuffer, dst: MTLBuffer) -> (work: Double, elapsed: TimeInterval)? {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(src, offset: 0, index: 0)
        encoder.setBuffer(dst, offset: 0, index: 1)
        var count = UInt32(bandwidthElementCount)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
        dispatch(pipeline: pipeline, encoder: encoder, threadCount: bandwidthElementCount)
        encoder.endEncoding()

        let start = Date()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let elapsed = Date().timeIntervalSince(start)
        guard commandBuffer.error == nil, elapsed > 0 else { return nil }

        // One `float4` (16 bytes) read from `src` plus one written to `dst`
        // per element.
        let bytes = Double(bandwidthElementCount) * Double(MemoryLayout<SIMD4<Float>>.size) * 2
        return (bytes, elapsed)
    }

    private static func dispatch(pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder, threadCount: Int) {
        let width = max(min(pipeline.maxTotalThreadsPerThreadgroup, threadCount), 1)
        let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
        let groupCount = (threadCount + width - 1) / width
        encoder.dispatchThreadgroups(MTLSize(width: max(groupCount, 1), height: 1, depth: 1), threadsPerThreadgroup: threadsPerGroup)
    }

    /// Fills a shared-storage-mode buffer's first `floatCount` `Float`s
    /// with `value` — just needs to be finite, non-zero, and roughly `1`
    /// in magnitude so `compute_alu`'s repeated near-1.0 multiplies stay
    /// numerically bounded across an entire phase's worth of batches
    /// (`bandwidth_copy` doesn't care what `src` holds; filling it too
    /// keeps both buffers out of undefined/NaN territory uniformly).
    private static func fill(buffer: MTLBuffer, floatCount: Int, value: Float) {
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: floatCount)
        for i in 0..<floatCount { pointer[i] = value }
    }
}

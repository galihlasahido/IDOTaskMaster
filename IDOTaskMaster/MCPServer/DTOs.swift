import Foundation

/// Hand-picked `Codable` response shapes for every MCP tool, each built from
/// one of `Core/`/`Providers/`'s existing (non-`Codable`) model types.
///
/// Deliberately **not** a blanket `Codable` conformance bolted onto the
/// app's own model structs (`CPUSnapshot`, `ProcessReading`, ...): those
/// carry internal bookkeeping fields an AI reading system state doesn't
/// need, and a couple (`ProcessReading`, `InstalledApp`) carry PNG icon
/// bytes that must never reach a JSON tool response. Every DTO below is
/// built with an explicit `init(_:)` off the real model value, field by
/// field, so an icon field is simply never copied over rather than needing
/// to be filtered back out.

// MARK: - Core per-tick domains (get_summary)

struct CPUTopologyDTO: Encodable {
    let logicalCoreCount: Int?
    let physicalCoreCount: Int?
    let performanceCoreCount: Int?
    let efficiencyCoreCount: Int?
    let packageCount: Int?
    let brandString: String?

    init(_ topology: CPUTopology) {
        logicalCoreCount = topology.logicalCoreCount
        physicalCoreCount = topology.physicalCoreCount
        performanceCoreCount = topology.performanceCoreCount
        efficiencyCoreCount = topology.efficiencyCoreCount
        packageCount = topology.packageCount
        brandString = topology.brandString
    }
}

struct CoreUtilizationDTO: Encodable {
    let core: Int
    let totalPercent: Double?
    let userPercent: Double?
    let systemPercent: Double?
    let idlePercent: Double?

    init(_ core: CoreUtilization) {
        self.core = core.id
        totalPercent = core.totalUtilization
        userPercent = core.userUtilization
        systemPercent = core.systemUtilization
        idlePercent = core.idleUtilization
    }
}

/// - Note: every `*Percent` field is `0...100`; every `*BytesPerSecond`
///   field is bytes/second; every `total*Bytes*` field is cumulative since
///   boot.
struct CPUDTO: Encodable {
    let totalPercent: Double?
    let userPercent: Double?
    let systemPercent: Double?
    let idlePercent: Double?
    let uptimeSeconds: Double
    let topology: CPUTopologyDTO
    let perCore: [CoreUtilizationDTO]

    init(_ snapshot: CPUSnapshot) {
        totalPercent = snapshot.totalUtilization
        userPercent = snapshot.userUtilization
        systemPercent = snapshot.systemUtilization
        idlePercent = snapshot.idleUtilization
        uptimeSeconds = snapshot.uptime
        topology = CPUTopologyDTO(snapshot.topology)
        perCore = snapshot.perCoreUtilization.map(CoreUtilizationDTO.init)
    }
}

/// Every `*Bytes` field is a byte count.
struct MemoryDTO: Encodable {
    let totalBytes: UInt64?
    let usedBytes: UInt64?
    let freeBytes: UInt64
    let availableBytes: UInt64
    let cachedBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let purgeableBytes: UInt64
    let swapTotalBytes: UInt64?
    let swapUsedBytes: UInt64?
    let swapFreeBytes: UInt64?
    /// "normal" / "warning" / "critical", or `null` if unreadable.
    let pressureLevel: String?

    init(_ snapshot: MemorySnapshot) {
        totalBytes = snapshot.totalBytes
        usedBytes = snapshot.usedBytes
        freeBytes = snapshot.freeBytes
        availableBytes = snapshot.availableBytes
        cachedBytes = snapshot.cachedBytes
        activeBytes = snapshot.activeBytes
        inactiveBytes = snapshot.inactiveBytes
        wiredBytes = snapshot.wiredBytes
        compressedBytes = snapshot.compressedBytes
        purgeableBytes = snapshot.purgeableBytes
        swapTotalBytes = snapshot.swapTotalBytes
        swapUsedBytes = snapshot.swapUsedBytes
        swapFreeBytes = snapshot.swapFreeBytes
        pressureLevel = snapshot.pressureLevel.map(Self.pressureLevelText)
    }

    /// `MemoryPressureLevel` isn't `String`-backed, so this maps it
    /// explicitly rather than relying on `String(describing:)`'s reflection
    /// of the case name.
    private static func pressureLevelText(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

struct GPUDTO: Encodable {
    let deviceClassName: String
    let utilizationPercent: Double?
    let rendererUtilizationPercent: Double?
    let tilerUtilizationPercent: Double?
    let vramUsedBytes: UInt64?
    let vramAllocatedBytes: UInt64?
    let vramTotalBytes: UInt64?
    let temperatureCelsius: Double?

    init(_ snapshot: GPUSnapshot) {
        deviceClassName = snapshot.deviceClassName
        utilizationPercent = snapshot.utilizationPercent
        rendererUtilizationPercent = snapshot.rendererUtilizationPercent
        tilerUtilizationPercent = snapshot.tilerUtilizationPercent
        vramUsedBytes = snapshot.vramUsedBytes
        vramAllocatedBytes = snapshot.vramAllocatedBytes
        vramTotalBytes = snapshot.vramTotalBytes
        temperatureCelsius = snapshot.temperatureCelsius
    }
}

struct DiskUnitDTO: Encodable {
    let id: String
    let mediaName: String?
    let isInternal: Bool?
    let activePercent: Double?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let totalBytesRead: UInt64
    let totalBytesWritten: UInt64

    init(_ unit: DiskUnitSnapshot) {
        id = unit.id
        mediaName = unit.mediaName
        isInternal = unit.isInternal
        activePercent = unit.activePercent
        readBytesPerSecond = unit.readBytesPerSecond
        writeBytesPerSecond = unit.writeBytesPerSecond
        totalBytesRead = unit.totalBytesRead
        totalBytesWritten = unit.totalBytesWritten
    }
}

struct DiskVolumeDTO: Encodable {
    let path: String
    let volumeName: String?
    let isSystemVolume: Bool
    let totalBytes: UInt64?
    let availableBytes: UInt64?
    let usedBytes: UInt64?

    init(_ volume: DiskCapacity) {
        path = volume.id
        volumeName = volume.volumeName
        isSystemVolume = volume.isSystemVolume
        totalBytes = volume.totalBytes
        availableBytes = volume.availableBytes
        usedBytes = volume.usedBytes
    }
}

struct DiskDTO: Encodable {
    let activePercent: Double?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let totalBytesRead: UInt64
    let totalBytesWritten: UInt64
    let units: [DiskUnitDTO]
    let volumes: [DiskVolumeDTO]

    init(_ snapshot: DiskSnapshot) {
        activePercent = snapshot.activePercent
        readBytesPerSecond = snapshot.readBytesPerSecond
        writeBytesPerSecond = snapshot.writeBytesPerSecond
        totalBytesRead = snapshot.totalBytesRead
        totalBytesWritten = snapshot.totalBytesWritten
        units = snapshot.units.map(DiskUnitDTO.init)
        volumes = snapshot.volumes.map(DiskVolumeDTO.init)
    }
}

struct NetworkInterfaceDTO: Encodable {
    let id: String
    let isLoopback: Bool
    let isUp: Bool
    let sendBytesPerSecond: Double?
    let receiveBytesPerSecond: Double?
    let totalBytesSent: UInt64
    let totalBytesReceived: UInt64

    init(_ interface: NetworkInterfaceSnapshot) {
        id = interface.id
        isLoopback = interface.isLoopback
        isUp = interface.isUp
        sendBytesPerSecond = interface.sendBytesPerSecond
        receiveBytesPerSecond = interface.receiveBytesPerSecond
        totalBytesSent = interface.totalBytesSent
        totalBytesReceived = interface.totalBytesReceived
    }
}

/// `sendBytesPerSecond`/`receiveBytesPerSecond`/`totalBytes*` exclude
/// loopback traffic — see `NetworkSnapshot`'s own doc comment.
struct NetworkDTO: Encodable {
    let sendBytesPerSecond: Double?
    let receiveBytesPerSecond: Double?
    let totalBytesSent: UInt64
    let totalBytesReceived: UInt64
    let interfaces: [NetworkInterfaceDTO]

    init(_ snapshot: NetworkSnapshot) {
        sendBytesPerSecond = snapshot.sendBytesPerSecond
        receiveBytesPerSecond = snapshot.receiveBytesPerSecond
        totalBytesSent = snapshot.totalBytesSent
        totalBytesReceived = snapshot.totalBytesReceived
        interfaces = snapshot.interfaces.map(NetworkInterfaceDTO.init)
    }
}

struct EnergyBatteryDTO: Encodable {
    let percent: Double?
    let isCharging: Bool?
    let isCharged: Bool?
    let timeToEmptyMinutes: Int?
    let timeToFullChargeMinutes: Int?
    let cycleCount: Int?
    let designCapacityMAh: Int?
    let fullChargeCapacityMAh: Int?
    let condition: String?

    init(_ battery: EnergyBatterySnapshot) {
        percent = battery.percent
        isCharging = battery.isCharging
        isCharged = battery.isCharged
        timeToEmptyMinutes = battery.timeToEmptyMinutes
        timeToFullChargeMinutes = battery.timeToFullChargeMinutes
        cycleCount = battery.cycleCount
        designCapacityMAh = battery.designCapacityMAh
        fullChargeCapacityMAh = battery.fullChargeCapacityMAh
        condition = battery.condition
    }
}

struct EnergyDTO: Encodable {
    let systemPowerWatts: Double?
    let adapterPowerWatts: Double?
    let batteryPowerWatts: Double?
    /// "acPower" / "batteryPower" / "unknown".
    let powerSource: String
    let isLowPowerModeEnabled: Bool
    let battery: EnergyBatteryDTO?

    init(_ snapshot: EnergySnapshot) {
        systemPowerWatts = snapshot.systemPowerWatts
        adapterPowerWatts = snapshot.adapterPowerWatts
        batteryPowerWatts = snapshot.batteryPowerWatts
        powerSource = snapshot.powerSource.rawValue
        isLowPowerModeEnabled = snapshot.isLowPowerModeEnabled
        battery = snapshot.battery.map(EnergyBatteryDTO.init)
    }
}

struct ThermalSensorDTO: Encodable {
    let key: String
    let celsius: Double

    init(_ sensor: ThermalSensorReading) {
        key = sensor.key
        celsius = sensor.celsius
    }
}

struct ThermalDTO: Encodable {
    let hotspotCelsius: Double?
    /// "nominal" / "fair" / "serious" / "critical" / "unknown".
    let thermalPressure: String
    let dieSensors: [ThermalSensorDTO]

    init(_ snapshot: ThermalSnapshot) {
        hotspotCelsius = snapshot.hotspotCelsius
        thermalPressure = snapshot.thermalPressure.rawValue
        dieSensors = snapshot.dieSensors.map(ThermalSensorDTO.init)
    }
}

/// See `NPUSnapshot`'s own doc comment: `energyDeltaRaw` is an
/// intentionally unconverted raw counter (no documented watts/percent
/// conversion exists), not a fabricated utilization figure.
struct NPUDTO: Encodable {
    let devicePresent: Bool
    let deviceName: String?
    let compatibleString: String?
    let energyDeltaRaw: UInt64?
    let isActive: Bool?
    let unavailableReason: String?

    init(_ snapshot: NPUSnapshot) {
        devicePresent = snapshot.devicePresent
        deviceName = snapshot.deviceName
        compatibleString = snapshot.compatibleString
        energyDeltaRaw = snapshot.energyDeltaRaw
        isActive = snapshot.isActive
        unavailableReason = snapshot.unavailableReason
    }
}

/// `get_summary`'s response. Any domain whose provider threw this call is
/// `null` here with its reason recorded under `errors[domainKey]` — the
/// same per-domain "honest degradation" the GUI app's own `Sampler` applies,
/// rather than one failed domain blanking the whole response.
struct SummaryResponse: Encodable {
    var cpu: CPUDTO?
    var memory: MemoryDTO?
    var gpu: GPUDTO?
    var disk: DiskDTO?
    var network: NetworkDTO?
    var energy: EnergyDTO?
    var thermal: ThermalDTO?
    var npu: NPUDTO?
    /// Live process count (`proc_listallpids`), or `null` if that call
    /// failed.
    var processCount: Int?
    /// Domain key -> failure reason, only for domains that threw this call.
    var errors: [String: String]
}

// MARK: - Processes

/// One process's identity/lifetime/CPU/memory/disk reading — the JSON shape
/// for both `list_processes`' rows and `get_process_detail`'s `process`
/// field. Never carries `ProcessReading.iconPNGData`.
struct ProcessDTO: Encodable {
    let pid: Int32
    let parentPID: Int32?
    let name: String?
    let executablePath: String?
    let isApplication: Bool
    let userID: UInt32
    let userName: String?
    /// "idle" / "running" / "sleeping" / "stopped" / "zombie", or
    /// "other(<raw BSD status>)" for an unrecognized kernel status.
    let status: String
    let startedAt: Date
    let niceValue: Int
    let threadCount: Int?
    let pageFaultCount: Int?
    /// Busy percentage since this pid was last sampled — not divided by
    /// core count, so a process fully busy across two cores reads ~200%.
    let cpuPercent: Double?
    let cpuTimeSeconds: Double?
    let memoryFootprintBytes: UInt64?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    let totalDiskBytesRead: UInt64?
    let totalDiskBytesWritten: UInt64?

    init(_ reading: ProcessReading) {
        pid = reading.pid
        parentPID = reading.parentPID
        name = reading.name
        executablePath = reading.executablePath
        isApplication = reading.isApplication
        userID = reading.userID
        userName = reading.userName
        status = Self.statusText(reading.status)
        startedAt = reading.startedAt
        niceValue = reading.niceValue
        threadCount = reading.threadCount
        pageFaultCount = reading.pageFaultCount
        cpuPercent = reading.cpuPercent
        cpuTimeSeconds = reading.cpuTimeSeconds
        memoryFootprintBytes = reading.memoryFootprintBytes
        diskReadBytesPerSecond = reading.diskReadBytesPerSecond
        diskWriteBytesPerSecond = reading.diskWriteBytesPerSecond
        totalDiskBytesRead = reading.totalDiskBytesRead
        totalDiskBytesWritten = reading.totalDiskBytesWritten
    }

    private static func statusText(_ status: ProcessStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .sleeping: return "sleeping"
        case .stopped: return "stopped"
        case .zombie: return "zombie"
        case .other(let rawValue): return "other(\(rawValue))"
        }
    }
}

struct ListProcessesResponse: Encodable {
    let totalMatched: Int
    let returned: Int
    let processes: [ProcessDTO]
}

struct TopProcessDTO: Encodable {
    let pid: Int32
    let name: String?
    let cpuPercent: Double?
    /// Always `null` — no public macOS API exposes per-process GPU
    /// utilization; see `TopProcessReading.gpuPercent`'s own doc comment.
    let gpuPercent: Double?
    let memoryBytes: UInt64?

    init(_ reading: TopProcessReading) {
        pid = reading.pid
        name = reading.name
        cpuPercent = reading.cpuPercent
        gpuPercent = reading.gpuPercent
        memoryBytes = reading.memoryBytes
    }
}

struct SigningInfoDTO: Encodable {
    let status: String
    let statusLabel: String
    let isAdHoc: Bool?
    let isNotarized: Bool?
    let teamIdentifier: String?
    let signingIdentifier: String?
    let unavailableReason: String?

    init(_ info: SigningInfo) {
        switch info.status {
        case .signed: status = "signed"
        case .unsigned: status = "unsigned"
        case .invalid: status = "invalid"
        case .unavailable: status = "unavailable"
        }
        statusLabel = info.statusLabel
        isAdHoc = info.isAdHoc
        isNotarized = info.isNotarized
        teamIdentifier = info.teamIdentifier
        signingIdentifier = info.signingIdentifier
        unavailableReason = info.unavailableReason
    }
}

struct OpenFileDTO: Encodable {
    let descriptor: Int32
    let kind: String
    let name: String?

    init(_ entry: OpenFileEntry) {
        descriptor = entry.descriptor
        kind = entry.kind
        name = entry.name
    }
}

struct OpenFilesDTO: Encodable {
    let entries: [OpenFileDTO]
    let generatedAt: Date

    init(_ catalog: OpenFilesCatalog) {
        entries = catalog.entries.map(OpenFileDTO.init)
        generatedAt = catalog.generatedAt
    }
}

struct ProcessDetailResponse: Encodable {
    var process: ProcessDTO?
    /// Set when `pid` wasn't found in this tick's process list (e.g. it
    /// already exited).
    var processError: String?
    var signing: SigningInfoDTO?
    var openFiles: OpenFilesDTO?
    /// Set when the open-files read itself failed for this pid (see
    /// `OpenFilesProviderError`).
    var openFilesError: String?
}

// MARK: - System Info

struct SystemInfoEntryDTO: Encodable {
    let label: String
    let value: String

    init(_ entry: SystemInfoEntry) {
        label = entry.label
        value = entry.value
    }
}

struct SystemInfoGroupDTO: Encodable {
    let title: String
    let fields: [SystemInfoEntryDTO]

    init(_ group: SystemInfoFieldGroup) {
        title = group.title
        fields = group.fields.map(SystemInfoEntryDTO.init)
    }
}

struct SystemInfoItemDTO: Encodable {
    let name: String
    let groups: [SystemInfoGroupDTO]

    init(_ item: SystemInfoItem) {
        name = item.name
        groups = item.groups.map(SystemInfoGroupDTO.init)
    }
}

struct SystemInfoCategoryDTO: Encodable {
    let id: String
    let title: String
    let items: [SystemInfoItemDTO]

    init(_ category: SystemInfoCategory) {
        id = category.id
        title = category.title
        items = category.items.map(SystemInfoItemDTO.init)
    }
}

struct SystemInfoResponse: Encodable {
    let generatedAt: Date
    let categories: [SystemInfoCategoryDTO]
}

// MARK: - Startup items

struct StartupItemDTO: Encodable {
    let displayName: String
    /// "userAgent" / "globalAgent" / "globalDaemon" / "systemAgent" /
    /// "systemDaemon".
    let domain: String
    let plistPath: String
    let programPath: String?
    let runAtLoad: Bool?
    let keepAlive: Bool?
    let isEnabled: Bool
    /// `null` when this item's running state couldn't be determined (an
    /// unprivileged process only reliably sees its own per-user domain's
    /// jobs) — see `StartupItem.isRunning`'s own doc comment.
    let isRunning: Bool?
    let runningPID: Int32?
    let fileSizeBytes: UInt64?
    let modifiedAt: Date?

    init(_ item: StartupItem) {
        displayName = item.displayName
        domain = item.domain.rawValue
        plistPath = item.plistPath
        programPath = item.programPath
        runAtLoad = item.runAtLoad
        keepAlive = item.keepAlive
        isEnabled = item.isEnabled
        isRunning = item.isRunning
        runningPID = item.runningPID
        fileSizeBytes = item.fileSizeBytes
        modifiedAt = item.modifiedAt
    }
}

struct ListStartupItemsResponse: Encodable {
    let generatedAt: Date
    let totalMatched: Int
    let items: [StartupItemDTO]
}

// MARK: - Services

struct ServiceItemDTO: Encodable {
    let label: String
    /// "system" / "userAgent".
    let runtimeDomain: String
    let isRunning: Bool
    let pid: Int32?
    let lastExitStatus: Int32?
    let plistPath: String?
    let programPath: String?
    let isAppleService: Bool
    let group: String

    init(_ item: ServiceItem) {
        label = item.label
        runtimeDomain = item.runtimeDomain.rawValue
        isRunning = item.isRunning
        pid = item.pid
        lastExitStatus = item.lastExitStatus
        plistPath = item.plistPath
        programPath = item.programPath
        isAppleService = item.isAppleService
        group = item.group
    }
}

struct ListServicesResponse: Encodable {
    let generatedAt: Date
    let totalMatched: Int
    let items: [ServiceItemDTO]
}

// MARK: - Connections

struct ConnectionSocketDTO: Encodable {
    let pid: Int32
    let processName: String?
    let descriptor: Int32
    /// "TCP" / "UDP" / "Unix".
    let transport: String
    let ipVersion: Int?
    /// Present only for TCP sockets — the human-readable state name
    /// ("Listen", "Established", ...).
    let tcpState: String?
    let localAddress: String?
    let localPort: UInt16?
    let remoteAddress: String?
    let remotePort: UInt16?
    let unixPath: String?
    /// "loopback" / "lan" / "internet", or `null` if unclassifiable.
    let exposure: String?
    let serviceName: String?
    let isListening: Bool
    let isConnected: Bool
    let observedAt: Date

    init(_ socket: ConnectionSocket) {
        pid = socket.pid
        processName = socket.processName
        descriptor = socket.descriptor
        transport = socket.transport.rawValue
        ipVersion = socket.ipVersion?.rawValue
        tcpState = socket.tcpState?.displayName
        localAddress = socket.localAddress
        localPort = socket.localPort
        remoteAddress = socket.remoteAddress
        remotePort = socket.remotePort
        unixPath = socket.unixPath
        exposure = socket.exposure?.rawValue
        serviceName = socket.serviceName
        isListening = socket.isListening
        isConnected = socket.isConnected
        observedAt = socket.observedAt
    }
}

struct ListConnectionsResponse: Encodable {
    let generatedAt: Date
    /// `true` when the native per-process socket scan was unavailable
    /// system-wide and this catalog came from the coarser `lsof` fallback
    /// instead — see `ConnectionsCatalog.usedFallback`'s own doc comment.
    let usedFallback: Bool
    let scannedProcessCount: Int
    let totalMatched: Int
    let sockets: [ConnectionSocketDTO]
}

// MARK: - Installed apps

struct InstalledAppDTO: Encodable {
    let name: String
    let bundlePath: String
    let bundleIdentifier: String?
    let versionString: String?
    let buildString: String?
    let categoryLabel: String?
    let publisher: String?
    let sizeBytes: UInt64?
    let modifiedAt: Date?
    let isAppleSystemApp: Bool

    init(_ app: InstalledApp) {
        name = app.name
        bundlePath = app.bundlePath
        bundleIdentifier = app.bundleIdentifier
        versionString = app.versionString
        buildString = app.buildString
        categoryLabel = app.categoryLabel
        publisher = app.publisher
        sizeBytes = app.sizeBytes
        modifiedAt = app.modifiedAt
        isAppleSystemApp = app.isAppleSystemApp
    }
}

struct ListInstalledAppsResponse: Encodable {
    let generatedAt: Date
    let totalMatched: Int
    let apps: [InstalledAppDTO]
}

// MARK: - History

struct HistorySeriesIDDTO: Encodable {
    let domain: String
    let key: String

    init(_ id: HistoryStore.SeriesID) {
        domain = id.domain.rawValue
        key = id.key
    }
}

struct ListHistorySeriesResponse: Encodable {
    let series: [HistorySeriesIDDTO]
}

struct HistorySeriesPointDTO: Encodable {
    let timestamp: Date
    let average: Double
    let minimum: Double
    let maximum: Double
    let sampleCount: Int

    init(_ point: HistoryStore.SeriesPoint) {
        timestamp = point.timestamp
        average = point.average
        minimum = point.minimum
        maximum = point.maximum
        sampleCount = point.sampleCount
    }
}

struct QueryHistoryResponse: Encodable {
    let domain: String
    let key: String
    let range: String
    let points: [HistorySeriesPointDTO]
}

// MARK: - Alerts

struct AlertRuleDTO: Encodable {
    let id: String
    let name: String
    /// One of "cpuAbove" / "memoryPressure" / "lowDisk" / "lowBattery" /
    /// "newPublicPort".
    let kind: String
    /// Human-readable condition, e.g. "CPU above 90% for 5 min".
    let condition: String
    let isEnabled: Bool
    let cooldownMinutes: Double

    init(_ rule: AlertRule) {
        id = rule.id.uuidString
        name = rule.name
        kind = rule.kind.tag.rawValue
        condition = rule.kind.conditionSummary
        isEnabled = rule.isEnabled
        cooldownMinutes = rule.cooldownMinutes
    }
}

struct ListAlertRulesResponse: Encodable {
    let rules: [AlertRuleDTO]
    /// Explains why no fired-alert history is included — see
    /// `AlertsEngine.firedAlerts`'s own doc comment: it's in-memory only
    /// inside the running GUI app process and isn't reachable from here.
    let note: String
}

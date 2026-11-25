import Darwin
import Foundation
import IOKit
import PulseCore

extension MacSampler {
    /// Cumulative ticks of every logical core.
    func coreTicks(_ host: host_t) -> [HostTicks]? {
        var processors: natural_t = 0
        var info: processor_info_array_t?
        var words: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &words) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(words) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard processors > 0, Int(words) >= Int(processors) * states else { return nil }
        return (0..<Int(processors)).map { core in
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[core * states + Int(state)]) }
            return HostTicks(user: ticks(Int32(CPU_STATE_USER)), system: ticks(Int32(CPU_STATE_SYSTEM)),
                             idle: ticks(Int32(CPU_STATE_IDLE)), nice: ticks(Int32(CPU_STATE_NICE)))
        }
    }

    /// Cumulative byte counters of every block storage driver, internal and external.
    func diskCounters() -> [DiskReading]? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var rows: [DiskReading] = []
        while true {
            let driver = IOIteratorNext(iterator)
            guard driver != 0 else { break }
            defer { IOObjectRelease(driver) }
            var entry: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &entry) == KERN_SUCCESS else { continue }
            let statistics = property(driver, "Statistics") as? [String: Any]
            // The whole-disk media object below the driver carries the BSD name, such as disk0.
            var media: io_registry_entry_t = 0
            var name: String?
            if IORegistryEntryGetChildEntry(driver, "IOService", &media) == KERN_SUCCESS {
                name = property(media, "BSD Name") as? String
                IOObjectRelease(media)
            }
            rows.append(DiskReading(id: DiskID(entry: entry, name: name ?? "Storage \(entry)"),
                                    read: (statistics?["Bytes (Read)"] as? NSNumber)?.uint64Value,
                                    written: (statistics?["Bytes (Write)"] as? NSNumber)?.uint64Value))
        }
        return rows.sorted { $0.id.name.localizedStandardCompare($1.id.name) == .orderedAscending }
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

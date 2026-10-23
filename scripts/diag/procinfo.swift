import Foundation
let pid = pid_t(CommandLine.arguments[1])!
var info = proc_taskinfo()
let r = withUnsafeMutableBytes(of: &info) { ptr in
    proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr.baseAddress, Int32(MemoryLayout<proc_taskinfo>.size))
}
guard r > 0 else { print("no info"); exit(1) }
print(String(format: "RSS: %.1f MB", Double(info.pti_resident_size) / 1048576))
print("线程数:", info.pti_threadnum)
print(String(format: "CPU 累计: %.1f 秒", Double(info.pti_total_user + info.pti_total_system) / 1_000_000))

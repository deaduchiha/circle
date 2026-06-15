import Darwin
import Foundation

enum ProcessNameMatcher {
  static func processName(for pid: pid_t = getpid()) -> String? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard result == size else { return nil }

    return withUnsafeBytes(of: info.pbi_name) { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      return String(cString: bytes.baseAddress!)
    }
  }
}

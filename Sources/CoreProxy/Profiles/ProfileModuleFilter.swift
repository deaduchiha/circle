import Foundation

public enum ProfileModuleFilter {
  public static func apply(_ profile: Profile, modules: ProfileModuleSettings) -> Profile {
    var filtered = profile

    if !modules.proxies {
      filtered.proxies = []
    }

    if !modules.proxyGroups {
      filtered.proxyGroups = []
    }

    if !modules.rules {
      filtered.rules = [Rule(type: .final, policy: "DIRECT")]
    }

    if !modules.dns {
      filtered.dnsConfig = DNSConfig()
    }

    if !modules.mitm {
      filtered.mitm = MITMConfig()
    }

    if !modules.hosts {
      filtered.hosts = [:]
    }

    if !modules.scripts {
      filtered.scripts = []
    }

    return filtered
  }
}

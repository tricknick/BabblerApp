import Foundation
import Compression

/// Theme word packs: inflected Russian forms of IT, business, gaming, slang and
/// profanity vocabulary. Each pack is `pack-<id>.txt.gz` in the bundle, written
/// by `scripts/build_theme_packs.py`. A form in an enabled pack counts as an
/// exact Russian dictionary word for auto-switching.
struct ThemePacks {
  static let allIds = ["it", "business", "gaming", "slang", "mat"]

  private let words: Set<String>

  private init(words: Set<String>) {
    self.words = words
  }

  /// Loads the packs in `ids`. Missing or unreadable packs contribute nothing.
  static func load(ids: Set<String>, resourceDir: URL) -> ThemePacks {
    var words = Set<String>()
    for id in allIds where ids.contains(id) {
      let url = resourceDir.appendingPathComponent("pack-\(id).txt.gz")
      guard let data = try? Data(contentsOf: url), let text = gunzip(data) else { continue }
      text.enumerateLines { line, _ in
        let word = line.trimmingCharacters(in: .whitespaces).lowercased()
        if !word.isEmpty { words.insert(word) }
      }
    }
    return ThemePacks(words: words)
  }

  func contains(_ ruWord: String) -> Bool {
    words.contains(ruWord.lowercased())
  }

  /// The packs the user has enabled. Every pack is enabled until a selection is stored.
  static func enabledIds(defaults: UserDefaults = .standard) -> Set<String> {
    guard let stored = defaults.stringArray(forKey: enabledThemePacksKey) else {
      return Set(allIds)
    }
    return Set(stored).intersection(allIds)
  }

  static func saveEnabledIds(_ ids: Set<String>, defaults: UserDefaults = .standard) {
    defaults.set(allIds.filter { ids.contains($0) }, forKey: enabledThemePacksKey)
  }

  /// Minimal gzip reader: skips the header, then inflates the raw deflate payload
  /// with libcompression. Same approach as `LayoutDictionary`, which keeps its
  /// copy private.
  private static func gunzip(_ data: Data) -> String? {
    guard data.count > 18,
          data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else { return nil }

    let flags = data[3]
    var offset = 10

    if flags & 0x04 != 0 {  // FEXTRA
      guard offset + 2 <= data.count else { return nil }
      let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
      offset += 2 + extraLength
    }
    if flags & 0x08 != 0 {  // FNAME
      while offset < data.count, data[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x10 != 0 {  // FCOMMENT
      while offset < data.count, data[offset] != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 {  // FHCRC
      offset += 2
    }
    guard offset < data.count - 8 else { return nil }

    let sizeOffset = data.count - 4
    let uncompressedSize = Int(data[sizeOffset])
      | (Int(data[sizeOffset + 1]) << 8)
      | (Int(data[sizeOffset + 2]) << 16)
      | (Int(data[sizeOffset + 3]) << 24)
    let capacity = max(uncompressedSize, (data.count - offset) * 8)

    let payload = data.subdata(in: offset..<(data.count - 8))
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { buffer.deallocate() }

    let written = payload.withUnsafeBytes { raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return compression_decode_buffer(
        buffer, capacity, base, payload.count, nil, COMPRESSION_ZLIB
      )
    }
    guard written > 0 else { return nil }

    return String(bytes: UnsafeBufferPointer(start: buffer, count: written), encoding: .utf8)
  }
}

/// The packs the engine checks. Lives here rather than in AutoSwitchEngine so that
/// engine builds without this file (the dictionary test harness) still compile.
extension AutoSwitchEngine {
  static var themePacks: ThemePacks? {
    get { ThemePackStore.packs }
    set {
      ThemePackStore.packs = newValue
      let contains: ((String) -> Bool)? = newValue.map { packs in { packs.contains($0) } }
      themePackContains = contains
    }
  }
}

private enum ThemePackStore {
  static var packs: ThemePacks?
}

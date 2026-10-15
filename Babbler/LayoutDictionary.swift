import Foundation
import Compression

/// Which of the two supported layouts a piece of text belongs to.
enum Layout {
  case english
  case russian

  var other: Layout {
    self == .english ? .russian : .english
  }

  /// Letters that can be typed in this layout, used to reconstruct a word from
  /// which one keystroke was dropped.
  var alphabet: [Character] {
    self == .english
      ? Array("abcdefghijklmnopqrstuvwxyz")
      : Array("абвгдежзийклмнопрстуфхцчшщъыьэюя")
  }
}

/// Word lists used to decide whether a typed string is a real word in a layout.
///
/// English ships gzipped and is decompressed into a `Set<String>` on first use.
/// Russian is every inflected form (~3 M), far too many for a `Set<String>`, so
/// it ships as a `HashedWordSet` of 48-bit hashes. Loading happens on a
/// background queue so parsing never blocks the event handler; until it finishes
/// every lookup reports `false`, which makes the auto-switch engine decline to
/// act rather than guess.
final class LayoutDictionary {
  static let shared = LayoutDictionary()

  private var english: Set<String> = []
  private var russian = HashedWordSet()
  /// Subset of `russian` the typo probe may match: see `hasWordOneInsertionAway`.
  private var russianTypo = HashedWordSet()
  private var russianCustom: Set<String> = []
  /// Top 5000 words per language, for `hasCommonWordOneTypoAway`.
  private var commonEnglish: Set<String> = []
  private var commonRussian: Set<String> = []
  private var englishModel: NGramModel?
  private var russianModel: NGramModel?
  private let lock = NSLock()
  private var didStartLoading = false
  private var isLoaded = false

  private init() {}

  var isReady: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isLoaded
  }

  /// Starts loading in the background. Safe to call repeatedly; only the first
  /// call does any work.
  func preload() {
    lock.lock()
    if didStartLoading {
      lock.unlock()
      return
    }
    didStartLoading = true
    lock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      var en = Self.loadWords(named: "en")
      en.formUnion(Self.loadCustomWords(named: "custom-en"))
      let ru = Bundle.main.url(forResource: "ru-forms", withExtension: "bin")
        .flatMap { HashedWordSet(contentsOf: $0) } ?? HashedWordSet()
      let ruTypo = Bundle.main.url(forResource: "ru-typo", withExtension: "bin")
        .flatMap { HashedWordSet(contentsOf: $0) } ?? HashedWordSet()
      let ruCustom = Self.loadCustomWords(named: "custom-ru")
      let commonEn = Self.loadWords(named: "common-en")
      let commonRu = Self.loadWords(named: "common-ru")
      let enModel = Bundle.main.url(forResource: "ngram-en", withExtension: "bin")
        .flatMap { NGramModel(contentsOf: $0) }
      let ruModel = Bundle.main.url(forResource: "ngram-ru", withExtension: "bin")
        .flatMap { NGramModel(contentsOf: $0) }

      self.lock.lock()
      self.englishModel = enModel
      self.russianModel = ruModel
      self.english = en
      self.russian = ru
      self.russianTypo = ruTypo
      self.russianCustom = ruCustom
      self.commonEnglish = commonEn
      self.commonRussian = commonRu
      self.isLoaded = !en.isEmpty && !ru.isEmpty
      self.lock.unlock()
    }
  }

  /// The character n-gram model for a layout's language, for the engine's last
  /// tier. Nil if the resource is missing, which simply turns that tier off.
  func nGramModel(for layout: Layout) -> NGramModel? {
    lock.lock()
    defer { lock.unlock() }
    guard isLoaded else { return nil }
    return layout == .english ? englishModel : russianModel
  }

  func setNGramModels(english: NGramModel?, russian: NGramModel?) {
    lock.lock()
    englishModel = english
    russianModel = russian
    lock.unlock()
  }

  /// Directory holding the user's own additions, alongside the crash logs.
  static var customWordsDirectory: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Babbler", isDirectory: true)
  }

  func contains(_ word: String, in layout: Layout) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard isLoaded else { return false }
    return containsLocked(word, in: layout)
  }

  private func containsLocked(_ word: String, in layout: Layout) -> Bool {
    layout == .english
      ? english.contains(word)
      : russian.contains(word) || russianCustom.contains(word)
  }

  private func containsForTypoLocked(_ word: String, in layout: Layout) -> Bool {
    layout == .english
      ? english.contains(word)
      : russianTypo.contains(word) || russianCustom.contains(word)
  }

  /// Whether `word` becomes a real word by inserting exactly one character —
  /// that is, whether the user typed a real word but missed one keystroke.
  ///
  /// Only omission is modelled, and that is a measured decision rather than a
  /// conservative guess. Against 40,000 correctly typed English words, allowing
  /// any edit of distance one raised the false-positive rate from 0.025% to
  /// 4.01% ("learn" matched "дукат", "rate" matched "кафе"). Restricting to a
  /// dropped keystroke brings it to 0.010% while still catching every typo in
  /// the test set; transposition adds no recall, and allowing a doubled letter
  /// is actively harmful because English is full of "ff", "ee" and "ll".
  ///
  /// Russian is probed against `russianTypo`, the frequency-ranked core plus the
  /// curated supplement, not against all ~3 M inflected forms. Each probe is
  /// ~200 lookups, so a rare form such as an obsolete participle is a chance for
  /// a correctly typed English word to land one keystroke from it. Against the
  /// full list the English false-positive rate rose from 0.0115% to 0.0693%;
  /// against the core it is back where it was. Exact matches still use every
  /// form.
  ///
  /// A deletion index over the dictionary would be huge. It is unnecessary: `w`
  /// is a word of which `q` is a one-character deletion exactly when some
  /// single-character insertion into `q` equals `w`, so the insertions are
  /// generated and probed against the set we already have. That is about 224
  /// lookups with no extra memory.
  func hasWordOneInsertionAway(_ word: String, in layout: Layout) -> Bool {
    guard word.count >= Self.minimumTypoLength else { return false }

    lock.lock()
    defer { lock.unlock() }
    guard isLoaded else { return false }

    var characters = Array(word)
    // Never insert before the first character: typos essentially never hit the
    // first key, and forbidding it measurably lowered false positives.
    for position in 1...characters.count {
      characters.insert(" ", at: position)
      for letter in layout.alphabet {
        characters[position] = letter
        // The reconstructed word has to start the same way the user did.
        if characters[0] == word.first, containsForTypoLocked(String(characters), in: layout) {
          return true
        }
      }
      characters.remove(at: position)
    }
    return false
  }

  /// Below this length a dropped keystroke leaves too little signal, and the
  /// candidate space is dense enough that almost anything matches something.
  static let minimumTypoLength = 5

  /// Whether `word` is one vowel substitution, doubled letter or adjacent
  /// transposition away from a top-5000 word of `layout`'s language. Only the
  /// first full-dictionary candidate is checked, and the typo must be at least
  /// 4 characters (5 for transpositions). Measured on EN and RU top-20k with
  /// these guards: 0 false positives against the top-20k, proper nouns and
  /// English collisions.
  func hasCommonWordOneTypoAway(_ word: String, in layout: Layout) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard isLoaded else { return false }
    let common = layout == .english ? commonEnglish : commonRussian
    guard !common.isEmpty else { return false }

    let chars = Array(word)
    let passes: [(candidates: [String], minimumLength: Int)] = [
      (Self.vowelCandidates(chars, in: layout, optional: false), 4),
      (Self.vowelCandidates(chars, in: layout, optional: true), 4),
      (Self.doubledCandidates(chars), 4),
      (Self.swapCandidates(chars), 5),
    ]
    for pass in passes where chars.count >= pass.minimumLength {
      guard let target = pass.candidates.first(where: { containsLocked($0, in: layout) }) else {
        continue
      }
      if common.contains(target) { return true }
    }
    return false
  }

  private static func vowelCandidates(_ chars: [Character], in layout: Layout, optional: Bool) -> [String] {
    var out = Set<String>()
    for i in chars.indices {
      for target in vowelSubstitutes(chars[i], in: layout, optional: optional) {
        var c = chars
        c[i] = target
        out.insert(String(c))
      }
    }
    return out.sorted()
  }

  private static func vowelSubstitutes(_ c: Character, in layout: Layout, optional: Bool) -> [Character] {
    if layout == .russian {
      if optional {
        switch c {
        case "е": return ["я"]
        case "я": return ["е"]
        case "и": return ["ы"]
        case "ы": return ["и"]
        default: return []
        }
      }
      switch c {
      case "о": return ["а"]
      case "а": return ["о"]
      case "е": return ["и"]
      case "и": return ["е"]
      default: return []
      }
    }
    if optional { return [] }
    switch c {
    case "a": return ["e"]
    case "e": return ["a", "i"]
    case "i": return ["e"]
    case "o": return ["u"]
    case "u": return ["o"]
    default: return []
    }
  }

  private static func doubledCandidates(_ chars: [Character]) -> [String] {
    var out = Set<String>()
    for i in 0..<max(0, chars.count - 1) where chars[i] == chars[i + 1] {
      var c = chars
      c.remove(at: i)
      out.insert(String(c))
    }
    return out.sorted()
  }

  private static func swapCandidates(_ chars: [Character]) -> [String] {
    var out = Set<String>()
    for i in 0..<max(0, chars.count - 1) where chars[i] != chars[i + 1] {
      var c = chars
      c.swapAt(i, i + 1)
      out.insert(String(c))
    }
    return out.sorted()
  }

  private static func loadWords(named name: String) -> Set<String> {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt.gz"),
          let compressed = try? Data(contentsOf: url),
          let text = gunzip(compressed) else {
      return []
    }

    var words = Set<String>()
    words.reserveCapacity(220_000)
    text.enumerateLines { line, _ in
      if !line.isEmpty { words.insert(line) }
    }
    return words
  }

  /// Plain-text words the user added themselves, one per line, `#` for comments.
  /// Missing files are normal and simply contribute nothing.
  private static func loadCustomWords(named name: String) -> Set<String> {
    let url = customWordsDirectory.appendingPathComponent("\(name).txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

    var words = Set<String>()
    text.enumerateLines { line, _ in
      let word = line.trimmingCharacters(in: .whitespaces).lowercased()
      if !word.isEmpty, !word.hasPrefix("#") { words.insert(word) }
    }
    return words
  }

  /// Minimal gzip reader: skips the gzip header, then inflates the raw deflate
  /// payload with libcompression. Foundation has no public gzip API, and the
  /// files are static build artifacts, so a full-featured parser is unnecessary.
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

    // The gzip trailer stores the uncompressed size mod 2^32. The lists are a
    // few MB, so it is exact, but clamp to a sane floor in case it is not.
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

/// A set of words stored as sorted 48-bit hashes, for lists too large to hold as
/// `Set<String>`: 3 M Russian forms take ~13 MB here against hundreds as strings.
///
/// A lookup hashes the word and binary-searches one of 65,536 buckets selected
/// by the top 16 bits, comparing the remaining 32. A word that is not in the set
/// matches by accident with probability count / 2^48 (about 1 in 10^8), which is
/// below anything the typo probe's few hundred lookups per word can notice.
///
/// The resource is written by `scripts/build_ru_forms.py`, which must hash
/// identically: FNV-1a over UTF-8, one murmur3 finalizer step, top 48 bits. The
/// file holds the sorted hashes as Rice-coded gaps, about 3.5 bytes per word.
struct HashedWordSet {
  private static let hashBits = 48
  private static let bucketBits = 16
  private static let bucketCount = 1 << bucketBits

  private var bucketStarts: [UInt32] = []
  private var lows: [UInt32] = []

  init() {}

  var isEmpty: Bool { lows.isEmpty }
  var count: Int { lows.count }

  /// Builds a set directly from words. Used for tests and small lists; the
  /// shipped list is decoded from the resource instead.
  init<Words: Sequence>(words: Words) where Words.Element == String {
    self.init(sortedHashes: Set(words.lazy.map(Self.hash)).sorted())
  }

  private init(sortedHashes: [UInt64]) {
    var starts = [UInt32](repeating: 0, count: Self.bucketCount + 1)
    var lows = [UInt32]()
    lows.reserveCapacity(sortedHashes.count)
    for hash in sortedHashes {
      starts[Int(hash >> 32) + 1] += 1
      lows.append(UInt32(truncatingIfNeeded: hash))
    }
    for index in 1...Self.bucketCount { starts[index] += starts[index - 1] }
    bucketStarts = starts
    self.lows = lows
  }

  /// Decodes a `ru-forms.bin` style file. Returns nil if it is malformed.
  init?(contentsOf url: URL) {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let decoded = Self.decode(data) else { return nil }
    bucketStarts = decoded.starts
    lows = decoded.lows
  }

  func contains(_ word: String) -> Bool {
    guard !lows.isEmpty else { return false }
    let hash = Self.hash(word)
    let bucket = Int(hash >> 32)
    let low = UInt32(truncatingIfNeeded: hash)

    var lower = Int(bucketStarts[bucket])
    var upper = Int(bucketStarts[bucket + 1])
    while lower < upper {
      let middle = (lower + upper) >> 1
      let value = lows[middle]
      if value == low { return true }
      if value < low { lower = middle + 1 } else { upper = middle }
    }
    return false
  }

  static func hash(_ word: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in word.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    h ^= h >> 33
    h = h &* 0xff51afd7ed558ccd
    h ^= h >> 33
    return h >> UInt64(64 - hashBits)
  }

  private static func decode(_ data: Data) -> (starts: [UInt32], lows: [UInt32])? {
    let headerSize = 16
    guard data.count > headerSize + 16 else { return nil }

    return data.withUnsafeBytes { raw -> (starts: [UInt32], lows: [UInt32])? in
      guard raw[0] == 0x42, raw[1] == 0x42, raw[2] == 0x4c, raw[3] == 0x48,  // "BBLH"
            raw[4] == 1, Int(raw[5]) == hashBits else { return nil }
      let k = UInt64(raw[6])
      let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
      guard k >= 1, k <= 32 else { return nil }

      var starts = [UInt32](repeating: 0, count: bucketCount + 1)
      var lows = [UInt32]()
      lows.reserveCapacity(count)

      // The writer pads the stream with zero bytes, so an 8-byte load at any
      // valid bit position stays in bounds; the checks below guard bad input.
      let limit = data.count - 8
      let mask = (UInt64(1) << k) - 1
      var position = headerSize * 8
      var value: UInt64 = 0

      for _ in 0..<count {
        var quotient: UInt64 = 0
        while true {
          guard position >> 3 <= limit else { return nil }
          let window = raw.loadUnaligned(fromByteOffset: position >> 3, as: UInt64.self)
            >> UInt64(position & 7)
          if window != 0 {
            let zeros = window.trailingZeroBitCount
            quotient += UInt64(zeros)
            position += zeros + 1
            break
          }
          quotient += 56
          position += 56
        }
        guard position >> 3 <= limit else { return nil }
        let window = raw.loadUnaligned(fromByteOffset: position >> 3, as: UInt64.self)
          >> UInt64(position & 7)
        position += Int(k)
        value &+= (quotient << k) | (window & mask)
        guard value >> 32 < UInt64(bucketCount) else { return nil }

        starts[Int(value >> 32) + 1] += 1
        lows.append(UInt32(truncatingIfNeeded: value))
      }
      for index in 1...bucketCount { starts[index] += starts[index - 1] }
      return (starts, lows)
    }
  }
}

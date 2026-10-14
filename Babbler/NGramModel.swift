import Foundation
import Compression

/// A character n-gram language model over one alphabet, read from the dense
/// table written by `scripts/build_ngram_models.py`.
///
/// The table holds `-ln p(symbol | previous order-1 symbols)` in 1/`step` nat for
/// every context, already interpolated with the lower orders, so scoring a word
/// is one byte lookup per letter and nothing else. Symbol 0 is the word
/// boundary: a word is read as `order-1` boundaries, its letters, then one
/// closing boundary.
final class NGramModel {
  /// Natural-log cost of a character outside the alphabet; kept in step with
  /// `OUT_OF_ALPHABET` in `scripts/ngram_lib.py`.
  static let outOfAlphabetPenalty = 12.0

  private let order: Int
  private let symbolCount: Int
  private let contextCount: Int
  private let step: Double
  private let symbols: [UInt32: Int]
  private let costs: [UInt8]

  /// Returns nil if the file is missing or malformed.
  convenience init?(contentsOf url: URL) {
    guard let data = try? Data(contentsOf: url) else { return nil }
    self.init(data: data)
  }

  init?(data: Data) {
    let fixedHeader = 8
    guard data.count > fixedHeader,
          data[0] == 0x42, data[1] == 0x4e, data[2] == 0x47, data[3] == 0x4d,  // "BNGM"
          data[4] == 1 else { return nil }

    let order = Int(data[5])
    let symbolCount = Int(data[6])
    let step = Double(data[7])
    guard order >= 1, order <= 6, symbolCount >= 2, step > 0 else { return nil }

    let letterCount = symbolCount - 1
    let payloadStart = fixedHeader + 2 * letterCount
    guard data.count > payloadStart else { return nil }

    var symbols: [UInt32: Int] = [:]
    for index in 0..<letterCount {
      let unit = UInt32(data[fixedHeader + 2 * index])
        | (UInt32(data[fixedHeader + 2 * index + 1]) << 8)
      symbols[unit] = index + 1
    }

    var tableSize = 1
    for _ in 0..<order { tableSize *= symbolCount }

    let payload = data.subdata(in: payloadStart..<data.count)
    var costs = [UInt8](repeating: 0, count: tableSize)
    let written = costs.withUnsafeMutableBufferPointer { destination -> Int in
      payload.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(
          destination.baseAddress!, tableSize, base, payload.count, nil, COMPRESSION_ZLIB
        )
      }
    }
    guard written == tableSize else { return nil }

    self.order = order
    self.symbolCount = symbolCount
    self.contextCount = tableSize / symbolCount
    self.step = step
    self.symbols = symbols
    self.costs = costs
  }

  /// Natural-log probability of `word`. Characters outside the alphabet are read
  /// as a boundary and each cost `outOfAlphabetPenalty` on top.
  func logProbability(of word: String) -> Double {
    var context = 0
    var cost = 0
    var unknown = 0

    @inline(__always) func advance(_ symbol: Int) {
      cost += Int(costs[context * symbolCount + symbol])
      context = (context * symbolCount + symbol) % contextCount
    }

    for scalar in word.unicodeScalars {
      if let symbol = symbols[scalar.value] {
        advance(symbol)
      } else {
        unknown += 1
        advance(0)
      }
    }
    advance(0)
    return -Double(cost) / step - Double(unknown) * Self.outOfAlphabetPenalty
  }
}

//
//  LineDiff.swift
//  HexCore
//
//  Line-level diff for the Edit-mode review banner: removed lines struck
//  through, additions highlighted, unchanged lines plain.
//
//  The design prototype diffed by set membership (`cset.has(line)`), which
//  reads fine on a mock but misbehaves on real notes: repeated lines (two
//  identical bullets, blank lines) collide, and every moved line shows up
//  as both a deletion and an addition. This walks a proper LCS instead, so
//  the diff reflects what actually changed.
//

import Foundation

public enum LineDiff {
  public enum Kind: Equatable, Sendable {
    case unchanged
    case removed
    case added
  }

  public struct Row: Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let kind: Kind

    public init(id: Int, text: String, kind: Kind) {
      self.id = id
      self.text = text
      self.kind = kind
    }
  }

  /// Diff `before` against `after`, line by line.
  public static func rows(from before: String, to after: String) -> [Row] {
    let old = before.components(separatedBy: "\n")
    let new = after.components(separatedBy: "\n")
    let table = lcsTable(old, new)

    var rows: [Row] = []
    var i = 0, j = 0
    var nextID = 0

    func append(_ text: String, _ kind: Kind) {
      rows.append(Row(id: nextID, text: text, kind: kind))
      nextID += 1
    }

    // Walk the table forward, emitting removals before additions so a
    // replaced line reads top-to-bottom as "was / now".
    while i < old.count, j < new.count {
      if old[i] == new[j] {
        append(old[i], .unchanged)
        i += 1
        j += 1
      } else if table[i + 1][j] >= table[i][j + 1] {
        append(old[i], .removed)
        i += 1
      } else {
        append(new[j], .added)
        j += 1
      }
    }
    while i < old.count {
      append(old[i], .removed)
      i += 1
    }
    while j < new.count {
      append(new[j], .added)
      j += 1
    }

    return rows
  }

  /// `table[i][j]` = length of the LCS of `a[i...]` and `b[j...]`.
  private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
    var table = Array(
      repeating: Array(repeating: 0, count: b.count + 1),
      count: a.count + 1
    )
    guard !a.isEmpty, !b.isEmpty else { return table }

    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        table[i][j] = a[i] == b[j]
          ? table[i + 1][j + 1] + 1
          : Swift.max(table[i + 1][j], table[i][j + 1])
      }
    }
    return table
  }
}

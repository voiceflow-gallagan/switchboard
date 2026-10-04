import Foundation

/// Changes JSON text at one place and leaves every other byte as it was.
///
/// A path is a list of object keys, never a dotted string. Every function returns nil when the
/// text is not valid JSON, when a key along the path appears more than once, or when the path
/// does not have the expected shape. Only the last key of a path may be missing, and only where
/// a function says it creates it.
enum JSONText {
  /// Sets the boolean at `path`, creating the last key when it is missing.
  static func setBool(_ value: Bool, at path: [String], in text: String) -> String? {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast())
    else { return nil }
    switch document.member(named: name, in: parent) {
    case .found(let index):
      guard case .bool(let current) = parent.members[index].value.content else { return nil }
      guard current != value else { return text }
      return document.replacing(parent.members[index].value.range, with: value ? "true" : "false")
    case .missing:
      return document.inserting(name: name, raw: value ? "true" : "false", into: parent)
    case .ambiguous:
      return nil
    }
  }

  /// Appends `value` to the array at `path`, creating the array when its key is missing.
  /// Text that already holds the value is returned unchanged.
  static func addString(_ value: String, toArrayAt path: [String], in text: String) -> String? {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast())
    else { return nil }
    switch document.member(named: name, in: parent) {
    case .found(let index):
      let array = parent.members[index].value
      guard array.content == .array else { return nil }
      let elements = array.elements
      if elements.contains(where: { $0.isString(value) }) { return text }
      return document.inserting(element: encoded(value), into: array, after: elements)
    case .missing:
      let created = document.inserting(name: name, raw: "[]", into: parent)
      return addString(value, toArrayAt: path, in: created)
    case .ambiguous:
      return nil
    }
  }

  /// Removes every copy of `value` from the array at `path`. A missing array, or one without
  /// the value, returns the text unchanged.
  static func removeString(_ value: String, fromArrayAt path: [String], in text: String) -> String?
  {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast())
    else { return nil }
    switch document.member(named: name, in: parent) {
    case .found(let index):
      let array = parent.members[index].value
      guard array.content == .array else { return nil }
      let elements = array.elements
      let matches = elements.indices.filter { elements[$0].isString(value) }
      guard !matches.isEmpty else { return text }
      return document.removing(matches, from: array)
    case .missing:
      return text
    case .ambiguous:
      return nil
    }
  }

  /// Removes the member at `path`. Returns the new text, the exact text of the removed value,
  /// and the name of the member that followed it, so it can be put back in the same place.
  static func removeMember(at path: [String], in text: String) -> (
    text: String, removed: String, following: String?
  )? {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast()),
      case .found(let index) = document.member(named: name, in: parent)
    else { return nil }
    let members = parent.members
    let range = document.removalRange(
      of: index, starts: members.map(\.keyRange.lowerBound),
      ends: members.map(\.value.range.upperBound), in: parent)
    return (
      document.replacing(range, with: ""),
      document.text(members[index].value.range),
      index + 1 < members.count ? members[index + 1].name : nil
    )
  }

  /// Inserts a member named `name` whose value is the exact text `raw` into the object at
  /// `path`, before the member named `following` when there is one, otherwise last. Returns nil
  /// when a member with that name exists or `raw` is not a JSON value.
  static func insertMember(
    _ raw: String, named name: String, at path: [String], following: String? = nil,
    in text: String
  ) -> String? {
    guard Document(raw) != nil, let document = Document(text),
      let parent = document.object(at: path[...]),
      case .missing = document.member(named: name, in: parent)
    else { return nil }
    var before: Int?
    if let following, case .found(let index) = document.member(named: following, in: parent) {
      before = index
    }
    return document.inserting(name: name, raw: raw, into: parent, before: before)
  }

  /// `raw` laid out to be inserted by `insertMember` as the last member of the object at `path`,
  /// in the style of `text`: one item per line, indented one step deeper than the members around
  /// it, when `text` has line breaks, otherwise on one line. Strings, numbers and literals keep
  /// their exact text. Nil when `raw` is not a JSON value or `path` does not lead to an object.
  static func formatted(_ raw: String, asMemberAt path: [String], in text: String) -> String? {
    guard let value = Document(raw), let document = Document(text),
      let parent = document.object(at: path[...])
    else { return nil }
    return value.layout(
      value.root, style: document.style, indent: document.memberIndent(of: parent))
  }

  /// `raw` on several lines with two spaces of indentation, as a reader would write it. Nil when
  /// `raw` is not a JSON value.
  static func formatted(_ raw: String) -> String? {
    guard let value = Document(raw) else { return nil }
    return value.layout(value.root, style: .readable, indent: "")
  }

  /// Whether the object at `path` has a member named by the last key.
  static func hasMember(at path: [String], in text: String) -> Bool? {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast())
    else { return nil }
    switch document.member(named: name, in: parent) {
    case .found: return true
    case .missing: return false
    case .ambiguous: return nil
    }
  }

  /// The exact text of each member of the object at `path`, in order. Nil when the text is not
  /// valid JSON or `path` does not lead to an object.
  static func members(at path: [String], in text: String) -> [(name: String, value: String)]? {
    guard let document = Document(text), let object = document.object(at: path[...]) else {
      return nil
    }
    return object.members.map { ($0.name, document.text($0.value.range)) }
  }

  /// `members(at:in:)` for several paths, parsing the text once. A path that does not lead to an
  /// object is left out. Nil when the text is not valid JSON.
  static func members(atEach paths: [[String]], in text: String) -> [[String]: [(
    name: String, value: String
  )]]? {
    guard let document = Document(text) else { return nil }
    var result: [[String]: [(name: String, value: String)]] = [:]
    for path in paths {
      if let object = document.object(at: path[...]) {
        result[path] = object.members.map { ($0.name, document.text($0.value.range)) }
      }
    }
    return result
  }

  /// The strings in the array at `path`, skipping anything else. Nil when the text is not valid
  /// JSON or the path does not lead to an array.
  static func strings(at path: [String], in text: String) -> [String]? {
    guard let document = Document(text), let name = path.last,
      let parent = document.object(at: path.dropLast()),
      case .found(let index) = document.member(named: name, in: parent),
      parent.members[index].value.content == .array
    else { return nil }
    return parent.members[index].value.elements.compactMap {
      if case .string(let string) = $0.content { string } else { nil }
    }
  }

  /// Whether `text` is one valid JSON value.
  static func isValid(_ text: String) -> Bool {
    Document(text) != nil
  }

  static func encoded(_ string: String) -> String {
    var result = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      case _ where scalar.value < 0x20:
        result += String(format: "\\u%04x", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}

private struct Node {
  enum Content: Equatable {
    case object
    case array
    case string(String)
    case bool(Bool)
    case other
  }

  var range: Range<Int>
  var content: Content
  var members: [Member] = []
  var elements: [Node] = []
}

extension Node {
  fileprivate func isString(_ value: String) -> Bool {
    if case .string(let string) = content { string.isIdentical(to: value) } else { false }
  }
}

extension String {
  /// Equal scalar by scalar. Swift's `==` treats different Unicode normalization forms as equal,
  /// which would let one key select another.
  func isIdentical(to other: String) -> Bool {
    unicodeScalars.elementsEqual(other.unicodeScalars)
  }
}

private struct Member {
  var name: String
  var keyRange: Range<Int>
  var value: Node
}

private enum MemberLookup {
  case found(Int)
  case missing
  case ambiguous
}

/// How a text lays out its containers.
private struct Style {
  static let readable = Style(newline: "\n", step: "  ", colon: ": ")

  /// Nil when the text is on one line.
  var newline: String?
  var step: String
  var colon: String
}

private struct Document {
  let bytes: [UInt8]
  let root: Node

  init?(_ text: String) {
    var parser = Parser(bytes: Array(text.utf8))
    guard let root = parser.document() else { return nil }
    bytes = parser.bytes
    self.root = root
  }

  func object(at path: ArraySlice<String>) -> Node? {
    var current = root
    for key in path {
      guard current.content == .object, case .found(let index) = member(named: key, in: current)
      else { return nil }
      current = current.members[index].value
    }
    return current.content == .object ? current : nil
  }

  func member(named name: String, in node: Node) -> MemberLookup {
    let matches = node.members.indices.filter { node.members[$0].name.isIdentical(to: name) }
    switch matches.count {
    case 0: return .missing
    case 1: return .found(matches[0])
    default: return .ambiguous
    }
  }

  func text(_ range: Range<Int>) -> String {
    String(decoding: bytes[range], as: UTF8.self)
  }

  func replacing(_ range: Range<Int>, with replacement: String) -> String {
    String(
      decoding: bytes[..<range.lowerBound] + Array(replacement.utf8) + bytes[range.upperBound...],
      as: UTF8.self)
  }

  /// The text with the items at `indices` of `container` removed, in one pass. Items are
  /// removed from the last one backwards, each by the rule of `removalRange`, so every range
  /// refers to the original text. A range may contain ranges found before it, so they are
  /// merged.
  func removing(_ indices: [Int], from container: Node) -> String {
    var starts = container.elements.map(\.range.lowerBound)
    var ends = container.elements.map(\.range.upperBound)
    var ranges: [Range<Int>] = []
    if indices.count == starts.count {
      ranges = [(container.range.lowerBound + 1)..<(container.range.upperBound - 1)]
    } else {
      for index in indices.sorted(by: >) {
        ranges.append(removalRange(of: index, starts: starts, ends: ends, in: container))
        starts.remove(at: index)
        ends.remove(at: index)
      }
    }
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var position = 0
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if range.lowerBound > position {
        result += bytes[position..<range.lowerBound]
      }
      position = max(position, range.upperBound)
    }
    result += bytes[position...]
    return String(decoding: result, as: UTF8.self)
  }

  /// The bytes to remove for item `index` of a container whose items start and end at the
  /// given offsets. The only item takes the whole inside with it. The last takes the separator
  /// before it. Any other takes the separator after it.
  func removalRange(of index: Int, starts: [Int], ends: [Int], in container: Node) -> Range<Int> {
    if starts.count == 1 {
      return (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
    }
    if index == starts.count - 1 {
      return ends[index - 1]..<ends[index]
    }
    return starts[index]..<starts[index + 1]
  }

  /// The text between two neighbouring items, such as `,\n  `. With one item, a comma and
  /// the space before that item.
  // ponytail: an insert copies one observed separator and re-encodes the key, so text with
  // uneven separators or keys written with needless escapes such as `\/` does not come back
  // byte for byte. It always parses to the same value.
  private func separator(starts: [Int], ends: [Int], at index: Int, container: Node) -> String {
    if starts.count >= 2 {
      let pair = min(max(index, 0), starts.count - 2)
      return text(ends[pair]..<starts[pair + 1])
    }
    return "," + text((container.range.lowerBound + 1)..<starts[0])
  }

  func inserting(name: String, raw: String, into object: Node, before: Int? = nil) -> String {
    let members = object.members
    guard let neighbour = before ?? members.indices.last else {
      return insertingIntoEmpty(JSONText.encoded(name) + defaultColon + raw, container: object)
    }
    let colon = text(
      members[neighbour].keyRange.upperBound..<members[neighbour].value.range.lowerBound)
    let member = JSONText.encoded(name) + colon + raw
    let starts = members.map(\.keyRange.lowerBound)
    let ends = members.map(\.value.range.upperBound)
    if let before {
      let separator = separator(starts: starts, ends: ends, at: before - 1, container: object)
      return replacing(starts[before]..<starts[before], with: member + separator)
    }
    let separator = separator(
      starts: starts, ends: ends, at: members.count - 2, container: object)
    return replacing(ends[neighbour]..<ends[neighbour], with: separator + member)
  }

  func inserting(element raw: String, into array: Node, after elements: [Node]) -> String {
    guard let last = elements.last else {
      return insertingIntoEmpty(raw, container: array)
    }
    let separator = separator(
      starts: elements.map(\.range.lowerBound), ends: elements.map(\.range.upperBound),
      at: elements.count - 2, container: array)
    let end = last.range.upperBound
    return replacing(end..<end, with: separator + raw)
  }

  /// Puts `item` alone inside an empty container. In text with line breaks, the item goes on
  /// its own line, one indentation step deeper than the line that opens the container.
  private func insertingIntoEmpty(_ item: String, container: Node) -> String {
    let inside = (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
    guard let newline else {
      return replacing(inside, with: item)
    }
    let indent = lineIndent(at: container.range.lowerBound)
    return replacing(
      inside, with: newline + indent + indentStep + item + newline + indent)
  }

  /// The line break of a text that has line breaks before its last value ends, otherwise nil.
  private var newline: String? {
    let content = bytes[..<(bytes.lastIndex { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? 0)]
    guard content.contains(UInt8(ascii: "\n")) else { return nil }
    return bytes.contains(UInt8(ascii: "\r")) ? "\r\n" : "\n"
  }

  var style: Style {
    Style(newline: newline, step: indentStep, colon: defaultColon)
  }

  /// The indentation of the line a new last member of `object` starts on.
  func memberIndent(of object: Node) -> String {
    guard let last = object.members.last else {
      return lineIndent(at: object.range.lowerBound) + indentStep
    }
    return lineIndent(at: last.keyRange.lowerBound)
  }

  /// `node`, a value of this document, laid out in `style` for a line indented by `indent`.
  // ponytail: text on one line gets a space after each comma exactly when its colon has one.
  func layout(_ node: Node, style: Style, indent: String) -> String {
    let deeper = indent + style.step
    let items: [String]
    let brackets: (open: String, close: String)
    switch node.content {
    case .object:
      items = node.members.map {
        text($0.keyRange) + style.colon + layout($0.value, style: style, indent: deeper)
      }
      brackets = ("{", "}")
    case .array:
      items = node.elements.map { layout($0, style: style, indent: deeper) }
      brackets = ("[", "]")
    default:
      return text(node.range)
    }
    guard !items.isEmpty else { return brackets.open + brackets.close }
    guard let newline = style.newline else {
      let comma = style.colon.hasSuffix(" ") ? ", " : ","
      return brackets.open + items.joined(separator: comma) + brackets.close
    }
    let itemStart = newline + deeper
    return brackets.open + itemStart + items.joined(separator: "," + itemStart) + newline + indent
      + brackets.close
  }

  private func lineIndent(at offset: Int) -> String {
    var start = offset
    while start > 0, bytes[start - 1] != UInt8(ascii: "\n") {
      start -= 1
    }
    var end = start
    while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") {
      end += 1
    }
    return text(start..<end)
  }

  /// The indentation of the first indented line, or two spaces.
  private var indentStep: String {
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "\n") {
        let indent = lineIndent(at: index + 1)
        if !indent.isEmpty { return indent }
      }
      index += 1
    }
    return "  "
  }

  /// The text between the first key in the document and its value, or `": "`.
  private var defaultColon: String {
    var pending = [root]
    while let node = pending.popLast() {
      if let member = node.members.first {
        return text(member.keyRange.upperBound..<member.value.range.lowerBound)
      }
      pending += node.elements.reversed()
    }
    return ": "
  }
}

/// A strict JSON parser that keeps the byte range of every value.
private struct Parser {
  static let depthLimit = 512

  let bytes: [UInt8]
  private var index = 0
  private var depth = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func document() -> Node? {
    skipWhitespace()
    guard let root = value() else { return nil }
    skipWhitespace()
    return index == bytes.count ? root : nil
  }

  private mutating func value() -> Node? {
    guard index < bytes.count else { return nil }
    let start = index
    switch UnicodeScalar(bytes[index]) {
    case "{": return object()
    case "[": return array()
    case "\"":
      guard let string = string() else { return nil }
      return Node(range: start..<index, content: .string(string))
    case "t": return literal("true", .bool(true))
    case "f": return literal("false", .bool(false))
    case "n": return literal("null", .other)
    case "-", "0"..."9": return number()
    default: return nil
    }
  }

  private mutating func object() -> Node? {
    let start = index
    guard enter() else { return nil }
    defer { depth -= 1 }
    index += 1
    var members: [Member] = []
    skipWhitespace()
    if consume("}") {
      return Node(range: start..<index, content: .object)
    }
    while true {
      skipWhitespace()
      let keyStart = index
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let name = string() else {
        return nil
      }
      let keyRange = keyStart..<index
      skipWhitespace()
      guard consume(":") else { return nil }
      skipWhitespace()
      guard let value = value() else { return nil }
      members.append(Member(name: name, keyRange: keyRange, value: value))
      skipWhitespace()
      if consume("}") {
        return Node(range: start..<index, content: .object, members: members)
      }
      guard consume(",") else { return nil }
    }
  }

  private mutating func array() -> Node? {
    let start = index
    guard enter() else { return nil }
    defer { depth -= 1 }
    index += 1
    var elements: [Node] = []
    skipWhitespace()
    if consume("]") {
      return Node(range: start..<index, content: .array)
    }
    while true {
      skipWhitespace()
      guard let element = value() else { return nil }
      elements.append(element)
      skipWhitespace()
      if consume("]") {
        return Node(range: start..<index, content: .array, elements: elements)
      }
      guard consume(",") else { return nil }
    }
  }

  private mutating func enter() -> Bool {
    depth += 1
    if depth > Self.depthLimit {
      depth -= 1
      return false
    }
    return true
  }

  /// Reads a string starting at its opening quote and returns its decoded value.
  private mutating func string() -> String? {
    index += 1
    var decoded: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case UInt8(ascii: "\""):
        return String(decoding: decoded, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard index < bytes.count else { return nil }
        let escape = bytes[index]
        index += 1
        switch UnicodeScalar(escape) {
        case "\"", "\\", "/": decoded.append(escape)
        case "b": decoded.append(0x08)
        case "f": decoded.append(0x0C)
        case "n": decoded.append(0x0A)
        case "r": decoded.append(0x0D)
        case "t": decoded.append(0x09)
        case "u":
          guard let scalar = escapedScalar() else { return nil }
          decoded += Array(String(Character(scalar)).utf8)
        default: return nil
        }
      case 0..<0x20:
        return nil
      default:
        decoded.append(byte)
      }
    }
    return nil
  }

  /// The scalar of a `\u` escape, joining a surrogate pair. A lone surrogate is valid JSON,
  /// written for example when a string was cut inside an emoji. It decodes as the replacement
  /// character, and its bytes in the text are never touched.
  private mutating func escapedScalar() -> UnicodeScalar? {
    let replacement: UnicodeScalar = "\u{FFFD}"
    guard let first = hexQuad() else { return nil }
    if (0xD800...0xDBFF).contains(first) {
      let afterFirst = index
      if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
        bytes[index + 1] == UInt8(ascii: "u")
      {
        index += 2
        if let second = hexQuad(), (0xDC00...0xDFFF).contains(second) {
          return UnicodeScalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
        }
      }
      index = afterFirst
      return replacement
    }
    return UnicodeScalar(first) ?? replacement
  }

  private mutating func hexQuad() -> UInt32? {
    guard index + 4 <= bytes.count,
      bytes[index..<index + 4].allSatisfy({ UnicodeScalar($0).properties.isASCIIHexDigit }),
      let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
    else { return nil }
    index += 4
    return value
  }

  private mutating func number() -> Node? {
    let start = index
    _ = consume("-")
    if !consume("0"), digits() == 0 {
      return nil
    }
    if consume("."), digits() == 0 {
      return nil
    }
    if consume("e") || consume("E") {
      _ = consume("+") || consume("-")
      if digits() == 0 { return nil }
    }
    return Node(range: start..<index, content: .other)
  }

  private mutating func digits() -> Int {
    let start = index
    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
      index += 1
    }
    return index - start
  }

  private mutating func literal(_ word: String, _ content: Node.Content) -> Node? {
    let start = index
    let expected = Array(word.utf8)
    guard index + expected.count <= bytes.count,
      Array(bytes[index..<index + expected.count]) == expected
    else { return nil }
    index += expected.count
    return Node(range: start..<index, content: content)
  }

  private mutating func consume(_ character: UnicodeScalar) -> Bool {
    guard index < bytes.count, bytes[index] == UInt8(character.value) else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
      index += 1
    }
  }
}

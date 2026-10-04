import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct JSONTextTests {
  private func parses(_ text: String) -> Bool {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
  }

  /// `forward` gives exactly `expected`, which parses, and `back` gives exactly `original`.
  /// Comparing whole texts proves every byte outside the changed value is as it was.
  private func expectRoundTrip(
    _ original: String,
    _ expected: String,
    forward: (String) -> String?,
    back: (String) -> String?
  ) throws {
    #expect(parses(original))
    let changed = try #require(forward(original))
    #expect(changed == expected)
    #expect(parses(changed))
    #expect(back(changed) == original)
  }

  @Test func setBoolChangesOnlyTheValueAtANestedEscapedKey() throws {
    let original = """
      {
        "enabledPlugins": {
          "a\\"b@m": true,
          "ü/ñ.x y": false
        },
        "ü/ñ.x y": false
      }
      """
    let path = ["enabledPlugins", "ü/ñ.x y"]
    try expectRoundTrip(
      original,
      original.replacingOccurrences(
        of: "\"ü/ñ.x y\": false\n  },", with: "\"ü/ñ.x y\": true\n  },"),
      forward: { JSONText.setBool(true, at: path, in: $0) },
      back: { JSONText.setBool(false, at: path, in: $0) })
    #expect(JSONText.setBool(false, at: ["enabledPlugins", "a\"b@m"], in: original) != nil)
  }

  @Test func setBoolKeepsTabsAndUnusualSpacing() throws {
    try expectRoundTrip(
      "{\r\n\t\"isEnabled\" :\t\ttrue ,\r\n\t\"userConfig\":{ }\r\n}\r\n",
      "{\r\n\t\"isEnabled\" :\t\tfalse ,\r\n\t\"userConfig\":{ }\r\n}\r\n",
      forward: { JSONText.setBool(false, at: ["isEnabled"], in: $0) },
      back: { JSONText.setBool(true, at: ["isEnabled"], in: $0) })
  }

  @Test func setBoolAddsAMissingLastKeyWithTheSurroundingStyle() throws {
    try expectRoundTrip(
      "{\n  \"a\": 1\n}",
      "{\n  \"a\": 1,\n  \"b\": true\n}",
      forward: { JSONText.setBool(true, at: ["b"], in: $0) },
      back: { JSONText.removeMember(at: ["b"], in: $0)?.text })
    try expectRoundTrip(
      "{\n  \"enabledPlugins\": {}\n}",
      "{\n  \"enabledPlugins\": {\n    \"x@m\": true\n  }\n}",
      forward: { JSONText.setBool(true, at: ["enabledPlugins", "x@m"], in: $0) },
      back: { JSONText.removeMember(at: ["enabledPlugins", "x@m"], in: $0)?.text })
    try expectRoundTrip(
      "{}",
      "{\"isEnabled\": false}",
      forward: { JSONText.setBool(false, at: ["isEnabled"], in: $0) },
      back: { JSONText.removeMember(at: ["isEnabled"], in: $0)?.text })
  }

  @Test func setBoolToTheCurrentValueReturnsTheSameText() {
    let text = "{ \"a\": true }"
    #expect(JSONText.setBool(true, at: ["a"], in: text) == text)
  }

  @Test func anUnexpectedShapeReturnsNil() {
    #expect(JSONText.setBool(true, at: ["a"], in: "{\"a\": \"yes\"}") == nil)
    #expect(JSONText.setBool(true, at: ["a", "b"], in: "{\"a\": []}") == nil)
    #expect(JSONText.setBool(true, at: ["a", "b"], in: "{}") == nil)
    #expect(JSONText.setBool(true, at: ["a"], in: "{\"a\": true, \"a\": false}") == nil)
    #expect(JSONText.setBool(true, at: ["a"], in: "[]") == nil)
    #expect(JSONText.setBool(true, at: [], in: "{}") == nil)
    #expect(JSONText.addString("x", toArrayAt: ["a"], in: "{\"a\": {}}") == nil)
    #expect(JSONText.addString("x", toArrayAt: ["p", "a"], in: "{}") == nil)
    #expect(JSONText.removeString("x", fromArrayAt: ["a"], in: "{\"a\": \"x\"}") == nil)
    #expect(JSONText.removeMember(at: ["a"], in: "{\"b\": 1}") == nil)
    #expect(JSONText.insertMember("1", named: "a", at: [], in: "{\"a\": 2}") == nil)
    #expect(JSONText.insertMember("{", named: "b", at: [], in: "{\"a\": 2}") == nil)
    #expect(JSONText.insertMember("1", named: "b", at: ["a"], in: "{\"a\": 2}") == nil)
  }

  @Test func textThatIsNotJSONReturnsNil() {
    for text in [
      "", "{", "{\"a\": tru}", "{\"a\": 1,}", "{\"a\": 01}", "{\"a\": \"\u{01}\"}",
      "{} {}", "{\"a\": 1} x", "\u{FEFF}{}",
    ] {
      #expect(JSONText.setBool(true, at: ["a"], in: text) == nil)
      #expect(!JSONText.isValid(text))
    }
    #expect(JSONText.isValid("{\"a\": [1.5e-3, -0, null, \"\\ud83d\\ude00\\n\"]}"))
  }

  @Test func addStringAppendsToAnArrayInAProjectWithSpecialCharacters() throws {
    let original = """
      {
        "projects": {
          "/Users/a b/\\"q\\".x": {
            "disabledMcpServers": [
              "search"
            ]
          }
        }
      }
      """
    let path = ["projects", "/Users/a b/\"q\".x", "disabledMcpServers"]
    try expectRoundTrip(
      original,
      original.replacingOccurrences(
        of: "\"search\"\n", with: "\"search\",\n        \"plugin:helper:api \\\"x\\\"\"\n"),
      forward: { JSONText.addString("plugin:helper:api \"x\"", toArrayAt: path, in: $0) },
      back: { JSONText.removeString("plugin:helper:api \"x\"", fromArrayAt: path, in: $0) })
  }

  @Test func addStringFillsAnEmptyArrayOnItsOwnLines() throws {
    try expectRoundTrip(
      "{\n  \"p\": {\n    \"off\": []\n  }\n}",
      "{\n  \"p\": {\n    \"off\": [\n      \"x\"\n    ]\n  }\n}",
      forward: { JSONText.addString("x", toArrayAt: ["p", "off"], in: $0) },
      back: { JSONText.removeString("x", fromArrayAt: ["p", "off"], in: $0) })
    try expectRoundTrip(
      "{\"a\":[\"x\"]}",
      "{\"a\":[\"x\",\"y\"]}",
      forward: { JSONText.addString("y", toArrayAt: ["a"], in: $0) },
      back: { JSONText.removeString("y", fromArrayAt: ["a"], in: $0) })
  }

  @Test func addStringCreatesAMissingArray() throws {
    try expectRoundTrip(
      "{\n  \"p\": {\n    \"allowedTools\": []\n  }\n}",
      "{\n  \"p\": {\n    \"allowedTools\": [],\n    \"off\": [\n      \"x\"\n    ]\n  }\n}",
      forward: { JSONText.addString("x", toArrayAt: ["p", "off"], in: $0) },
      back: { JSONText.removeMember(at: ["p", "off"], in: $0)?.text })
  }

  @Test func addStringOfAPresentValueAndRemoveStringOfAnAbsentOneChangeNothing() {
    let text = "{\"a\": [\"x\", 1, \"y\"]}"
    #expect(JSONText.addString("x", toArrayAt: ["a"], in: text) == text)
    #expect(JSONText.removeString("z", fromArrayAt: ["a"], in: text) == text)
    #expect(JSONText.removeString("z", fromArrayAt: ["b"], in: text) == text)
  }

  @Test func removeStringRemovesEveryCopyAndKeepsTheRestInOrder() {
    let text = "{\n  \"a\": [\n    \"x\",\n    \"y\",\n    \"x\",\n    \"z\"\n  ]\n}"
    #expect(
      JSONText.removeString("x", fromArrayAt: ["a"], in: text)
        == "{\n  \"a\": [\n    \"y\",\n    \"z\"\n  ]\n}")
    #expect(JSONText.removeString("y", fromArrayAt: ["a"], in: "{\"a\": [\"y\"]}") == "{\"a\": []}")
  }

  private let servers = """
    {
      "mcpServers": {
        "first": {"command": "one"},
        "we\\"ird/na.me ü": {
          "url": "https://h.example.test",
          "headers": { "Authorization": "Bearer x" }
        },
        "last": [1, 2]
      },
      "other": true
    }
    """

  @Test(arguments: ["first", "we\"ird/na.me ü", "last"])
  func removeMemberThenInsertMemberGivesBackTheOriginal(name: String) throws {
    let path = ["mcpServers", name]
    let removal = try #require(JSONText.removeMember(at: path, in: servers))
    #expect(parses(removal.text))
    #expect(parses(removal.removed))
    #expect(servers.contains(removal.removed))
    #expect(JSONText.hasMember(at: path, in: removal.text) == false)
    #expect(
      JSONText.insertMember(
        removal.removed, named: name, at: ["mcpServers"], following: removal.following,
        in: removal.text) == servers)
  }

  @Test func removeMemberKeepsEveryOtherByte() throws {
    let removal = try #require(
      JSONText.removeMember(at: ["mcpServers", "we\"ird/na.me ü"], in: servers))
    #expect(
      removal.removed
        == "{\n      \"url\": \"https://h.example.test\",\n      \"headers\": { \"Authorization\": \"Bearer x\" }\n    }"
    )
    #expect(removal.following == "last")
    #expect(
      removal.text
        == "{\n  \"mcpServers\": {\n    \"first\": {\"command\": \"one\"},\n    \"last\": [1, 2]\n  },\n  \"other\": true\n}"
    )
  }

  @Test func theOnlyMemberLeavesAnEmptyObjectAndComesBackOnItsOwnLines() throws {
    let original =
      "{\n\t\"mcpServers\": {\n\t\t\"only\": {\n\t\t\t\"command\": \"x\"\n\t\t}\n\t}\n}"
    let removal = try #require(JSONText.removeMember(at: ["mcpServers", "only"], in: original))
    #expect(removal.text == "{\n\t\"mcpServers\": {}\n}")
    #expect(removal.following == nil)
    #expect(
      JSONText.insertMember(removal.removed, named: "only", at: ["mcpServers"], in: removal.text)
        == original)
  }

  @Test func membersOnOneLineWithUnusualSpacingComeBack() throws {
    let original = "{ \"a\"  :  1 ,  \"b\"  :  [ ] ,  \"c\"  :  {} }"
    for name in ["a", "b", "c"] {
      let removal = try #require(JSONText.removeMember(at: [name], in: original))
      #expect(parses(removal.text))
      #expect(
        JSONText.insertMember(
          removal.removed, named: name, at: [], following: removal.following, in: removal.text)
          == original)
    }
  }

  @Test func insertMemberWithoutAFollowingMemberGoesLast() {
    #expect(
      JSONText.insertMember("2", named: "b", at: [], following: "gone", in: "{\n  \"a\": 1\n}")
        == "{\n  \"a\": 1,\n  \"b\": 2\n}")
  }

  @Test func aUnicodeEscapeNeedsExactlyFourHexDigits() {
    for escape in ["\\u+041", "\\u-041", "\\u 041", "\\u004", "\\u0x41"] {
      #expect(!JSONText.isValid("{\"a\": \"\(escape)\"}"))
    }
    #expect(JSONText.isValid("{\"a\": \"\\u00e9\\u00E9\"}"))
  }

  @Test func keysInDifferentNormalizationFormsAreDifferentKeys() throws {
    let composed = "caf\u{E9}"
    let decomposed = "cafe\u{301}"
    let text = "{\"\(decomposed)\": false, \"\(composed)\": false, \"list\": [\"\(decomposed)\"]}"
    let changed = try #require(JSONText.setBool(true, at: [composed], in: text))
    #expect(
      changed.isIdentical(
        to: "{\"\(decomposed)\": false, \"\(composed)\": true, \"list\": [\"\(decomposed)\"]}"))
    #expect(
      JSONText.hasMember(at: ["only-\(composed)"], in: "{\"only-\(decomposed)\": 1}") == false)
    #expect(
      JSONText.removeString(composed, fromArrayAt: ["list"], in: text)?.isIdentical(to: text)
        == true)
    #expect(
      JSONText.addString(composed, toArrayAt: ["list"], in: text)
        .map {
          $0.isIdentical(
            to:
              "{\"\(decomposed)\": false, \"\(composed)\": false, \"list\": [\"\(decomposed)\",\"\(composed)\"]}"
          )
        } == true)
  }

  @Test func removeStringRemovesThousandsOfCopiesInOnePass() throws {
    let copies = Array(repeating: "    \"x\"", count: 3000)
    let text =
      "{\n  \"a\": [\n    \"keep\",\n" + copies.joined(separator: ",\n") + ",\n    \"last\"\n  ]\n}"
    let clock = ContinuousClock()
    var result: String?
    let elapsed = clock.measure {
      result = JSONText.removeString("x", fromArrayAt: ["a"], in: text)
    }
    #expect(result == "{\n  \"a\": [\n    \"keep\",\n    \"last\"\n  ]\n}")
    #expect(elapsed < .seconds(2))
    #expect(
      JSONText.removeString("x", fromArrayAt: ["a"], in: "{\"a\": [\"x\", \"x\"]}") == "{\"a\": []}"
    )
    #expect(
      JSONText.removeString("x", fromArrayAt: ["a"], in: "{\"a\": [\"x\", \"y\", \"x\"]}")
        == "{\"a\": [\"y\"]}")
  }

  @Test func aLoneSurrogateEscapeIsValidAndItsBytesStay() throws {
    let text =
      "{\"cut\": \"\\ud83d\", \"low\": \"\\udc00x\", \"mixed\": \"\\ud83d\\u0041\", \"on\": false}"
    #expect(JSONText.isValid(text))
    #expect(
      JSONText.setBool(true, at: ["on"], in: text)
        == text.replacingOccurrences(of: "\"on\": false", with: "\"on\": true"))
    #expect(JSONText.hasMember(at: ["cut"], in: "{\"\\ud83d\": 1, \"\\udc00\": 2}") == false)
    #expect(JSONText.hasMember(at: ["\u{FFFD}"], in: "{\"\\ud83d\": 1}") == true)
    #expect(!JSONText.isValid("{\"a\": \"\\ud83d\\u12G4\"}"))
  }

  @Test func aCompactFileStaysCompactWhenItEndsWithANewline() {
    #expect(
      JSONText.setBool(true, at: ["a", "b"], in: "{\"a\":{}}\n") == "{\"a\":{\"b\":true}}\n")
    #expect(
      JSONText.addString("x", toArrayAt: ["a"], in: "{\"a\":[]}\r\n") == "{\"a\":[\"x\"]}\r\n")
  }
}

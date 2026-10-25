import Foundation
@testable import SandboxHost

func runtimeJSONChecks() throws {
    func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: label, code: 1) }
    }
    let accepted: [(String, RuntimeJSON)] = [
        (" \t\r\n{\"array\":[null,true,false,0,-1,9007199254740991,-9007199254740991],\"empty\":{}} ",
         .object(["array": .array([.null, .bool(true), .bool(false), .integer(0), .integer(-1), .integer(RuntimeJSON.maxInteger), .integer(-RuntimeJSON.maxInteger)]), "empty": .object([:])])),
        (#""\"\\\/\b\f\n\r\t\u0041\u00e9\uD83D\uDE00""#, .string("\"\\/\u{8}\u{c}\n\r\tAé😀")),
        ("[]", .array([])), ("\"日本語\"", .string("日本語")),
    ]
    for (text, expected) in accepted {
        let value = try RuntimeJSON.parse(Data(text.utf8))
        try require(value == expected, "runtime JSON semantic value")
        try require(try value.validated() == expected, "runtime JSON bounded Codable round trip")
        try require(try JSONDecoder().decode(RuntimeJSON.self, from: JSONEncoder().encode(value)) == expected, "runtime JSON Codable preservation")
    }
    let object = try RuntimeJSON.parse(Data(#"{"a":["x",1]}"#.utf8))
    try require(object["a"]?.array?[0].string == "x" && object["a"]?.array?[1].integer == 1, "typed runtime accessors")
    try require(object.string == nil && object.array == nil && object.integer == nil && RuntimeJSON.null.object == nil, "mismatched runtime accessor")
    let malformed = ["", "{", "[", "{\"a\" 1}", "[1,]", "{\"a\":0,}", "true false", "tru", "nulX", "-", "-0", "01", "1.0", "1e0", "NaN", "9007199254740992", "-9007199254740992", "999999999999999999999999", "\"unterminated", "\"\\", "\"\\q\"", "\"\\u00G0\"", "\"\\u12\"", "\"\\uD800\"", "\"\\uD800\\u0041\"", "\"\\uDC00\"", "\"raw\nnewline\"", #"{"a":0,"\u0061":1}"#,
        String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9),
        "[" + Array(repeating: "0", count: 128).joined(separator: ",") + "]"]
    for text in malformed {
        do { _ = try RuntimeJSON.parse(Data(text.utf8)); throw NSError(domain: "accepted malformed runtime JSON", code: 1) }
        catch is AgentRuntimeProbe.Failure {}
    }
    for bytes in [Data([34, 255, 34]), Data(repeating: 32, count: RuntimeJSON.maxBytes + 1)] {
        do { _ = try RuntimeJSON.parse(bytes); throw NSError(domain: "accepted malformed runtime bytes", code: 1) }
        catch is AgentRuntimeProbe.Failure {}
    }
    do { _ = try JSONEncoder().encode(RuntimeJSON.integer(.max)); throw NSError(domain: "encoded unsafe integer", code: 1) }
    catch is AgentRuntimeProbe.Failure {}
    do { _ = try JSONDecoder().decode(RuntimeJSON.self, from: Data("1.5".utf8)); throw NSError(domain: "decoded fractional integer", code: 1) }
    catch is AgentRuntimeProbe.Failure {}
    print("PASS runtime JSON grammar, Unicode, exact integers, bounded decoding and Codable controls")
}

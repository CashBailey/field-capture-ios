// Port of test/sha256.test.ts
import XCTest

@testable import FieldContracts

final class Sha256Tests: XCTestCase {
    func testEmptyInput() {
        XCTAssertEqual(sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAbc() {
        XCTAssertEqual(sha256HexOfString("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testHelloWorld() {
        XCTAssertEqual(
            sha256HexOfString("hello world"), "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testTwoBlockMessage() {
        // 56 bytes forces padding into a second block.
        XCTAssertEqual(
            sha256HexOfString("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testBinaryInputAndMultiByteUtf8AreStable() {
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        func matches(_ s: String) -> Bool {
            hexPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches(sha256Hex(Data([0x00, 0xff, 0x10, 0x80]))))
        XCTAssertTrue(matches(sha256HexOfString("nappali — 灣鱷")))
        // Determinism: same input, same digest.
        XCTAssertEqual(sha256HexOfString("nappali — 灣鱷"), sha256HexOfString("nappali — 灣鱷"))
    }
}

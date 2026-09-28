// Port of apps/mobile/__tests__/native-image-capture.test.ts — the pure normalization parts
// (picker outcome → captured bytes/MIME/source mapping). The RN-module-mock-only assertions (the
// TS test's `expect(p.launchCamera).toHaveBeenCalledWith(expect.objectContaining({ mediaType:
// 'photo', quality: 0.8 }))`) have no Swift equivalent: `ImagePickerLike`'s methods take no
// options parameter (the real `UIImagePickerController` options are fixed inside the UIKit-only
// `UIKitImagePicker`, which isn't unit-testable without a simulator/device) — so those call-site
// option assertions are skipped, and only the outcome→result mapping this file actually owns is
// tested.
import XCTest

@testable import FieldAdapters

private final class FakeImagePicker: ImagePickerLike, @unchecked Sendable {
    var cameraOutcome: ImagePickerOutcome = .none
    var libraryOutcome: ImagePickerOutcome = .none
    private(set) var launchCameraCallCount = 0
    private(set) var launchImageLibraryCallCount = 0

    func launchCamera() async -> ImagePickerOutcome {
        launchCameraCallCount += 1
        return cameraOutcome
    }

    func launchImageLibrary() async -> ImagePickerOutcome {
        launchImageLibraryCallCount += 1
        return libraryOutcome
    }
}

final class NativeImageCaptureTests: XCTestCase {
    func test_capturesCameraImageBytesThroughNativeCameraPicker() async throws {
        let picker = FakeImagePicker()
        picker.cameraOutcome = .picked(PickedImageAsset(uri: "file:///camera/photo.jpg", type: "image/jpeg"))
        let deps = EvidenceImageCaptureDeps(
            imagePicker: picker,
            readBytes: { uri in
                XCTAssertEqual(uri, "file:///camera/photo.jpg")
                return Data([9, 8, 7])
            })

        let result = try await captureEvidenceImage(.camera, deps: deps)
        XCTAssertEqual(
            result,
            CapturedEvidenceImage(
                bytes: Data([9, 8, 7]), mimeType: "image/jpeg", source: .camera, localUri: "file:///camera/photo.jpg"))
        XCTAssertEqual(picker.launchCameraCallCount, 1)
    }

    func test_importsLibraryImageBytesAndInfersMimeTypeFromUri() async throws {
        let picker = FakeImagePicker()
        picker.libraryOutcome = .picked(PickedImageAsset(uri: "file:///library/receipt.png"))
        let deps = EvidenceImageCaptureDeps(imagePicker: picker, readBytes: { _ in Data([1, 2, 3]) })

        let result = try await captureEvidenceImage(.import, deps: deps)
        XCTAssertEqual(result?.mimeType, "image/png")
        XCTAssertEqual(result?.source, .import)
        XCTAssertEqual(result?.localUri, "file:///library/receipt.png")
        XCTAssertEqual(picker.launchImageLibraryCallCount, 1)
    }

    func test_returnsNilWhenNativePickerReportsPermissionDenial() async throws {
        let picker = FakeImagePicker()
        picker.cameraOutcome = .permissionDenied
        let result = try await captureEvidenceImage(
            .camera, deps: EvidenceImageCaptureDeps(imagePicker: picker, readBytes: { _ in Data() }))
        XCTAssertNil(result)
    }

    func test_returnsNilWhenUserCancelsNativePicker() async throws {
        let picker = FakeImagePicker()
        picker.libraryOutcome = .canceled
        let result = try await captureEvidenceImage(
            .import, deps: EvidenceImageCaptureDeps(imagePicker: picker, readBytes: { _ in Data() }))
        XCTAssertNil(result)
    }
}

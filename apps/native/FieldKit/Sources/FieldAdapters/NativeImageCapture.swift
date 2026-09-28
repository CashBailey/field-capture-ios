// Port of adapters/device/NativeImageCapture.ts — Capture/import one still image for field
// evidence. The native picker returns a local file URI; we read the bytes immediately and hand
// them to CaptureFlow, which hashes and persists them under the app's protected capture
// directory. Cancel/permission-denied returns nil: no fake evidence.
//
// The pure normalization logic (MIME inference, the capture flow driven by an injected picker
// seam) is platform-independent so `swift test` builds and runs it on macOS too. Only the
// production `UIImagePickerController` wiring needs UIKit, so it is isolated behind
// `#if canImport(UIKit)`.
//
// Deviation from the TS: `EvidenceImageSource` mirrors the TS type alias
// `Extract<CaptureSource, 'camera' | 'import'>`, kept local (rather than importing `FieldRuntime`'s
// full `CaptureSource` union) since `FieldAdapters` sits below `FieldRuntime` in the package graph.
import Foundation

/// Where a captured evidence image came from — mirrors the TS `EvidenceImageSource`.
public enum EvidenceImageSource: String, Equatable, Sendable {
    case camera
    case `import`
}

public struct CapturedEvidenceImage: Equatable, Sendable {
    public var bytes: Data
    public var mimeType: String
    public var source: EvidenceImageSource
    public var localUri: String

    public init(bytes: Data, mimeType: String, source: EvidenceImageSource, localUri: String) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.source = source
        self.localUri = localUri
    }
}

/// One asset the picker returned — mirrors the slice of the TS `ImagePickerResponse.assets[0]`
/// this code actually reads.
public struct PickedImageAsset: Equatable, Sendable {
    public var uri: String
    public var type: String?

    public init(uri: String, type: String? = nil) {
        self.uri = uri
        self.type = type
    }
}

/// What a native picker call resolved to — mirrors the TS `ImagePickerResponse`'s three observed
/// shapes (`didCancel`, `errorCode === 'permission'`, `assets[0]`).
public enum ImagePickerOutcome: Equatable, Sendable {
    case canceled
    case permissionDenied
    case picked(PickedImageAsset)
    /// Anything else the real picker could return (e.g. an empty `assets` array) — never
    /// fabricates evidence.
    case none
}

/// The native picker seam (`UIImagePickerController` in production) — mirrors the TS
/// `ImagePickerLike`.
public protocol ImagePickerLike: Sendable {
    func launchCamera() async -> ImagePickerOutcome
    func launchImageLibrary() async -> ImagePickerOutcome
}

public struct EvidenceImageCaptureDeps {
    public var imagePicker: ImagePickerLike?
    public var readBytes: ((String) async throws -> Data)?

    public init(imagePicker: ImagePickerLike? = nil, readBytes: ((String) async throws -> Data)? = nil) {
        self.imagePicker = imagePicker
        self.readBytes = readBytes
    }
}

/// Best-effort MIME type from a file extension (mirrors the TS `mimeFromUri`).
public func mimeFromUri(_ uri: String) -> String {
    let clean =
        (uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? uri)
        .lowercased()
    if clean.hasSuffix(".png") { return "image/png" }
    if clean.hasSuffix(".webp") { return "image/webp" }
    if clean.hasSuffix(".gif") { return "image/gif" }
    if clean.hasSuffix(".heic") { return "image/heic" }
    if clean.hasSuffix(".heif") { return "image/heif" }
    return "image/jpeg"
}

private func readFileBytes(_ uri: String) async throws -> Data {
    let path = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

#if canImport(UIKit)
    @MainActor private func defaultImagePicker() -> ImagePickerLike? { UIKitImagePicker() }
#else
    @MainActor private func defaultImagePicker() -> ImagePickerLike? { nil }
#endif

/// Capture/import one still image for field evidence. The native picker returns a local file URI;
/// we read the bytes immediately and hand them to CaptureFlow, which hashes and persists them
/// under the app's protected capture directory. Cancel/permission-denied returns nil: no fake
/// evidence.
public func captureEvidenceImage(
    _ source: EvidenceImageSource,
    deps: EvidenceImageCaptureDeps = EvidenceImageCaptureDeps()
) async throws -> CapturedEvidenceImage? {
    let resolvedPicker: ImagePickerLike?
    if let injected = deps.imagePicker {
        resolvedPicker = injected
    } else {
        resolvedPicker = await defaultImagePicker()
    }
    guard let picker = resolvedPicker else { return nil }
    let outcome = source == .camera ? await picker.launchCamera() : await picker.launchImageLibrary()

    guard case .picked(let asset) = outcome else { return nil }
    if let type = asset.type, !type.hasPrefix("image/") { return nil }

    let bytes = try await (deps.readBytes ?? readFileBytes)(asset.uri)
    return CapturedEvidenceImage(
        bytes: bytes,
        mimeType: asset.type ?? mimeFromUri(asset.uri),
        source: source,
        localUri: asset.uri
    )
}

#if canImport(UIKit)
    import UIKit
    import AVFoundation

    /// Production picker: `UIImagePickerController`, wrapped as `ImagePickerLike`. Presents from the
    /// foreground key window's root view controller and resolves once the delegate fires.
    @MainActor
    public final class UIKitImagePicker: NSObject, ImagePickerLike {
        public override init() { super.init() }

        public func launchCamera() async -> ImagePickerOutcome {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .permissionDenied }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .video) else { return .permissionDenied }
            default:
                return .permissionDenied
            }
            return await present(sourceType: .camera)
        }

        public func launchImageLibrary() async -> ImagePickerOutcome {
            // UIImagePickerController's `.photoLibrary` source runs out-of-process and needs no Photos
            // permission (unlike PHPickerViewController's full-library variants).
            await present(sourceType: .photoLibrary)
        }

        private func present(sourceType: UIImagePickerController.SourceType) async -> ImagePickerOutcome {
            guard let presenter = Self.topViewController() else { return .none }
            return await withCheckedContinuation { (continuation: CheckedContinuation<ImagePickerOutcome, Never>) in
                let picker = UIImagePickerController()
                picker.sourceType = sourceType
                let delegate = PickerDelegate { outcome in continuation.resume(returning: outcome) }
                picker.delegate = delegate
                objc_setAssociatedObject(picker, &PickerDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
                presenter.present(picker, animated: true)
            }
        }

        private static func topViewController() -> UIViewController? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?.rootViewController
        }
    }

    private final class PickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        static var associatedKey = 0
        private let completion: (ImagePickerOutcome) -> Void
        private var completed = false

        init(_ completion: @escaping (ImagePickerOutcome) -> Void) {
            self.completion = completion
        }

        private func finish(_ outcome: ImagePickerOutcome, _ picker: UIImagePickerController) {
            guard !completed else { return }
            completed = true
            picker.dismiss(animated: true)
            completion(outcome)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finish(.canceled, picker)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.8)
            else {
                finish(.none, picker)
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            do {
                try data.write(to: url)
                finish(.picked(PickedImageAsset(uri: url.absoluteString, type: "image/jpeg")), picker)
            } catch {
                finish(.none, picker)
            }
        }
    }
#endif

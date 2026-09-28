import Foundation

/// Durable storage for finalized printer bytes, keyed by the job that owns them.
public protocol PrintPayloadStore: AnyObject {
    func put(_ printJobId: String, _ bytes: Data) throws
    func get(_ printJobId: String) throws -> Data?
    func delete(_ printJobId: String) throws
}

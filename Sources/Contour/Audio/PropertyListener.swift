import CoreAudio
import Foundation

/// Adds an AudioObject property listener for as long as this object lives.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init(object: AudioObjectID,
         address: AudioObjectPropertyAddress,
         queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

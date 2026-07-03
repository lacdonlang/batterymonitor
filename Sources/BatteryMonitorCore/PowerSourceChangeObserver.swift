import Foundation
import IOKit.ps

public protocol PowerSourceChangeObserving: Sendable {
    func start()
    func stop()
}

public final class PowerSourceChangeObserver: PowerSourceChangeObserving, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var runLoopSource: CFRunLoopSource?

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        guard runLoopSource == nil else {
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }
            let observer = Unmanaged<PowerSourceChangeObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            observer.onChange()
        }, context)?.takeRetainedValue() else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    public func stop() {
        guard let runLoopSource else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        self.runLoopSource = nil
    }
}

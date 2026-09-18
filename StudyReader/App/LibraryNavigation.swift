import SwiftUI

/// Article changes wait for the outgoing reader's checkpoint. Compact navigation must be
/// committed with that selection, rather than letting a NavigationLink push before it exists.
@MainActor final class LibraryNavigation: ObservableObject {
    @Published private(set) var selectedID: UUID?
    @Published var compactColumn: NavigationSplitViewColumn = .sidebar
    private var request = UUID()

    @discardableResult
    func select(_ id: UUID?, opensReader: Bool = false,
                prepare: @escaping @MainActor () async -> Void,
                activate: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        let request = UUID()
        self.request = request
        guard id != selectedID else {
            activate()
            if opensReader, id != nil { compactColumn = .detail }
            return nil
        }
        return Task { @MainActor in
            await prepare()
            guard self.request == request else { return }
            activate()
            selectedID = id
            if opensReader, id != nil { compactColumn = .detail }
            else if id == nil, compactColumn == .detail { compactColumn = .content }
        }
    }
}

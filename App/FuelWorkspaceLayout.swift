import Foundation

/// Single layout seam for the fuel workspace (issue #6).
///
/// Today exactly one implementation ships: `CompactSinglePaneFuelWorkspaceLayout`,
/// the compact single-pane layout every iPhone currently uses. The seam exists
/// so a *future* iPhone Duo adapter can introduce a second surface (a persistent
/// quick-log companion pane, spanned ledger/trends) without any screen having to
/// learn about fold hardware. No fold APIs are referenced or stubbed anywhere in
/// this repo — see `docs/dual-screen.md` for the adapter contract.
enum WorkspaceKind: String, Sendable {
    /// Single compact pane; all content lives in one surface (today's behavior).
    case compactSinglePane
    /// Reserved for the future dual-screen companion layout. No shipped
    /// implementation exists; adding one requires the contract in
    /// `docs/dual-screen.md` to be satisfied first.
    case compactDualScreenCompanion
}

protocol FuelWorkspaceLayout: Sendable {
    var workspaceKind: WorkspaceKind { get }
}

/// The only shipped implementation: everything stays in a single compact pane.
struct CompactSinglePaneFuelWorkspaceLayout: FuelWorkspaceLayout {
    let workspaceKind: WorkspaceKind = .compactSinglePane

    init() {}
}

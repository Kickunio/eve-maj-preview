//! Whether a thumbnail is shown, or hidden by hand or automatically.
pub const VisibilityState = enum {
    visible,
    /// Auto-hidden via hideWhenNoEveFocus; can be auto-shown again.
    hidden_automatic,
    /// Persists until the user manually toggles it again.
    hidden_manual,

    pub fn isVisible(self: VisibilityState) bool {
        return self == .visible;
    }
};

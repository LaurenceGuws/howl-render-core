//! Responsibility: own shared atlas math for the render-core text stack.
//! Ownership: render-core text stack.
//! Reason: keep atlas index math and bounds logic out of backend roots.

/// Text-atlas layout contract shared by backend owners.
pub const AtlasLayout = struct {
    cell_w: u16,
    cell_h: u16,
    slot_stride: usize,
    max_slots: u32,
};

/// Return the atlas slice for one slot when it is in bounds.
pub fn slotSlice(layout: AtlasLayout, atlas: []u8, slot: u32) ?[]u8 {
    if (slot >= layout.max_slots) return null;
    const slot_index = @as(usize, slot) * layout.slot_stride;
    if (slot_index + layout.slot_stride > atlas.len) return null;
    return atlas[slot_index .. slot_index + layout.slot_stride];
}

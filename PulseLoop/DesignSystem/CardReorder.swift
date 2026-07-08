import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Home-screen-style card reordering: long-press a card to enter an "edit" mode where
// the cards wiggle and can be dragged to new positions. The model reorders live as a
// dragged card hovers a new slot; the caller persists the final order.

// MARK: - Wiggle

private struct WiggleModifier: ViewModifier {
    let active: Bool
    /// Small per-card phase offset so cards don't wiggle in lockstep.
    let phase: Double
    @State private var swing = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (swing ? 1.4 : -1.4) : 0))
            .animation(
                active
                    ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(phase)
                    : .easeOut(duration: 0.15),
                value: swing
            )
            .onChange(of: active) { _, now in swing = now }
            .onAppear { if active { swing = true } }
    }
}

extension View {
    /// Adds the edit-mode wiggle. `phase` (0…0.12) desynchronizes neighboring cards.
    func wiggling(active: Bool, phase: Double = 0) -> some View {
        modifier(WiggleModifier(active: active, phase: phase))
    }
}

// MARK: - ReorderableForEach

/// Live-reordering `ForEach` for a `LazyVGrid` or `VStack`. While `isEditing`, each item
/// wiggles, its own taps are disabled (so a tap can't navigate), and it can be dragged;
/// hovering over another item reorders the model immediately via `move(from:to:)`.
struct ReorderableForEach<Item: Hashable, Content: View>: View {
    let items: [Item]
    let isEditing: Bool
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element) { index, item in
            // Inner card is disabled in edit mode so its button can't fire; the drag/drop
            // lives on the enclosing container, which stays interactive.
            ZStack {
                content(item).disabled(isEditing)
            }
            .wiggling(active: isEditing, phase: Double(index % 4) * 0.03)
            .opacity(dragging == item && isEditing ? 0.55 : 1)
            .modifier(DragDropModifier(
                item: item, items: items, isEditing: isEditing,
                dragging: $dragging, move: move, preview: { content(item) }
            ))
        }
    }
}

private struct DragDropModifier<Item: Hashable, Preview: View>: ViewModifier {
    let item: Item
    let items: [Item]
    let isEditing: Bool
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if isEditing {
            content
                .onDrag {
                    dragging = item
                    return NSItemProvider(object: String(describing: item.hashValue) as NSString)
                } preview: {
                    preview() // clean, un-wiggled snapshot under the finger
                }
                .onDrop(of: [.text], delegate: ReorderDropDelegate(
                    item: item, items: items, dragging: $dragging, move: move
                ))
        } else {
            content
        }
    }
}

private struct ReorderDropDelegate<Item: Hashable>: DropDelegate {
    let item: Item
    let items: [Item]
    @Binding var dragging: Item?
    let move: (_ from: Int, _ to: Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = items.firstIndex(of: dragging),
              let to = items.firstIndex(of: item), from != to else { return }
        move(from, to)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func dropUpdated(info: DropInfo) -> DropProposal { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

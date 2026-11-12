//
//  DropInteractionState.swift
//  boringNotch
//

import Observation

@Observable
final class DropInteractionState {
    var dragDetectorTargeting = false
    var generalDropTargeting = false
    var dropZoneTargeting = false
    var dropEvent = false
    // Both the AppKit detector and SwiftUI drop targets use this signal.
    var dragOpenGeneration = 0

    var anyDropZoneTargeting: Bool {
        dragDetectorTargeting || generalDropTargeting || dropZoneTargeting
    }
}

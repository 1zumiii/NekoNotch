//
//  CustomBuild.swift
//  boringNotch
//

/// This is a customised build of Boring Notch. An official release installed
/// over it would silently remove the changes, so the updater is switched off:
/// it is never started, and every update control is disabled.
/// To pick up upstream changes, merge them into the fork and rebuild.
enum CustomBuild {
    static let updatesDisabled = true

    /// Shown on the About page instead of the upstream release name and version.
    /// The bundle's own version stays that of the upstream release it is
    /// based on, so merging upstream never has to touch the project file.
    static let releaseName = "Izumi Edition ✨"
    static let version = "1.1.0"
}

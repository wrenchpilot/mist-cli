//
//  InstallerCreator.swift
//  Mist
//
//  Created by Nindi Gill on 11/3/21.
//

import Foundation

/// Helper Struct used to install macOS Installers.
enum InstallerCreator {
    // swiftlint:disable function_body_length

    /// Creates a recently downloaded macOS Installer.
    ///
    /// - Parameters:
    ///   - installer: The selected macOS Installer that was downloaded.
    ///   - options:   Download options for macOS Installers.
    ///
    /// - Throws: A `MistError` if the downloaded macOS Installer fails to install.
    static func create(_ installer: Installer, options: DownloadInstallerOptions) throws {
        !options.quiet ? PrettyPrint.printHeader("INSTALL", noAnsi: options.noAnsi) : Mist.noop()

        let imageURL: URL = DownloadInstallerCommand.temporaryImage(for: installer, options: options)
        let temporaryURL: URL = .init(fileURLWithPath: DownloadInstallerCommand.temporaryDirectory(for: installer, options: options))

        if FileManager.default.fileExists(atPath: imageURL.path) {
            !options.quiet ? PrettyPrint.print("Deleting old image '\(imageURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
            try FileManager.default.removeItem(at: imageURL)
        }

        !options.quiet ? PrettyPrint.print("Creating image '\(imageURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
        var arguments: [String] = ["hdiutil", "create", "-fs", "HFS+", "-layout", "SPUD", "-size", "\(installer.diskImageSize)g", "-volname", installer.identifier, imageURL.path]
        _ = try Shell.execute(arguments)

        // Clean up any stale mounts before mounting (uses robust cleanup with retries and diskutil fallback)
        Generator.cleanupStaleMounts(for: installer, quiet: options.quiet, noAnsi: options.noAnsi)

        !options.quiet ? PrettyPrint.print("Mounting disk image at mount point '\(installer.temporaryDiskImageMountPointURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
        arguments = ["hdiutil", "attach", imageURL.path, "-noverify", "-nobrowse", "-mountpoint", installer.temporaryDiskImageMountPointURL.path]
        _ = try Shell.execute(arguments)

        if
            installer.sierraOrOlder,
            let package: Package = installer.packages.first {
            let legacyDiskImageURL: URL = temporaryURL.appendingPathComponent(package.filename)
            let legacyDiskImageMountPointURL: URL = .init(fileURLWithPath: "/Volumes/Install \(installer.name)")
            let packageURL: URL = .init(fileURLWithPath: "/Volumes/Install \(installer.name)").appendingPathComponent(package.filename.replacingOccurrences(of: ".dmg", with: ".pkg"))

            !options.quiet ? PrettyPrint.print("Mounting Installer disk image at mount point '\(legacyDiskImageMountPointURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["hdiutil", "attach", legacyDiskImageURL.path, "-noverify", "-nobrowse", "-mountpoint", legacyDiskImageMountPointURL.path]
            _ = try Shell.execute(arguments)

            !options.quiet ? PrettyPrint.print("Creating Installer in disk image at mount point '\(legacyDiskImageMountPointURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["installer", "-pkg", packageURL.path, "-target", installer.temporaryDiskImageMountPointURL.path]
            let variables: [String: String] = ["CM_BUILD": "CM_BUILD"]
            _ = try Shell.execute(arguments, environment: variables)

            !options.quiet ? PrettyPrint.print("Unmounting Installer disk image at mount point '\(legacyDiskImageMountPointURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()
            let arguments: [String] = ["hdiutil", "detach", legacyDiskImageMountPointURL.path, "-force"]
            _ = try Shell.execute(arguments)
        } else {
            !options.quiet ? PrettyPrint.print("Creating new installer '\(installer.temporaryInstallerURL.path)'...", noAnsi: options.noAnsi) : Mist.noop()

            if installer.containsInstallAssistantPackage {
                let installAssistantPackageURL: URL = temporaryURL.appendingPathComponent("InstallAssistant.pkg")
                arguments = ["installer", "-pkg", installAssistantPackageURL.path, "-target", installer.temporaryDiskImageMountPointURL.path]
                let variables: [String: String] = ["CM_BUILD": "CM_BUILD"]
                _ = try Shell.execute(arguments, environment: variables)
            } else {
                // macOS 15.6+ security changes prevent using distribution files with the installer command
                // Instead, we manually extract and assemble the installer app from the component packages
                try assembleInstallerManually(installer: installer, temporaryURL: temporaryURL, options: options)
            }
        }

        // temporary fix for applying correct posix permissions
        arguments = ["chmod", "-R", "755", installer.temporaryInstallerURL.path]
        _ = try Shell.execute(arguments)

        !options.quiet ? PrettyPrint.print("Created new installer '\(installer.temporaryInstallerURL.path)'", noAnsi: options.noAnsi) : Mist.noop()
    }

    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length

    /// Manually assembles a macOS Installer app by extracting component packages.
    ///
    /// This is necessary for macOS 15.6+ which introduced security changes (CVE-2025-43187)
    /// that prevent using distribution files with the installer command.
    ///
    /// - Parameters:
    ///   - installer: The selected macOS Installer being assembled.
    ///   - temporaryURL: The temporary directory containing downloaded packages.
    ///   - options: Download options for macOS Installers.
    ///
    /// - Throws: A `MistError` if assembly fails.
    private static func assembleInstallerManually(installer: Installer, temporaryURL: URL, options: DownloadInstallerOptions) throws {
        let tempExpansionURL: URL = temporaryURL.appendingPathComponent("_expansion")
        var arguments: [String]

        // Clean up any previous expansion directory
        if FileManager.default.fileExists(atPath: tempExpansionURL.path) {
            try FileManager.default.removeItem(at: tempExpansionURL)
        }
        try FileManager.default.createDirectory(at: tempExpansionURL, withIntermediateDirectories: true)

        // Step 1: Expand InstallAssistantAuto.pkg to get the installer app
        let installAssistantPkgURL: URL = temporaryURL.appendingPathComponent("InstallAssistantAuto.pkg")
        let appExpansionURL: URL = tempExpansionURL.appendingPathComponent("InstallAssistantAuto")

        !options.quiet ? PrettyPrint.print("Extracting installer app from InstallAssistantAuto.pkg...", noAnsi: options.noAnsi) : Mist.noop()
        arguments = ["pkgutil", "--expand-full", installAssistantPkgURL.path, appExpansionURL.path]
        _ = try Shell.execute(arguments)

        // Step 2: Copy the app to the target mount point
        let sourceAppURL: URL = appExpansionURL.appendingPathComponent("Payload/Install \(installer.name).app")
        let targetAppURL: URL = installer.temporaryDiskImageMountPointURL.appendingPathComponent("Applications/Install \(installer.name).app")
        let targetAppsDir: URL = installer.temporaryDiskImageMountPointURL.appendingPathComponent("Applications")

        if !FileManager.default.fileExists(atPath: targetAppsDir.path) {
            try FileManager.default.createDirectory(at: targetAppsDir, withIntermediateDirectories: true)
        }

        !options.quiet ? PrettyPrint.print("Copying installer app to disk image...", noAnsi: options.noAnsi) : Mist.noop()
        arguments = ["ditto", sourceAppURL.path, targetAppURL.path]
        _ = try Shell.execute(arguments)

        // Step 3: Expand InstallESDDmg.pkg to get InstallESD.dmg
        let installESDPkgURL: URL = temporaryURL.appendingPathComponent("InstallESDDmg.pkg")
        let esdExpansionURL: URL = tempExpansionURL.appendingPathComponent("InstallESDDmg")

        !options.quiet ? PrettyPrint.print("Extracting InstallESD.dmg from InstallESDDmg.pkg...", noAnsi: options.noAnsi) : Mist.noop()
        arguments = ["pkgutil", "--expand-full", installESDPkgURL.path, esdExpansionURL.path]
        _ = try Shell.execute(arguments)

        // Step 4: Set up SharedSupport directory
        let sharedSupportURL: URL = targetAppURL.appendingPathComponent("Contents/SharedSupport")

        // Step 5: Copy InstallESD.dmg to SharedSupport
        let sourceESDURL: URL = esdExpansionURL.appendingPathComponent("InstallESD.dmg")
        let targetESDURL: URL = sharedSupportURL.appendingPathComponent("InstallESD.dmg")

        !options.quiet ? PrettyPrint.print("Copying InstallESD.dmg to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
        arguments = ["ditto", sourceESDURL.path, targetESDURL.path]
        _ = try Shell.execute(arguments)

        // Step 6: Copy OSInstall.mpkg to SharedSupport
        let sourceMpkgURL: URL = temporaryURL.appendingPathComponent("OSInstall.mpkg")
        let targetMpkgURL: URL = sharedSupportURL.appendingPathComponent("OSInstall.mpkg")

        if FileManager.default.fileExists(atPath: sourceMpkgURL.path) {
            !options.quiet ? PrettyPrint.print("Copying OSInstall.mpkg to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["ditto", sourceMpkgURL.path, targetMpkgURL.path]
            _ = try Shell.execute(arguments)
        }

        // Step 7: Copy BaseSystem files to SharedSupport
        let sourceBaseSystemDmgURL: URL = temporaryURL.appendingPathComponent("BaseSystem.dmg")
        let sourceBaseSystemChunklistURL: URL = temporaryURL.appendingPathComponent("BaseSystem.chunklist")

        if FileManager.default.fileExists(atPath: sourceBaseSystemDmgURL.path) {
            !options.quiet ? PrettyPrint.print("Copying BaseSystem.dmg to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["ditto", sourceBaseSystemDmgURL.path, sharedSupportURL.appendingPathComponent("BaseSystem.dmg").path]
            _ = try Shell.execute(arguments)
        }

        if FileManager.default.fileExists(atPath: sourceBaseSystemChunklistURL.path) {
            !options.quiet ? PrettyPrint.print("Copying BaseSystem.chunklist to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["ditto", sourceBaseSystemChunklistURL.path, sharedSupportURL.appendingPathComponent("BaseSystem.chunklist").path]
            _ = try Shell.execute(arguments)
        }

        // Step 8: Copy AppleDiagnostics files to SharedSupport
        let sourceAppleDiagnosticsDmgURL: URL = temporaryURL.appendingPathComponent("AppleDiagnostics.dmg")
        let sourceAppleDiagnosticsChunklistURL: URL = temporaryURL.appendingPathComponent("AppleDiagnostics.chunklist")

        if FileManager.default.fileExists(atPath: sourceAppleDiagnosticsDmgURL.path) {
            !options.quiet ? PrettyPrint.print("Copying AppleDiagnostics.dmg to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["ditto", sourceAppleDiagnosticsDmgURL.path, sharedSupportURL.appendingPathComponent("AppleDiagnostics.dmg").path]
            _ = try Shell.execute(arguments)
        }

        if FileManager.default.fileExists(atPath: sourceAppleDiagnosticsChunklistURL.path) {
            !options.quiet ? PrettyPrint.print("Copying AppleDiagnostics.chunklist to SharedSupport...", noAnsi: options.noAnsi) : Mist.noop()
            arguments = ["ditto", sourceAppleDiagnosticsChunklistURL.path, sharedSupportURL.appendingPathComponent("AppleDiagnostics.chunklist").path]
            _ = try Shell.execute(arguments)
        }

        // Clean up expansion directory
        try? FileManager.default.removeItem(at: tempExpansionURL)
    }

    // swiftlint:enable function_body_length
}

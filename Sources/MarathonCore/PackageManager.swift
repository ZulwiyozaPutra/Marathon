/**
 *  Marathon
 *  Copyright (c) John Sundell 2017
 *  Licensed under the MIT license. See LICENSE file.
 */

import Foundation
import Files
import Wrap
import Unbox

// MARK: - Error

public enum PackageManagerError {
    case failedToResolveLatestVersion(URL)
    case packageAlreadyAdded(String)
    case failedToSavePackageFile(String, Folder)
    case failedToReadPackageFile(String)
    case failedToUpdatePackages(Folder)
    case unknownPackageForRemoval(String)
    case failedToRemovePackage(String, Folder)
    case failedToReadMarathonFile(File)
}

extension PackageManagerError: PrintableError {
    public var message: String {
        switch self {
        case .failedToResolveLatestVersion(let url):
            return "Could not resolve the latest version for package at '\(url)'"
        case .packageAlreadyAdded(let name):
            return "A package named '\(name)' has already been added"
        case .failedToSavePackageFile(let name, _):
            return "Could not save file for package '\(name)'"
        case .failedToReadPackageFile(let name):
            return "Could not read file for package '\(name)'"
        case .failedToUpdatePackages(_):
            return "Failed to update packages"
        case .unknownPackageForRemoval(let name):
            return "Cannot remove package '\(name)' - no such package has been added"
        case .failedToRemovePackage(let name, _):
            return "Could not remove package '\(name)'"
        case .failedToReadMarathonFile(let file):
            return "Incorrectly formatted Marathonfile at '\(file.path)'"
        }
    }

    public var hint: String? {
        switch self {
        case .failedToResolveLatestVersion(let url):
            var hint = "Make sure that the package you're trying to add is reachable, and has at least one tagged release"

            if !url.isRemote {
                hint += "\nYou can make a release by using 'git tag <version>' in your package's repository"
            }

            return hint
        case .packageAlreadyAdded(let name):
            return "Did you mean to update it? If so, run 'marathon update'\n" +
                   "You can also remove the existing package using 'marathon remove \(name)', and then run 'add' again"
        case .failedToSavePackageFile(_, let folder):
            return "Make sure you have write permissions to the folder '\(folder.path)'"
        case .failedToReadPackageFile(let name):
            return "The file may have become corrupted. Try removing the package using 'marathon remove \(name)' and then add it back again"
        case .failedToUpdatePackages(let folder):
            return "Make sure you have write permissions to the folder '\(folder.path)'"
        case .unknownPackageForRemoval(_):
            return "Did you mean to remove the cache data for a script? If so, add '.swift' to its path\n" +
                   "To list all added packages run 'marathon list'"
        case .failedToRemovePackage(_, let folder):
            return "Make sure you have write permissions to the folder '\(folder.path)'"
        case .failedToReadMarathonFile(_):
            return "Ensure that the file is formatted according to the documentation at https://github.com/johnsundell/marathon"
        }
    }
}

// MARK: - PackageManager

internal final class PackageManager {
    private typealias Error = PackageManagerError

    var addedPackages: [Package] { return makePackageList() }

    private let folder: Folder
    private let generatedFolder: Folder
    private var masterPackageName: String { return "MARATHON_PACKAGES" }

    // MARK: - Init

    init(folder: Folder) throws {
        self.folder = folder
        self.generatedFolder = try folder.createSubfolderIfNeeded(withName: "Generated")
    }

    // MARK: - API

    @discardableResult func addPackage(at url: URL, throwIfAlreadyAdded: Bool = true) throws -> Package {
        let name = nameForPackage(at: url)

        if throwIfAlreadyAdded {
            guard (try? folder.file(named: name)) == nil else {
                throw Error.packageAlreadyAdded(name)
            }
        }

        let latestVersion = try latestMajorVersionForPackage(at: url)
        let package = Package(name: name, url: url, majorVersion: latestVersion)
        try save(package: package)
        try updatePackages()
        return package
    }

    func addPackages(fromMarathonFile file: File) throws {
        let fileContent = try perform(file.readAsString().components(separatedBy: .newlines),
                                      orThrow: Error.failedToReadMarathonFile(file))

        for urlString in fileContent {
            guard !urlString.isEmpty else {
                continue
            }

            guard let url = URL(string: urlString) else {
                throw Error.failedToReadMarathonFile(file)
            }

            try addPackage(at: url, throwIfAlreadyAdded: false)
        }
    }

    func removePackage(named name: String) throws -> Package {
        let packageFile = try perform(folder.file(named: name), orThrow: Error.unknownPackageForRemoval(name))
        let package = try perform(unbox(data: packageFile.read()) as Package,
                                  orThrow: Error.failedToReadPackageFile(name))

        do {
            let packageFolderPrefix = (name + "-\(package.majorVersion)").lowercased()

            for packageFolder in try generatedFolder.subfolder(named: "Packages").subfolders {
                guard packageFolder.name.lowercased().hasPrefix(packageFolderPrefix) else {
                    continue
                }

                try packageFolder.delete()
                break
            }

            try packageFile.delete()
        } catch {
            throw Error.failedToRemovePackage(name, folder)
        }

        return package
    }

    func makePackageDescription(for script: Script) throws -> String {
        guard let masterDescription = try? generatedFolder.file(named: "Package.swift").readAsString() else {
            try updatePackages()
            return try makePackageDescription(for: script)
        }

        return masterDescription.replacingOccurrences(of: masterPackageName, with: script.name)
    }

    func symlinkPackages(to folder: Folder) throws {
        guard let packagesFolder = try? generatedFolder.subfolder(named: "Packages") else {
            try updatePackages()
            return try symlinkPackages(to: folder)
        }

        guard (try? folder.subfolder(named: "Packages")) == nil else {
            return
        }

        try folder.createSymlink(to: packagesFolder.path, at: "Packages")
    }

    func updateAllPackagesToLatestMajorVersion() throws {
        for var package in addedPackages {
            let latestMajorVersion = try latestMajorVersionForPackage(at: package.url)

            guard latestMajorVersion > package.majorVersion else {
                continue
            }

            package.majorVersion = latestMajorVersion
            try save(package: package)
        }

        try updatePackages()
    }

    // MARK: - Private

    private func latestMajorVersionForPackage(at url: URL) throws -> Int {
        if url.isRemote {
            return try latestMajorVersionForRemotePackage(at: url)
        }

        return try lastestMajorVersionForLocalPackage(at: url)
    }

    private func latestMajorVersionForRemotePackage(at url: URL) throws -> Int {
        let command = "git ls-remote --tags \(url.absoluteString)"
        let tags = try perform(Process().launchBash(withCommand: command),
                                  orThrow: Error.failedToResolveLatestVersion(url))

        guard let latestTag = tags.components(separatedBy: "\n").last else {
            throw Error.failedToResolveLatestVersion(url)
        }

        guard let versionString = latestTag.components(separatedBy: "refs/tags/").last else {
            throw Error.failedToResolveLatestVersion(url)
        }

        guard let majorVersion = majorVersion(from: versionString) else {
            throw Error.failedToResolveLatestVersion(url)
        }

        return majorVersion
    }

    private func lastestMajorVersionForLocalPackage(at url: URL) throws -> Int {
        let command = "cd \(url.absoluteString) && git tag"
        let tags = try perform(Process().launchBash(withCommand: command),
                                  orThrow: Error.failedToResolveLatestVersion(url))

        guard let latestTag = tags.components(separatedBy: "\n").last else {
            throw Error.failedToResolveLatestVersion(url)
        }

        guard let majorVersion = majorVersion(from: latestTag) else {
            throw Error.failedToResolveLatestVersion(url)
        }

        return majorVersion
    }

    private func nameForPackage(at url: URL) -> String {
        let urlComponents = url.absoluteString.components(separatedBy: "/")
        let lastComponent = urlComponents.last!

        if url.isRemote {
            return lastComponent.components(separatedBy: ".git").first!
        }

        guard !lastComponent.isEmpty else {
            return urlComponents[urlComponents.count - 2]
        }

        return lastComponent
    }

    private func majorVersion(from string: String) -> Int? {
        return string.components(separatedBy: ".").first.flatMap({ Int($0) })
    }

    private func save(package: Package) throws {
        try perform(folder.createFile(named: package.name, contents: wrap(package)),
                    orThrow: Error.failedToSavePackageFile(package.name, folder))
    }

    private func updatePackages() throws {
        do {
            try generateMasterPackageDescription()
            try generatedFolder.moveToAndPerform(command: "swift package update")
            try generatedFolder.createSubfolderIfNeeded(withName: "Packages")
        } catch {
            throw Error.failedToUpdatePackages(folder)
        }
    }

    private func generateMasterPackageDescription() throws {
        var description = "import PackageDescription\n\n" +
                          "let package = Package(\n" +
                          "    name: \"\(masterPackageName)\",\n" +
                          "    dependencies: [\n"

        for (index, file) in folder.files.enumerated() {
            let name = file.nameExcludingExtension
            let package = try perform(unbox(data: file.read()) as Package,
                                      orThrow: Error.failedToReadPackageFile(name))

            if index > 0 {
                description += ",\n"
            }

            description += "        " + package.dependencyString
        }

        description += "\n    ]\n)"

        try generatedFolder.createFile(named: "Package.swift",
                                       contents: description.data(using: .utf8)!)
    }

    private func makePackageList() -> [Package] {
        return folder.files.flatMap { file in
            return try? unbox(data: file.read())
        }
    }
}

// MARK: - Utilities

private extension URL {
    var isRemote: Bool {
        return absoluteString.hasSuffix(".git")
    }
}

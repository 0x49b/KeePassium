//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit

public enum FileKeeperError: LocalizedError {
    case openError(reason: String)
    case importError(reason: String)
    case removalError(reason: String)
    public var errorDescription: String? {
        switch self {
        case .openError(let reason):
            return String.localizedStringWithFormat(
                LString.Error.failedToOpenFileReasonTemplate,
                reason)
        case .importError(let reason):
            return String.localizedStringWithFormat(
                LString.Error.failedToImportFileReasonTemplate,
                reason)
        case .removalError(let reason):
            return String.localizedStringWithFormat(
                LString.Error.failedToDeleteFileReasonTemplate,
                reason)
        }
    }
}

public protocol FileKeeperDelegate: AnyObject {
    func shouldResolveImportConflict(
        target: URL,
        handler: @escaping (FileKeeper.ConflictResolution) -> Void
    )
}

public class FileKeeper {
    public static let shared = FileKeeper()
    
    public weak var delegate: FileKeeperDelegate?
    
    public enum ConflictResolution {
        case ask
        case abort
        case rename
        case overwrite
    }

    private enum UserDefaultsKey {
        static let documentsDirURLReference = "documentsDirURLReference"
        
        static var mainAppPrefix: String {
            if BusinessModel.type == .prepaid {
                return "com.keepassium.pro.recentFiles"
            } else {
                return "com.keepassium.recentFiles"
            }
        }

        static var autoFillExtensionPrefix: String {
            if FileKeeper.platformSupportsSharedReferences {
                return mainAppPrefix
            }
            
            if BusinessModel.type == .prepaid {
                return "com.keepassium.pro.autoFill.recentFiles"
            } else {
                return "com.keepassium.autoFill.recentFiles"
            }
        }
        
        static let internalDatabases = ".internal.databases"
        static let internalKeyFiles = ".internal.keyFiles"
        static let externalDatabases = ".external.databases"
        static let externalKeyFiles = ".external.keyFiles"
    }
    
    public static let platformSupportsSharedReferences: Bool = {
        if ProcessInfo.isRunningOnMac {
            return false 
        }
        
        if #available(iOS 14, *) {
            return true
        } else {
            return false
        }
    }()
    
    public static var canAccessAppSandbox: Bool {
        if platformSupportsSharedReferences {
            return true
        } else {
            return AppGroup.isMainApp
        }
    }
    
    private static let documentsDirectoryName = "Documents"
    private static let inboxDirectoryName = "Inbox"
    private static let backupDirectoryName = "Backup"
    
    public enum OpenMode {
        case openInPlace
        case `import`
    }
    
    fileprivate let docDirURL: URL
    fileprivate let backupDirURL: URL
    fileprivate let inboxDirURL: URL
    
    fileprivate var referenceCache = ReferenceCache()

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.keepassium.FileKeeper"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 8
        return queue
    }()
    
    private init() {
        docDirURL = FileKeeper.getDocumentsDirectoryURL().standardizedFileURL
        inboxDirURL = docDirURL.appendingPathComponent(
            FileKeeper.inboxDirectoryName,
            isDirectory: true)
            .standardizedFileURL

        print("\nDoc dir: \(docDirURL)\n")
        
        guard let sharedContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.id) else { fatalError() }
        
        let _backupDirURL = sharedContainerURL.appendingPathComponent(
            FileKeeper.backupDirectoryName,
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: _backupDirURL,
                withIntermediateDirectories: true,
                attributes: nil)
        } catch {
            Diag.warning("Failed to create backup directory")
        }
        self.backupDirURL = _backupDirURL.standardizedFileURL
        
        deleteExpiredBackupFiles(completion: nil)
    }

    private static func getDocumentsDirectoryURL() -> URL {
        let dirFromFileManager = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!  
            .standardizedFileURL
        if AppGroup.isMainApp {
            storeURL(
                dirFromFileManager,
                location: .internalDocuments,
                key: UserDefaultsKey.documentsDirURLReference
            )
            return dirFromFileManager
        } else {
            if platformSupportsSharedReferences {
                guard let docDirUrl = loadURL(key: UserDefaultsKey.documentsDirURLReference) else {
                    Diag.warning("AutoFill does not know the main app's documents directory. Launch the main app to fix this.")
                    return dirFromFileManager
                }
                return docDirUrl
            }
            return dirFromFileManager
        }
    }
    
    private static func storeURL(_ url: URL, location: URLReference.Location, key: String) {
        URLReference.create(for: url, location: location) { result in
            switch result {
            case .success(let urlRef):
                let data = urlRef.serialize()
                UserDefaults.appGroupShared.set(data, forKey: key)
            case .failure(let error):
                assertionFailure("This should not happen")
                Diag.warning("Failed to store URL reference [message: \(error.localizedDescription)]")
            }
        }
    }
    
    private static func loadURL(key: String) -> URL? {
        guard let urlReferenceData = UserDefaults.appGroupShared.data(forKey: key),
              let urlReference = URLReference.deserialize(from: urlReferenceData)
        else {
            return nil
        }
        do {
            let url = try urlReference.resolveSync() 
            return url
        } catch {
            Diag.error("Failed to resolve URL [message: \(error.localizedDescription)]")
            return nil
        }
    }
    
    
    fileprivate func getDirectory(for location: URLReference.Location) -> URL? {
        switch location {
        case .internalDocuments:
            return docDirURL
        case .internalBackup:
            return backupDirURL
        case .internalInbox:
            return inboxDirURL
        default:
            return nil
        }
    }
    
    public func getLocation(for filePath: URL) -> URLReference.Location {
        let path: String
        if filePath.isDirectory {
            path = filePath.standardizedFileURL.path
        } else {
            path = filePath.standardizedFileURL.deletingLastPathComponent().path
        }
        
        for candidateLocation in URLReference.Location.allInternal {
            guard let dirPath = getDirectory(for: candidateLocation)?.path else {
                assertionFailure()
                continue
            }
            if path == dirPath {
                return candidateLocation
            }
        }
        return .external
    }
    
    private func userDefaultsKey(for fileType: FileType, external isExternal: Bool) -> String {
        let keySuffix: String
        switch fileType {
        case .database:
            if isExternal {
                keySuffix = UserDefaultsKey.externalDatabases
            } else {
                keySuffix = UserDefaultsKey.internalDatabases
            }
        case .keyFile:
            if isExternal {
                keySuffix = UserDefaultsKey.externalKeyFiles
            } else {
                keySuffix = UserDefaultsKey.internalKeyFiles
            }
        }
        if AppGroup.isMainApp {
            return UserDefaultsKey.mainAppPrefix + keySuffix
        } else {
            return UserDefaultsKey.autoFillExtensionPrefix + keySuffix
        }
    }
    
    private func getStoredReferences(
        fileType: FileType,
        forExternalFiles isExternal: Bool
    ) -> [URLReference] {
        let key = userDefaultsKey(for: fileType, external: isExternal)
        guard let refsData = UserDefaults.appGroupShared.array(forKey: key) else {
            return []
        }
        var refs: [URLReference] = []
        for data in refsData {
            if let ref = URLReference.deserialize(from: data as! Data) {
                refs.append(ref)
            }
        }
        let result = referenceCache.update(with: refs, fileType: fileType, isExternal: isExternal)
        return result
    }
    
    
    private func storeReferences(
        _ refs: [URLReference],
        fileType: FileType,
        forExternalFiles isExternal: Bool
    ) {
        let serializedRefs = refs.map{ $0.serialize() }
        let key = userDefaultsKey(for: fileType, external: isExternal)
        UserDefaults.appGroupShared.set(serializedRefs, forKey: key)
    }

    private func findStoredExternalReferenceFor(url: URL, fileType: FileType) -> URLReference? {
        let storedRefs = getStoredReferences(fileType: fileType, forExternalFiles: true)
        for ref in storedRefs {
            let storedURL = ref.cachedURL ?? ref.bookmarkedURL
            if storedURL == url {
                return ref
            }
        }
        return nil
    }

    public func deleteFile(_ urlRef: URLReference, fileType: FileType, ignoreErrors: Bool) throws {
        Diag.debug("Will trash local file [fileType: \(fileType)]")
        do {
            let url = try urlRef.resolveSync() 
            try FileManager.default.removeItem(at: url)
            Diag.info("Local file deleted")
            FileKeeperNotifier.notifyFileRemoved(urlRef: urlRef, fileType: fileType)
        } catch {
            if ignoreErrors {
                Diag.debug("Suppressed file deletion error [message: '\(error.localizedDescription)']")
            } else {
                Diag.error("Failed to delete file [message: '\(error.localizedDescription)']")
                throw FileKeeperError.removalError(reason: error.localizedDescription)
            }
        }
    }
    
    @discardableResult
    public func removeExternalReference(_ urlRef: URLReference, fileType: FileType) -> Bool {
        Diag.debug("Removing URL reference [fileType: \(fileType)]")
        var refs = getStoredReferences(fileType: fileType, forExternalFiles: true)
        if let index = refs.firstIndex(of: urlRef) {
            refs.remove(at: index)
            storeReferences(refs, fileType: fileType, forExternalFiles: true)
            Diag.info("URL reference removed successfully")
            FileKeeperNotifier.notifyFileRemoved(urlRef: urlRef, fileType: fileType)
            return true
        } else {
            Diag.warning("Failed to remove URL reference - no such reference")
            return false
        }
    }
    
    public func getAllReferences(fileType: FileType, includeBackup: Bool) -> [URLReference] {
        var result: [URLReference] = []
        result.append(contentsOf:getStoredReferences(fileType: fileType, forExternalFiles: true))
        
        let internalDocumentFiles = scanLocalDirectory(docDirURL, fileType: fileType)
        result.append(contentsOf: internalDocumentFiles)

        if includeBackup {
            let backupFileRefs = scanLocalDirectory(backupDirURL, fileType: fileType)
            result.append(contentsOf: backupFileRefs)
        }
        return result
    }
    
    func scanLocalDirectory(_ dirURL: URL, fileType: FileType) -> [URLReference] {
        var refs: [URLReference] = []
        let location = getLocation(for: dirURL)
        assert(location != .external, "This should be used only on local directories.")
        
        let isIgnoreFileType = (location == .internalBackup)
        do {
            let dirContents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [])
            for url in dirContents {
                let isFileTypeMatch = isIgnoreFileType || FileType(for: url) == fileType
                if isFileTypeMatch && !url.isDirectory {
                    let urlRef = try URLReference(from: url, location: location)
                    refs.append(urlRef)
                }
            }
        } catch {
            Diag.error(error.localizedDescription)
        }
        let cachedRefs = referenceCache.update(with: refs, from: dirURL, fileType: fileType)
        return cachedRefs
    }
    
    public func addFile(
        url: URL,
        fileType: FileType?,
        mode: OpenMode,
        completionQueue: OperationQueue = .main,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        operationQueue.addOperation { [self] in
            self.addFileInBackground(
                url: url,
                fileType: fileType,
                openMode: mode,
                completionQueue: completionQueue,
                completion: completion
            )
        }
    }
    
    private func addFileInBackground(
        url: URL,
        fileType: FileType?,
        openMode: OpenMode,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        
        Diag.debug("Will add file [mode: \(openMode)]")
        
        guard url.isFileURL else {
            Diag.error("Failed to import non-file URL: \(url.redacted)")
            let messageNotAFileURL = LString.Error.notAFileURL
            let error: FileKeeperError
            switch openMode {
            case .import:
                error = FileKeeperError.importError(reason: messageNotAFileURL)
            case .openInPlace:
                error = FileKeeperError.openError(reason: messageNotAFileURL)
            }
            completionQueue.addOperation {
                completion(.failure(error))
            }
            return
        }
        
        
        let location = getLocation(for: url)
        let fileType = fileType ?? FileType(for: url)
        switch location {
        case .external:
            processExternalFile(
                url: url,
                fileType: fileType,
                openMode: openMode,
                completionQueue: completionQueue,
                completion: completion)
        case .internalDocuments, .internalBackup:
            processInternalFile(
                url: url,
                fileType: fileType,
                location: location,
                completionQueue: completionQueue,
                completion: completion)
        case .internalInbox:
            processInboxFile(
                url: url,
                fileType: fileType,
                location: location,
                completionQueue: completionQueue,
                completion: completion)
        }
    }
    
    
    private func maybeProcessExistingExternalFile(
        url sourceURL: URL,
        fileType: FileType,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) -> Bool {
        assert(operationQueue.isCurrent)
        guard let existingRef = findStoredExternalReferenceFor(url: sourceURL, fileType: fileType)
        else {
            return false 
        }
        
        guard existingRef.error == nil else {
            Diag.debug("Removing the old broken reference.")
            removeExternalReference(existingRef, fileType: fileType)
            return false 
        }

        if fileType == .database {
            Settings.current.startupDatabase = existingRef
        }
        Diag.info("Added already known external file, deduplicating.")
        FileKeeperNotifier.notifyFileAdded(urlRef: existingRef, fileType: fileType)
        completionQueue.addOperation {
            completion(.success(existingRef))
        }
        return true 
    }
    
    private func processExternalFile(
        url sourceURL: URL,
        fileType: FileType,
        openMode: OpenMode,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        let isProcessed = maybeProcessExistingExternalFile(
            url: sourceURL,
            fileType: fileType,
            completionQueue: completionQueue,
            completion: completion)
        guard !isProcessed else {
            return
        }
        
        switch openMode {
        case .openInPlace:
            addExternalFileRef(
                url: sourceURL,
                fileType: fileType,
                completionQueue: completionQueue,
                completion: { result in
                    assert(completionQueue.isCurrent)
                    switch result {
                    case .success(let urlRef):
                        Diag.info("External file added successfully")
                        FileKeeperNotifier.notifyFileAdded(urlRef: urlRef, fileType: fileType)
                        completion(.success(urlRef))
                    case .failure(let fileKeeperError):
                        completion(.failure(fileKeeperError))
                    }
                }
            )
        case .import:
            copyToDocumentsResolvingConflicts(
                from: sourceURL,
                fileProvider: nil, 
                completionQueue: completionQueue)
            {
                (result) in
                switch result {
                case .success(let url):
                    URLReference.create(for: url, location: self.getLocation(for: url)) {
                        (result) in
                        switch result {
                        case .success(let urlRef):
                            Diag.info("External file imported successfully")
                            FileKeeperNotifier.notifyFileAdded(urlRef: urlRef, fileType: fileType)
                            completionQueue.addOperation {
                                completion(.success(urlRef))
                            }
                        case .failure(let fileAccessError):
                            Diag.error("""
                                Failed to import external file [
                                    type: \(fileType),
                                    message: \(fileAccessError.localizedDescription),
                                    url: \(sourceURL.redacted)]
                                """)
                            let importError = FileKeeperError.importError(reason: fileAccessError.localizedDescription)
                            completionQueue.addOperation {
                                completion(.failure(importError))
                            }
                        }
                    }
                case .failure(let fileKeeperError):
                    assert(completionQueue.isCurrent)
                    completion(.failure(fileKeeperError))
                }
            }
        }
    }
    
    private func processInboxFile(
        url sourceURL: URL,
        fileType: FileType,
        location: URLReference.Location,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        copyToDocumentsResolvingConflicts(
            from: sourceURL,
            fileProvider: FileProvider.localStorage,
            completionQueue: operationQueue)
        {
            (moveResult) in
            switch moveResult {
            case .success(let url):
                URLReference.create(for: url, location: location) { refResult in
                    switch refResult {
                    case .success(let urlRef):
                        if fileType == .database {
                            Settings.current.startupDatabase = urlRef
                        }
                        Diag.info("Inbox file added successfully [fileType: \(fileType)]")
                        FileKeeperNotifier.notifyFileAdded(urlRef: urlRef, fileType: fileType)
                        completionQueue.addOperation {
                            completion(.success(urlRef))
                        }
                    case .failure(let fileAccessError):
                        Diag.error("Failed to import inbox file [type: \(fileType), message: \(fileAccessError.localizedDescription)]")
                        let importError = FileKeeperError.importError(reason: fileAccessError.localizedDescription)
                        completionQueue.addOperation {
                            completion(.failure(importError))
                        }
                    }
                    
                }
            case .failure(let fileAccessError):
                completionQueue.addOperation {
                    completion(.failure(fileAccessError))
                }
            }
        }
    }
    
    private func processInternalFile(
        url sourceURL: URL,
        fileType: FileType,
        location: URLReference.Location,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        URLReference.create(for: sourceURL, location: location) { result in
            switch result {
            case .success(let urlRef):
                if fileType == .database {
                    Settings.current.startupDatabase = urlRef
                }
                Diag.info("Internal file processed successfully [fileType: \(fileType), location: \(location)]")
                FileKeeperNotifier.notifyFileAdded(urlRef: urlRef, fileType: fileType)
                completionQueue.addOperation {
                    completion(.success(urlRef))
                }
            case .failure(let fileAccessError):
                Diag.error("Failed to create URL reference [error: '\(fileAccessError.localizedDescription)', url: '\(sourceURL.redacted)']")
                let importError = FileKeeperError.openError(reason: fileAccessError.localizedDescription)
                completionQueue.addOperation {
                    completion(.failure(importError))
                }
            }
        }
    }
    
    private func addExternalFileRef(
        url sourceURL: URL,
        fileType: FileType,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URLReference, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        Diag.debug("Will add external file reference")
        
        URLReference.create(for: sourceURL, location: .external) {
            [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let newRef):
                var storedRefs = self.getStoredReferences(
                    fileType: fileType,
                    forExternalFiles: true)
                storedRefs.insert(newRef, at: 0)
                self.storeReferences(storedRefs, fileType: fileType, forExternalFiles: true)
                
                Diag.info("External URL reference added OK")
                completionQueue.addOperation {
                    completion(.success(newRef))
                }
            case .failure(let fileAccessError):
                Diag.error("Failed to create URL reference [error: '\(fileAccessError.localizedDescription)', url: '\(sourceURL.redacted)']")
                let importError = FileKeeperError.openError(reason: fileAccessError.localizedDescription)
                completionQueue.addOperation {
                    completion(.failure(importError))
                }
            }
        }
    }
    
    
    private func copyToDocumentsResolvingConflicts(
        from sourceURL: URL,
        fileProvider: FileProvider?,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URL, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        let fileName = sourceURL.lastPathComponent
        let targetURL = docDirURL.appendingPathComponent(fileName)
        let sourceDirs = sourceURL.deletingLastPathComponent() 
        
        if sourceDirs.path == docDirURL.path {
            Diag.info("Tried to import a file already in Documents, nothing to do")
            completionQueue.addOperation {
                completion(.success(sourceURL))
            }
            return
        }
        
        Diag.debug("Will import a file")
        BaseDocument.read(sourceURL, completionQueue: operationQueue) { [self] result in 
            assert(operationQueue.isCurrent)
            switch result {
            case .success(let docData):
                self.saveDataWithConflictResolution(
                    docData,
                    to: targetURL,
                    conflictResolution: .ask,
                    completionQueue: completionQueue,
                    completion: completion)
            case .failure(let fileAccessError):
                Diag.error("Failed to import external file [message: \(fileAccessError.localizedDescription)]")
                let importError = FileKeeperError.importError(reason: fileAccessError.localizedDescription)
                completionQueue.addOperation {
                    completion(.failure(importError))
                }
                self.clearInbox()
            }
        }
    }
    
    private func saveDataWithConflictResolution(
        _ data: ByteArray,
        to targetURL: URL,
        conflictResolution: FileKeeper.ConflictResolution,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URL, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        let hasConflict = FileManager.default.fileExists(atPath: targetURL.path)
        guard hasConflict else {
            writeToFile(data, to: targetURL, completionQueue: completionQueue, completion: completion)
            clearInbox()
            return
        }
        
        switch conflictResolution {
        case .ask:
            assert(delegate != nil)
            let conflictResolutionHandler: ((ConflictResolution)->Void) = {
                [self] (resolution) in
                Diag.info("Conflict resolution: \(resolution)")
                self.operationQueue.addOperation {
                    self.saveDataWithConflictResolution(
                        data,
                        to: targetURL,
                        conflictResolution: resolution,
                        completionQueue: completionQueue,
                        completion: completion
                    )
                }
            }
            DispatchQueue.main.async { [self] in 
                self.delegate?.shouldResolveImportConflict(
                    target: targetURL,
                    handler: conflictResolutionHandler
                )
            }
        case .abort:
            clearInbox()
            completionQueue.addOperation {
                completion(.success(targetURL))
            }
        case .rename:
            let newURL = makeUniqueFileName(targetURL)
            writeToFile(data, to: newURL, completionQueue: completionQueue, completion: completion)
            clearInbox()
        case .overwrite:
            writeToFile(data, to: targetURL, completionQueue: completionQueue, completion: completion)
            clearInbox()
        }
    }
    
    
    private func makeUniqueFileName(_ url: URL) -> URL {
        let fileManager = FileManager.default

        let path = url.deletingLastPathComponent()
        let fileNameNoExt = url.deletingPathExtension().lastPathComponent
        let fileExt = url.pathExtension
        
        var fileName = url.lastPathComponent
        var index = 1
        while fileManager.fileExists(atPath: path.appendingPathComponent(fileName).path) {
            fileName = String(format: "%@ (%d).%@", fileNameNoExt, index, fileExt)
            index += 1
        }
        return path.appendingPathComponent(fileName)
    }
    
    private func writeToFile(
        _ bytes: ByteArray,
        to targetURL: URL,
        completionQueue: OperationQueue,
        completion: @escaping (Result<URL, FileKeeperError>) -> Void
    ) {
        assert(operationQueue.isCurrent)
        do {
            try bytes.write(to: targetURL, options: [.atomicWrite])
            Diag.debug("File imported successfully")
            clearInbox()
            completionQueue.addOperation {
                completion(.success(targetURL))
            }
        } catch {
            Diag.error("Failed to save external file [message: \(error.localizedDescription)]")
            let importError = FileKeeperError.importError(reason: error.localizedDescription)
            completionQueue.addOperation {
                completion(.failure(importError))
            }
        }
    }
    
    private func clearInbox() {
        let fileManager = FileManager()
        let inboxFiles = try? fileManager.contentsOfDirectory(
            at: inboxDirURL,
            includingPropertiesForKeys: nil,
            options: [])
        inboxFiles?.forEach {
            try? fileManager.removeItem(at: $0) 
        }
    }
    
    
    enum BackupMode {
        case latest
        case timestamped
    }
    
    let backupTimestampFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return dateFormatter
    }()
    let backupTimestampSeparator = Character("_")
    let backupLatestSuffix = ".latest"
    
    func makeBackup(nameTemplate: String, mode: BackupMode, contents: ByteArray) {
        guard !contents.isEmpty else {
            Diag.info("No data to backup.")
            return
        }
        guard let encodedNameTemplate = nameTemplate
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        guard let nameTemplateURL = URL(string: encodedNameTemplate) else { return }
        
        let timestamp: Date
        let fileNameSuffix: String
        switch mode {
        case .latest:
            timestamp = Date.now
            fileNameSuffix = backupLatestSuffix
        case .timestamped:
            timestamp = Date.now - 1.0
            let timestampString = backupTimestampFormatter.string(from: timestamp)
            fileNameSuffix = String(backupTimestampSeparator) + timestampString
        }
        
        let baseFileName = nameTemplateURL
            .deletingPathExtension()
            .absoluteString
            .removingPercentEncoding  
            ?? nameTemplate           
        var backupFileURL = backupDirURL
            .appendingPathComponent(baseFileName + fileNameSuffix, isDirectory: false)
            .appendingPathExtension(nameTemplateURL.pathExtension)
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: backupDirURL,
                withIntermediateDirectories: true,
                attributes: nil)
            
            try contents.asData.write(to: backupFileURL, options: .atomic)
            try fileManager.setAttributes(
                [FileAttributeKey.creationDate: timestamp,
                 FileAttributeKey.modificationDate: timestamp],
                ofItemAtPath: backupFileURL.path)
            
            let isExcludeFromBackup = Settings.current.isExcludeBackupFilesFromSystemBackup
            backupFileURL.setExcludedFromBackup(isExcludeFromBackup)
            
            switch mode {
            case .latest:
                Diag.info("Latest backup updated OK")
            case .timestamped:
                Diag.info("Backup copy created OK")
            }
        } catch {
            Diag.warning("Failed to make backup copy [error: \(error.localizedDescription)]")
        }
    }
    
    public func getBackupFiles() -> [URLReference] {
        return scanLocalDirectory(backupDirURL, fileType: .database)
    }
    
    public func deleteExpiredBackupFiles(completion: (()->Void)?) {
        Diag.debug("Will perform backup maintenance")
        deleteBackupFiles(
            olderThan: Settings.current.backupKeepingDuration.seconds,
            keepLatest: true,
            completionQueue: .main,
            completion: {
                Diag.info("Backup maintenance completed")
                completion?()
            }
        )
    }

    
    private func getBackupFileDate(_ urlRef: URLReference, completion: @escaping (Date?) -> Void) {
        if let url = urlRef.url {
            let fileName = url.deletingPathExtension().lastPathComponent
            let possibleTimestamp = fileName.suffix(backupTimestampFormatter.dateFormat.count)
            if let date = backupTimestampFormatter.date(from: String(possibleTimestamp)) {
                completion(date)
                return
            }
        }
        urlRef.getCachedInfo(canFetch: true) { result in
            switch result {
            case .success(let fileInfo):
                guard let date = fileInfo.modificationDate else {
                    completion(nil)
                    return
                }
                completion(date)
            case .failure(let error):
                Diag.warning("Failed to check backup file age [reason: \(error.localizedDescription)]")
                completion(nil)
            }
        }
    }

    private func isLatestBackupFile(_ urlRef: URLReference) -> Bool {
        guard let fileName = urlRef.url?.deletingPathExtension().lastPathComponent else {
            return false
        }
        return fileName.hasSuffix(backupLatestSuffix)
    }
    
    public func deleteBackupFiles(
        olderThan maxAge: TimeInterval,
        keepLatest: Bool,
        completionQueue: OperationQueue = .main,
        completion: (()->Void)?
    ) {
        operationQueue.addOperation { [weak self] in
            self?.deleteBackupFilesAsync(
                olderThan: maxAge,
                keepLatest: keepLatest,
                completionQueue: completionQueue,
                completion: completion
            )
        }
    }
    
    private func deleteBackupFilesAsync(
        olderThan maxAge: TimeInterval,
        keepLatest: Bool,
        completionQueue: OperationQueue,
        completion: (()->Void)?
    ) {
        assert(operationQueue.isCurrent)
        let allBackupFileRefs = getBackupFiles()
        let now = Date.now
        for fileRef in allBackupFileRefs {
            if keepLatest && isLatestBackupFile(fileRef) {
                continue
            }
            getBackupFileDate(fileRef) { [weak self] fileDate in
                guard let self = self else { return }
                guard let fileDate = fileDate else {
                    Diag.warning("Failed to get backup file age.")
                    return
                }
                guard now.timeIntervalSince(fileDate) > maxAge else {
                    return
                }
                do {
                    try self.deleteFile(fileRef, fileType: .database, ignoreErrors: false)
                    FileKeeperNotifier.notifyFileRemoved(urlRef: fileRef, fileType: .database)
                } catch {
                    Diag.warning("Failed to delete backup file [reason: \(error.localizedDescription)]")
                }
            }
        }
        completionQueue.addOperation {
            completion?()
        }
    }
}


fileprivate class ReferenceCache {
    private struct FileTypeExternalKey: Hashable {
        var fileType: FileType
        var isExternal: Bool
    }
    private struct DirectoryFileTypeKey: Hashable {
        var directory: URL
        var fileType: FileType
    }
    
    private var cache = [FileTypeExternalKey: [URLReference]]()
    private var cacheSet = [FileTypeExternalKey: Set<URLReference>]()
    private var directoryCache = [DirectoryFileTypeKey: [URLReference]]()
    private var directoryCacheSet = [DirectoryFileTypeKey: Set<URLReference>]()
    
    private let semaphore = DispatchSemaphore(value: 1)
    
    func update(
        with newRefs: [URLReference],
        fileType: FileType,
        isExternal: Bool
    ) -> [URLReference] {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        let key = FileTypeExternalKey(fileType: fileType, isExternal: isExternal)
        guard var _cache = cache[key], let _cacheSet = cacheSet[key] else {
            cache[key] = newRefs
            cacheSet[key] = Set(newRefs)
            return newRefs
        }
        let newRefsSet = Set(newRefs)
        let addedRefs = newRefsSet.subtracting(_cacheSet)
        let removedRefs = _cacheSet.subtracting(newRefsSet)
        if !removedRefs.isEmpty {
            _cache.removeAll { ref in removedRefs.contains(ref) }
        }
        _cache.append(contentsOf: addedRefs)
        cache[key] = _cache
        cacheSet[key] = _cacheSet.subtracting(removedRefs).union(addedRefs)
        return _cache
    }
    
    func update(
        with newRefs: [URLReference],
        from directory: URL,
        fileType: FileType
    ) -> [URLReference] {
        semaphore.wait()
        defer {
            semaphore.signal()
        }

        let key = DirectoryFileTypeKey(directory: directory, fileType: fileType)
        guard var _directoryCache = directoryCache[key],
            let _directoryCacheSet = directoryCacheSet[key] else
        {
            directoryCache[key] = newRefs
            directoryCacheSet[key] = Set(newRefs)
            return newRefs
        }
        let newRefsSet = Set(newRefs)
        let addedRefs = newRefsSet.subtracting(_directoryCacheSet)
        let removedRefs = _directoryCacheSet.subtracting(newRefsSet)
        _directoryCache.removeAll { ref in removedRefs.contains(ref) }
        _directoryCache.append(contentsOf: addedRefs)
        directoryCache[key] = _directoryCache
        directoryCacheSet[key] = _directoryCacheSet.subtracting(removedRefs).union(addedRefs)
        return _directoryCache
    }
}

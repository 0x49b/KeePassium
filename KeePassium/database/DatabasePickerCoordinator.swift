//  KeePassium Password Manager
//  Copyright © 2021 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

protocol DatabasePickerCoordinatorDelegate: AnyObject {
    func didSelectDatabase(_ fileRef: URLReference?, in coordinator: DatabasePickerCoordinator)
    
    func shouldKeepSelection(in coordinator: DatabasePickerCoordinator) -> Bool
}

public enum DatabasePickerMode {
    case full
    case autoFill
    case light
}

final class DatabasePickerCoordinator: NSObject, Coordinator, Refreshable {
    var childCoordinators = [Coordinator]()
    
    var dismissHandler: CoordinatorDismissHandler?
    weak var delegate: DatabasePickerCoordinatorDelegate?
    private(set) var selectedDatabase: URLReference?
    var shouldSelectDefaultDatabase = false
    
    private let router: NavigationRouter
    private let databasePickerVC: DatabasePickerVC
    private let mode: DatabasePickerMode
    
    private var fileKeeperNotifications: FileKeeperNotifications!
    
    init(router: NavigationRouter, mode: DatabasePickerMode) {
        self.router = router
        self.mode = mode
        databasePickerVC = DatabasePickerVC.instantiateFromStoryboard()
        databasePickerVC.mode = mode
        super.init()
        
        databasePickerVC.delegate = self
        fileKeeperNotifications = FileKeeperNotifications(observer: self)
    }
    
    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
        
        fileKeeperNotifications.stopObserving()
    }
    
    func start() {
        router.push(databasePickerVC, animated: true, onPop: { [weak self] in
            guard let self = self else { return }
            self.removeAllChildCoordinators()
            self.dismissHandler?(self)
        })
        fileKeeperNotifications.startObserving()
    }
    
    func refresh() {
        databasePickerVC.refresh()
    }
    
    
    public func setEnabled(_ enabled: Bool) {
        databasePickerVC.isEnabled = enabled
    }
    
    public func selectDatabase(_ fileRef: URLReference?, animated: Bool) {
        selectedDatabase = fileRef
        switch mode {
        case .full, .autoFill:
            Settings.current.startupDatabase = fileRef
        case .light:
            break
        }
        databasePickerVC.selectDatabase(fileRef, animated: animated)
        delegate?.didSelectDatabase(fileRef, in: self)
    }
    
    #if MAIN_APP
    private func showTipBox(in viewController: UIViewController) {
        let modalRouter = NavigationRouter.createModal(style: .formSheet)
        let tipBoxCoordinator = TipBoxCoordinator(router: modalRouter)
        tipBoxCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        tipBoxCoordinator.start()
        addChildCoordinator(tipBoxCoordinator)
        viewController.present(modalRouter, animated: true, completion: nil)
    }
    
    func showAboutScreen(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(
            style: ProcessInfo.isRunningOnMac ? .formSheet : .popover,
            at: popoverAnchor)
        let aboutCoordinator = AboutCoordinator(router: modalRouter)
        aboutCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        aboutCoordinator.start()
        addChildCoordinator(aboutCoordinator)        
        viewController.present(modalRouter, animated: true, completion: nil)
    }
    #endif
    
    private func showListOptions(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(style: .popover, at: popoverAnchor)
        let settingsFileSortingCoordinator = SettingsFileSortingCoordinator(router: modalRouter)
        settingsFileSortingCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        settingsFileSortingCoordinator.start()
        addChildCoordinator(settingsFileSortingCoordinator)
        viewController.present(modalRouter, animated: true, completion: nil)
    }
    
    #if MAIN_APP
    func showAppSettings(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(
            style: ProcessInfo.isRunningOnMac ? .formSheet : .popover,
            at: popoverAnchor)
        let settingsCoordinator = SettingsCoordinator(router: modalRouter)
        settingsCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        settingsCoordinator.start()
        addChildCoordinator(settingsCoordinator)
        viewController.present(modalRouter, animated: true, completion: nil)
    }
    #endif
    
    private func maybeShowAddDatabaseOptions(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        guard hasValidDatabases() else {
            #if MAIN_APP
            databasePickerVC.showAddDatabaseOptions(at: popoverAnchor)
            #else
            addExistingDatabase(presenter: viewController)
            #endif
            return
        }
        performPremiumActionOrOfferUpgrade(for: .canUseMultipleDatabases, in: viewController) {
            [weak self] in
            #if MAIN_APP
            self?.databasePickerVC.showAddDatabaseOptions(at: popoverAnchor)
            #else
            self?.addExistingDatabase(presenter: viewController)
            #endif
        }
    }
    
    private func hasValidDatabases() -> Bool {
        let accessibleDatabaseRefs = FileKeeper.shared
            .getAllReferences(fileType: .database, includeBackup: false)
            .filter { !$0.needsReinstatement } 
        return accessibleDatabaseRefs.count > 0
    }
    
    public func addExistingDatabase(presenter: UIViewController) {
        let documentPicker = UIDocumentPickerViewController(
            documentTypes: FileType.databaseUTIs,
            in: .open
        )
        documentPicker.delegate = self
        documentPicker.modalPresentationStyle = .pageSheet
        presenter.present(documentPicker, animated: true, completion: nil)
    }
    
    private func addDatabaseFile(_ url: URL, mode: FileKeeper.OpenMode) {
        FileKeeper.shared.addFile(url: url, fileType: .database, mode: .openInPlace) {
            [weak self] (result) in
            switch result {
            case .success(let fileRef):
                self?.refresh()
                self?.selectDatabase(fileRef, animated: true)
            case .failure(let fileKeeperError):
                Diag.error("Failed to import database [message: \(fileKeeperError.localizedDescription)]")
                self?.refresh()
            }
        }
    }

    #if MAIN_APP
    public func createDatabase(presenter: UIViewController) {
        let modalRouter = NavigationRouter.createModal(style: .formSheet)
        let databaseCreatorCoordinator = DatabaseCreatorCoordinator(router: modalRouter)
        databaseCreatorCoordinator.delegate = self
        databaseCreatorCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        databaseCreatorCoordinator.start()
        
        presenter.present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(databaseCreatorCoordinator)
    }
    #endif

    private func showDatabaseInfo(
        _ fileRef: URLReference,
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabasePickerVC
    ) {
        let databaseInfoVC = FileInfoVC.make(urlRef: fileRef, fileType: .database, at: popoverAnchor)
        databaseInfoVC.canExport = true
        databaseInfoVC.didDeleteCallback = { [weak self, weak databaseInfoVC] in
            self?.refresh()
            databaseInfoVC?.dismiss(animated: true, completion: nil)
        }
        viewController.present(databaseInfoVC, animated: true, completion: nil)
    }
}

extension DatabasePickerCoordinator: DatabasePickerDelegate {

    func getDefaultDatabase(
        from databases: [URLReference],
        in viewController: DatabasePickerVC
    ) -> URLReference? {
        switch mode {
        case .light:
            return nil
        case .full, .autoFill:
            break
        }
        
        defer {
            shouldSelectDefaultDatabase = false
        }
        guard shouldSelectDefaultDatabase,
              Settings.current.isAutoUnlockStartupDatabase
        else {
            return nil
        }
        
        #if AUTOFILL_EXT
        if databases.count == 1,
           let defaultDatabase = databases.first
        {
            return defaultDatabase
        }
        #endif
        if let startupDatabase = Settings.current.startupDatabase,
           let defaultDatabase = startupDatabase.find(in: databases)
        {
            return defaultDatabase
        }
        return nil
    }
    
    func didPressAddDatabaseOptions(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        maybeShowAddDatabaseOptions(at: popoverAnchor, in: viewController)
    }
    
    func didPressSetupAppLock(in viewController: DatabasePickerVC) {
        let passcodeInputVC = PasscodeInputVC.instantiateFromStoryboard()
        passcodeInputVC.delegate = self
        passcodeInputVC.mode = .setup
        passcodeInputVC.modalPresentationStyle = .formSheet
        passcodeInputVC.isCancelAllowed = true
        viewController.present(passcodeInputVC, animated: true, completion: nil)
    }
    
    #if MAIN_APP
    func didPressHelp(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        showAboutScreen(at: popoverAnchor, in: viewController)
    }
        
    func didPressListOptions(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        showListOptions(at: popoverAnchor, in: viewController)
    }
    
    func didPressSettings(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        showAppSettings(at: popoverAnchor, in: viewController)
    }
    
    func didPressCreateDatabase(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        createDatabase(presenter: viewController)
    }
    #endif
    
    func didPressCancel(in viewController: DatabasePickerVC) {
        router.pop(viewController: databasePickerVC, animated: true)
    }
    
    func didPressAddExistingDatabase(at popoverAnchor: PopoverAnchor, in viewController: DatabasePickerVC) {
        addExistingDatabase(presenter: viewController)
    }

    func didPressRevealDatabaseInFinder(
        _ fileRef: URLReference,
        in viewController: DatabasePickerVC
    ) {
        FileExportHelper.revealInFinder(fileRef)
    }

    func didPressExportDatabase(
        _ fileRef: URLReference,
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabasePickerVC
    ) {
        FileExportHelper.showFileExportSheet(fileRef, at: popoverAnchor, parent: viewController)
    }
    
    func didPressEliminateDatabase(
        _ fileRef: URLReference,
        shouldConfirm: Bool,
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabasePickerVC
    ) {
        FileDestructionHelper.destroyFile(
            fileRef,
            fileType: .database,
            withConfirmation: shouldConfirm,
            at: popoverAnchor,
            parent: viewController,
            completion: { [weak self] isEliminated in
                guard let self = self else { return }
                if isEliminated && (fileRef === self.selectedDatabase) {
                    self.selectDatabase(nil, animated: false)
                }
                self.refresh()
            }
        )
    }
    
    func didPressDatabaseProperties(
        _ fileRef: URLReference,
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabasePickerVC
    ) {
        showDatabaseInfo(fileRef, at: popoverAnchor, in: viewController)
    }

    func shouldKeepSelection(in viewController: DatabasePickerVC) -> Bool {
        return delegate?.shouldKeepSelection(in: self) ?? true
    }
    
    func didSelectDatabase(_ fileRef: URLReference, in viewController: DatabasePickerVC) {
        selectDatabaseOrOfferPremiumUpgrade(fileRef, in: viewController)
    }
    
    private func selectDatabaseOrOfferPremiumUpgrade(
        _ fileRef: URLReference,
        in viewController: DatabasePickerVC
    ) {
        if fileRef == Settings.current.startupDatabase {
            selectDatabase(fileRef, animated: false)
            return
        }
        
        let validSortedDatabases = viewController.databaseRefs.filter {
            !$0.hasError && $0.location != .internalBackup
        }
        let isFirstDatabase = (fileRef === validSortedDatabases.first)
        if isFirstDatabase || fileRef.location == .internalBackup {
            selectDatabase(fileRef, animated: false)
        } else {
            performPremiumActionOrOfferUpgrade(
                for: .canUseMultipleDatabases,
                allowBypass: true,
                in: viewController,
                actionHandler: { [weak self] in
                    self?.selectDatabase(fileRef, animated: false)
                }
            )
        }
    }
}


extension DatabasePickerCoordinator: PasscodeInputDelegate {
    func passcodeInputDidCancel(_ sender: PasscodeInputVC) {
        do {
            try Keychain.shared.removeAppPasscode() 
        } catch {
            Diag.error(error.localizedDescription)
            databasePickerVC.showErrorAlert(error, title: LString.titleKeychainError)
            return
        }
        sender.dismiss(animated: true, completion: nil)
        refresh()
    }
    
    func passcodeInput(_sender: PasscodeInputVC, canAcceptPasscode passcode: String) -> Bool {
        return passcode.count > 0
    }
    
    func passcodeInput(_ sender: PasscodeInputVC, didEnterPasscode passcode: String) {
        sender.dismiss(animated: true) {
            [weak self] in
            do {
                try Keychain.shared.setAppPasscode(passcode)
                Settings.current.isBiometricAppLockEnabled = true
                self?.refresh()
            } catch {
                Diag.error(error.localizedDescription)
                self?.databasePickerVC.showErrorAlert(error, title: LString.titleKeychainError)
            }
        }
    }
}

extension DatabasePickerCoordinator: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        FileAddingHelper.ensureFileIsDatabase(url, parent: databasePickerVC) {
            [weak self] (url) in
            guard let self = self else { return }
            
            switch controller.documentPickerMode {
            case .open:
                self.addDatabaseFile(url, mode: .openInPlace)
            case .import:
                assertionFailure("This will misbehave in AutoFill before iOS 14")
                self.addDatabaseFile(url, mode: .import)
            default:
                Diag.warning("Unexpected document picker mode")
                assertionFailure()
                return
            }
        }
    }
}

#if MAIN_APP
extension DatabasePickerCoordinator: DatabaseCreatorCoordinatorDelegate {
    func didCreateDatabase(
        in databaseCreatorCoordinator: DatabaseCreatorCoordinator,
        database urlRef: URLReference
    ) {
        selectDatabase(urlRef, animated: true)
    }
}
#endif

extension DatabasePickerCoordinator: FileKeeperObserver {
    func fileKeeper(didAddFile urlRef: URLReference, fileType: FileType) {
        guard fileType == .database else { return }
        refresh()
    }
    
    func fileKeeper(didRemoveFile urlRef: URLReference, fileType: FileType) {
        guard fileType == .database else { return }
        if urlRef === selectedDatabase {
            selectDatabase(nil, animated: false)
        }
        refresh()
    }
}

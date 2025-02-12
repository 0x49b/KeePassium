//  KeePassium Password Manager
//  Copyright © 2021 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

public enum DatabaseCloseReason: CustomStringConvertible {
    case userRequest
    case databaseTimeout
    case appLevelOperation
    
    public var description: String {
        switch self {
        case .userRequest:
            return "User request"
        case .databaseTimeout:
            return "Database timeout"
        case .appLevelOperation:
            return "App-level operation"
        }
    }
}

protocol DatabaseViewerCoordinatorDelegate: AnyObject {
    func didLeaveDatabase(in coordinator: DatabaseViewerCoordinator)
    
    func didRelocateDatabase(_ databaseFile: DatabaseFile, to url: URL)
}

final class DatabaseViewerCoordinator: Coordinator {
    private let vcAnimationDuration = 0.3
    
    enum Action {
        case lockDatabase
        case createEntry
        case createGroup
    }
    
    var childCoordinators = [Coordinator]()
    
    weak var delegate: DatabaseViewerCoordinatorDelegate?
    var dismissHandler: CoordinatorDismissHandler?

    private let primaryRouter: NavigationRouter
    private let placeholderRouter: NavigationRouter
    private var entryViewerRouter: NavigationRouter?
    
    private let databaseFile: DatabaseFile
    private let database: Database
    private let canEditDatabase: Bool
    private let loadingWarnings: DatabaseLoadingWarnings?
    
    private weak var currentGroup: Group?
    private weak var currentEntry: Entry?
    private weak var rootGroupViewer: GroupViewerVC?
    
    private let splitViewController: RootSplitVC
    private weak var oldSplitDelegate: UISplitViewControllerDelegate?
    private var isSplitViewCollapsed: Bool {
        return splitViewController.isCollapsed
    }
    
    private var oldPrimaryRouterDetailDismissalHandler:
        NavigationRouter.CollapsedDetailDismissalHandler?
    
    private var progressOverlay: ProgressOverlay?
    private var settingsNotifications: SettingsNotifications!
    
    var databaseSaver: DatabaseSaver?
    var fileExportHelper: FileExportHelper?
    var savingProgressHost: ProgressViewHost? { return self }
    
    init(
        splitViewController: RootSplitVC,
        primaryRouter: NavigationRouter,
        databaseFile: DatabaseFile,
        canEditDatabase: Bool,
        loadingWarnings: DatabaseLoadingWarnings?
    ) {
        self.splitViewController = splitViewController
        self.primaryRouter = primaryRouter
        
        self.databaseFile = databaseFile
        self.database = databaseFile.database
        self.canEditDatabase = canEditDatabase
        self.loadingWarnings = loadingWarnings
        
        let placeholderVC = PlaceholderVC.instantiateFromStoryboard()
        let placeholderWrapperVC = RouterNavigationController(rootViewController: placeholderVC)
        self.placeholderRouter = NavigationRouter(placeholderWrapperVC)
    }
    
    deinit {
        settingsNotifications.stopObserving()
        
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }
    
    func start() {
        oldSplitDelegate = splitViewController.delegate
        splitViewController.delegate = self
        
        oldPrimaryRouterDetailDismissalHandler = primaryRouter.collapsedDetailDismissalHandler
        primaryRouter.collapsedDetailDismissalHandler = { [weak self] dismissedVC in
            guard let self = self else { return }
            if dismissedVC === self.entryViewerRouter?.navigationController {
                self.showEntry(nil)
            }
        }

        settingsNotifications = SettingsNotifications(observer: self)

        showGroup(database.root, replacingTopVC: splitViewController.isCollapsed)
        showEntry(nil)
        
        settingsNotifications.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * vcAnimationDuration) {
            [weak self] in
            self?.showInitialMessages()
        }
    }
    
    public func stop(animated: Bool, completion: (()->Void)?) {
        guard let rootGroupViewer = rootGroupViewer else {
            fatalError("No group viewer")
        }
        primaryRouter.dismissModals(animated: animated) { [self, rootGroupViewer] in 
            self.primaryRouter.pop(
                viewController: rootGroupViewer,
                animated: animated,
                completion: completion
            )
        }
    }
    
    func refresh() {
        if let topPrimaryVC = primaryRouter.navigationController.topViewController {
            (topPrimaryVC as? Refreshable)?.refresh()
        }
        if let topSecondaryVC = entryViewerRouter?.navigationController.topViewController {
            (topSecondaryVC as? Refreshable)?.refresh()
        }
    }
    
    private func getPresenterForModals() -> UIViewController {
        return splitViewController
    }
}

extension DatabaseViewerCoordinator {
    public func canPerform(action: Action) -> Bool {
        switch action {
        case .lockDatabase:
            return true
        case .createEntry:
            guard let currentGroup = currentGroup else {
                assertionFailure()
                return false
            }
            let permissions = getActionPermissions(for: currentGroup)
            return permissions.canCreateEntry
        case .createGroup:
            guard let currentGroup = currentGroup else {
                assertionFailure()
                return false
            }
            let permissions = getActionPermissions(for: currentGroup)
            return permissions.canCreateGroup
        }
    }
    
    public func perform(action: Action) {
        assert(canPerform(action: action))
        switch action {
        case .lockDatabase:
            closeDatabase(shouldLock: true, reason: .userRequest, animated: true, completion: nil)
        case .createEntry:
            let popoverAnchor = PopoverAnchor(
                sourceView: primaryRouter.navigationController.view,
                sourceRect: primaryRouter.navigationController.view.bounds)
            primaryRouter.dismissModals(animated: true) { [self] in
                showEntryEditor(for: nil, at: popoverAnchor)
            }
        case .createGroup:
            let popoverAnchor = PopoverAnchor(
                sourceView: primaryRouter.navigationController.view,
                sourceRect: primaryRouter.navigationController.view.bounds)
            primaryRouter.dismissModals(animated: true) { [self] in
                showGroupEditor(for: nil, at: popoverAnchor)
            }
        }
    }
}

extension DatabaseViewerCoordinator {
    private func showInitialMessages() {
        if loadingWarnings != nil {
            showLoadingWarnings(loadingWarnings!)
        }
        if !canEditDatabase {
            showReadOnlyDatabaseNotification(in: getPresenterForModals())
        }

        StoreReviewSuggester.maybeShowAppReview(
            appVersion: AppInfo.version,
            occasion: .didOpenDatabase
        )
    }
    
    private func showLoadingWarnings(_ warnings: DatabaseLoadingWarnings) {
        guard !warnings.isEmpty else { return }
        
        let presentingVC = getPresenterForModals()
        DatabaseLoadingWarningsVC.present(
            warnings,
            in: presentingVC,
            onLockDatabase: { [weak self] in
                self?.closeDatabase(
                    shouldLock: true,
                    reason: .userRequest,
                    animated: true,
                    completion: nil
                )
            }
        )
        StoreReviewSuggester.registerEvent(.trouble)
    }
    
    private func showReadOnlyDatabaseNotification(in toastHost: UIViewController) {
        let image: UIImage?
        if #available(iOS 13, *) {
            image = UIImage(systemName: SystemImageName.exclamationMarkTriangle.rawValue)?
                .withTintColor(UIColor.warningMessage, renderingMode: .alwaysOriginal)
        } else {
            image = UIImage.get(.exclamationMarkTriangle)
        }
        toastHost.showNotification(
            LString.databaseIsReadOnly,
            image: image,
            imageSize: CGSize(width: 25, height: 25),
            duration: 3.0
        )
    }
    
    private func showDiagnostics() {
        let modalRouter = NavigationRouter.createModal(style: .formSheet)
        let diagnosticsViewerCoordinator = DiagnosticsViewerCoordinator(router: modalRouter)
        diagnosticsViewerCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        diagnosticsViewerCoordinator.start()
        
        getPresenterForModals().present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(diagnosticsViewerCoordinator)
    }
    
    private func showGroup(_ group: Group?, replacingTopVC: Bool = false) {
        guard let group = group else {
            Diag.error("The group is nil")
            assertionFailure()
            return
        }

        let previousGroup = currentGroup
        currentGroup = group

        group.touch(.accessed)
        let groupViewerVC = GroupViewerVC.instantiateFromStoryboard()
        groupViewerVC.delegate = self
        groupViewerVC.group = group
        
        let isCustomTransition = replacingTopVC
        if isCustomTransition {
            primaryRouter.prepareCustomTransition(
                duration: vcAnimationDuration,
                type: .fade,
                timingFunction: .easeOut
            )
        }
        primaryRouter.push(
            groupViewerVC,
            animated: !isCustomTransition,
            replaceTopViewController: replacingTopVC,
            onPop: {
                [weak self, previousGroup] in
                guard let self = self else { return }
                self.currentGroup = previousGroup
                if previousGroup == nil { 
                    self.showEntry(nil) 
                    self.splitViewController.delegate = self.oldSplitDelegate
                    self.primaryRouter.collapsedDetailDismissalHandler =
                        self.oldPrimaryRouterDetailDismissalHandler
                    self.dismissHandler?(self)
                    self.delegate?.didLeaveDatabase(in: self)
                }
            }
        )

        if rootGroupViewer == nil {
            rootGroupViewer = groupViewerVC
        }
    }
    
    private func selectEntry(_ entry: Entry?) {
        guard let groupViewerVC = primaryRouter.navigationController.topViewController
                as? GroupViewerVC
        else {
            assertionFailure()
            return
        }
        
        groupViewerVC.selectEntry(entry, animated: false)
        showEntry(entry)
    }
    
    private func showEntry(_ entry: Entry?) {
        currentEntry = entry
        guard let entry = entry else {
            if !splitViewController.isCollapsed {
                splitViewController.setDetailRouter(placeholderRouter)
            }
            entryViewerRouter?.popAll()
            entryViewerRouter = nil
            childCoordinators.removeAll(where: { $0 is EntryViewerCoordinator })
            return
        }
        
        if let existingCoordinator = childCoordinators.first(where: { $0 is EntryViewerCoordinator }) {
            let entryViewerCoordinator = existingCoordinator as! EntryViewerCoordinator 
            entryViewerCoordinator.setEntry(
                entry,
                isHistoryEntry: false,
                canEditEntry: canEditDatabase && !entry.isDeleted
            )
            guard let entryViewerRouter = self.entryViewerRouter else {
                Diag.error("Coordinator without a router, aborting")
                assertionFailure()
                return
            }
            splitViewController.setDetailRouter(entryViewerRouter)
            return
        }
        
        let entryViewerRouter = NavigationRouter(RouterNavigationController())
        let entryViewerCoordinator = EntryViewerCoordinator(
            entry: entry,
            databaseFile: databaseFile,
            isHistoryEntry: false,
            canEditEntry: canEditDatabase && !entry.isDeleted,
            router: entryViewerRouter,
            progressHost: self 
        )
        entryViewerCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
            self?.entryViewerRouter = nil
        }
        entryViewerCoordinator.delegate = self
        entryViewerCoordinator.start()
        addChildCoordinator(entryViewerCoordinator)
        
        self.entryViewerRouter = entryViewerRouter
        splitViewController.setDetailRouter(entryViewerRouter)
    }
    
    public func closeDatabase(
        shouldLock: Bool,
        reason: DatabaseCloseReason,
        animated: Bool,
        completion: (()->Void)?
    ) {
        if shouldLock {
            DatabaseSettingsManager.shared.updateSettings(for: databaseFile) {
                $0.clearMasterKey()
            }
        }
        Diag.debug("Database closed [locked: \(shouldLock), reason: \(reason)]")
        stop(animated: animated, completion: completion)
    }
    
    private func showGroupListSettings(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(style: .popover, at: popoverAnchor)
        let listSettingsCoordinator = SettingsItemListCoordinator(router: modalRouter)
        listSettingsCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        listSettingsCoordinator.start()
        addChildCoordinator(listSettingsCoordinator)
        viewController.present(modalRouter, animated: true, completion: nil)
    }

    private func showAppSettings(at popoverAnchor: PopoverAnchor, in viewController: UIViewController) {
        let modalRouter = NavigationRouter.createModal(
            style: ProcessInfo.isRunningOnMac ? .formSheet : .popover,
            at: popoverAnchor)
        let settingsCoordinator = SettingsCoordinator(router: modalRouter)
        settingsCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        settingsCoordinator.start()
        viewController.present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(settingsCoordinator)
    }
    
    private func showMasterKeyChanger(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        Diag.info("Will change master key")
        
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let databaseKeyChangeCoordinator = DatabaseKeyChangerCoordinator(
            databaseFile: databaseFile,
            router: modalRouter
        )
        databaseKeyChangeCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        databaseKeyChangeCoordinator.delegate = self
        databaseKeyChangeCoordinator.start()
        viewController.present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(databaseKeyChangeCoordinator)
    }
    
    private func showGroupEditor(for groupToEdit: Group?, at popoverAnchor: PopoverAnchor?) {
        Diag.info("Will edit group")
        guard let parent = currentGroup else {
            Diag.warning("Parent group is not defined")
            assertionFailure()
            return
        }
        
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let groupEditorCoordinator = GroupEditorCoordinator(
            router: modalRouter,
            databaseFile: databaseFile,
            parent: parent,
            target: groupToEdit)
        groupEditorCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        groupEditorCoordinator.delegate = self
        groupEditorCoordinator.start()
        
        getPresenterForModals().present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(groupEditorCoordinator)
    }
    
    private func showEntryEditor(for entryToEdit: Entry?, at popoverAnchor: PopoverAnchor?) {
        Diag.info("Will edit entry")
        guard let parent = currentGroup else {
            Diag.warning("Parent group is not definted")
            assertionFailure()
            return
        }
        
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let entryFieldEditorCoordinator = EntryFieldEditorCoordinator(
            router: modalRouter,
            databaseFile: databaseFile,
            parent: parent,
            target: entryToEdit
        )
        entryFieldEditorCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        entryFieldEditorCoordinator.delegate = self
        entryFieldEditorCoordinator.start()
        modalRouter.dismissAttemptDelegate = entryFieldEditorCoordinator
        
        getPresenterForModals().present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(entryFieldEditorCoordinator)
    }
    
    private func showItemRelocator(
        for item: DatabaseItem,
        mode: ItemRelocationMode,
        at popoverAnchor: PopoverAnchor
    ) {
        Diag.info("Will relocate item [mode: \(mode)]")
        let modalRouter = NavigationRouter.createModal(style: .popover, at: popoverAnchor)
        let itemRelocationCoordinator = ItemRelocationCoordinator(
            router: modalRouter,
            databaseFile: databaseFile,
            mode: mode,
            itemsToRelocate: [Weak(item)])
        itemRelocationCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        itemRelocationCoordinator.delegate = self
        itemRelocationCoordinator.start()
        
        getPresenterForModals().present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(itemRelocationCoordinator)
    }
}

extension DatabaseViewerCoordinator: SettingsObserver {
    func settingsDidChange(key: Settings.Keys) {
        guard key != .recentUserActivityTimestamp else {
            return
        }
        refresh()
    }
}

extension DatabaseViewerCoordinator: GroupViewerDelegate {
    func didPressListSettings(at popoverAnchor: PopoverAnchor, in viewController: GroupViewerVC) {
        showGroupListSettings(at: popoverAnchor, in: viewController)
    }
        
    func didPressLockDatabase(in viewController: GroupViewerVC) {
        closeDatabase(shouldLock: true, reason: .userRequest, animated: true, completion: nil)
    }

    func didPressChangeMasterKey(at popoverAnchor: PopoverAnchor, in viewController: GroupViewerVC) {
        showMasterKeyChanger(at: popoverAnchor, in: viewController)
    }
    
    func didPressSettings(at popoverAnchor: PopoverAnchor, in viewController: GroupViewerVC) {
        showAppSettings(at: popoverAnchor, in: viewController)
    }

    func didSelectGroup(_ group: Group?, in viewController: GroupViewerVC) -> Bool {
        showGroup(group)
        
        return false
    }
    
    func didSelectEntry(_ entry: Entry?, in viewController: GroupViewerVC) -> Bool {
        showEntry(entry)
        
        let shouldRemainSelected = !isSplitViewCollapsed
        return shouldRemainSelected
    }

    func didPressCreateGroup(at popoverAnchor: PopoverAnchor, in viewController: GroupViewerVC) {
        showGroupEditor(for: nil, at: popoverAnchor)
    }

    func didPressCreateEntry(at popoverAnchor: PopoverAnchor, in viewController: GroupViewerVC) {
        showEntryEditor(for: nil, at: popoverAnchor)
    }
    
    func didPressEditGroup(
        _ group: Group,
        at popoverAnchor: PopoverAnchor,
        in viewController: GroupViewerVC
    ) {
        showGroupEditor(for: group, at: popoverAnchor)
    }

    func didPressEditEntry(
        _ entry: Entry,
        at popoverAnchor: PopoverAnchor,
        in viewController: GroupViewerVC
    ) {
        showEntryEditor(for: entry, at: popoverAnchor)
    }
    
    func didPressDeleteGroup(
        _ group: Group,
        at popoverAnchor: PopoverAnchor,
        in viewController: GroupViewerVC
    ) {
        database.delete(group: group)
        group.touch(.accessed)
        saveDatabase(databaseFile)
    }
    
    func didPressDeleteEntry(
        _ entry: Entry,
        at popoverAnchor: PopoverAnchor,
        in viewController: GroupViewerVC
    ) {
        database.delete(entry: entry)
        entry.touch(.accessed)
        let isDeletedCurrentEntry = entry === currentEntry
        if isDeletedCurrentEntry {
            selectEntry(nil)
            showEntry(nil)
        }
        saveDatabase(databaseFile)
    }
    
    func didPressRelocateItem(
        _ item: DatabaseItem,
        mode: ItemRelocationMode,
        at popoverAnchor: PopoverAnchor,
        in viewController: GroupViewerVC
    ) {
        showItemRelocator(for: item, mode: mode, at: popoverAnchor)
    }
    
    func getActionPermissions(for group: Group) -> DatabaseItemActionPermissions {
        guard canEditDatabase else {
            return DatabaseItemActionPermissions.everythingForbidden
        }
        
        var result = DatabaseItemActionPermissions()
        result.canEditDatabase = true 
        result.canCreateGroup = !group.isDeleted

        if group is Group1 {
            result.canCreateEntry = !group.isDeleted && !group.isRoot
        } else {
            result.canCreateEntry = !group.isDeleted
        }
        
        let isRecycleBin = (group === group.database?.getBackupGroup(createIfMissing: false))
        if isRecycleBin {
            result.canEditItem = group is Group2
        } else {
            result.canEditItem = !group.isDeleted
        }
        
        result.canDeleteItem = !group.isRoot
        
        result.canMoveItem = !group.isRoot
        if (group is Group1) && isRecycleBin {
            result.canMoveItem = false
        }
        return result
    }
    
    func getActionPermissions(for entry: Entry) -> DatabaseItemActionPermissions {
        guard canEditDatabase else {
            return DatabaseItemActionPermissions.everythingForbidden
        }
        
        var result = DatabaseItemActionPermissions()
        result.canEditDatabase = true 
        result.canCreateGroup = false
        result.canCreateEntry = false
        result.canEditItem = !entry.isDeleted
        result.canDeleteItem = true 
        result.canMoveItem = true
        return result
    }
}

extension DatabaseViewerCoordinator: ProgressViewHost {
    public func showProgressView(title: String, allowCancelling: Bool, animated: Bool) {
        if progressOverlay != nil {
            progressOverlay?.title = title
            progressOverlay?.isCancellable = allowCancelling
            return
        }
        progressOverlay = ProgressOverlay.addTo(
            splitViewController.view,
            title: title,
            animated: animated)
        progressOverlay?.isCancellable = allowCancelling
        progressOverlay?.unresponsiveCancelHandler = { [weak self] in
            self?.showDiagnostics()
        }
    }
    
    public func updateProgressView(with progress: ProgressEx) {
        assert(progressOverlay != nil)
        progressOverlay?.update(with: progress)
    }
    
    public func hideProgressView(animated: Bool) {
        progressOverlay?.dismiss(animated: animated) { [weak self] finished in
            guard let self = self else { return }
            self.progressOverlay?.removeFromSuperview()
            self.progressOverlay = nil
        }
    }
}

extension DatabaseViewerCoordinator: DatabaseSaving {
    func canCancelSaving(databaseFile: DatabaseFile) -> Bool {
        return false
    }
    
    func didCancelSaving(databaseFile: DatabaseFile) {
        refresh()
    }
    
    func didSave(databaseFile: DatabaseFile) {
        refresh()
    }
    
    func didFailSaving(databaseFile: DatabaseFile) {
        refresh()
    }
    
    func didRelocate(databaseFile: DatabaseFile, to newURL: URL) {
        delegate?.didRelocateDatabase(databaseFile, to: newURL)
    }
    
    func getDatabaseSavingErrorParent() -> UIViewController {
        getPresenterForModals()
    }
    
    func getDiagnosticsHandler() -> (() -> Void)? {
        return showDiagnostics
    }
}

extension DatabaseViewerCoordinator: EntryViewerCoordinatorDelegate {
    func didUpdateEntry(_ entry: Entry, in coordinator: EntryViewerCoordinator) {
        refresh()
    }
    
    func didRelocateDatabase(_ databaseFile: DatabaseFile, to url: URL) {
        delegate?.didRelocateDatabase(databaseFile, to: url)
    }
}

extension DatabaseViewerCoordinator: GroupEditorCoordinatorDelegate {
    func didUpdateGroup(_ group: Group, in coordinator: GroupEditorCoordinator) {
        refresh()
        StoreReviewSuggester.maybeShowAppReview(appVersion: AppInfo.version, occasion: .didEditItem)
    }
}

extension DatabaseViewerCoordinator: EntryFieldEditorCoordinatorDelegate {
    func didUpdateEntry(_ entry: Entry, in coordinator: EntryFieldEditorCoordinator) {
        refresh()
        if !isSplitViewCollapsed {
            selectEntry(entry)
        }
        StoreReviewSuggester.maybeShowAppReview(appVersion: AppInfo.version, occasion: .didEditItem)
    }
}

extension DatabaseViewerCoordinator: ItemRelocationCoordinatorDelegate {
    func didRelocateItems(in coordinator: ItemRelocationCoordinator) {
        getPresenterForModals().showSuccessNotification(LString.actionDone)
        refresh()
    }
}

extension DatabaseViewerCoordinator: DatabaseKeyChangerCoordinatorDelegate {
    func didChangeDatabaseKey(in coordinator: DatabaseKeyChangerCoordinator) {
        getPresenterForModals().showNotification(LString.masterKeySuccessfullyChanged)
    }
}

extension DatabaseViewerCoordinator: UISplitViewControllerDelegate {
    func splitViewController(
        _ splitViewController: UISplitViewController,
        collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController
    ) -> Bool {
        if secondaryViewController === placeholderRouter.navigationController {
            return true 
        }
        return false
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        separateSecondaryFrom primaryViewController: UIViewController
    ) -> UIViewController? {
        if let entryViewerRouter = entryViewerRouter {
            return entryViewerRouter.navigationController
        }
        return placeholderRouter.navigationController
    }

    func primaryViewController(forExpanding splitViewController: UISplitViewController) -> UIViewController? {
        return primaryRouter.navigationController
    }
    func primaryViewController(forCollapsing splitViewController: UISplitViewController) -> UIViewController? {
        return primaryRouter.navigationController
    }
}

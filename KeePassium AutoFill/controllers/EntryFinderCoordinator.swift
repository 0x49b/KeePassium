//  KeePassium Password Manager
//  Copyright © 2021 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib
import AuthenticationServices

protocol EntryFinderCoordinatorDelegate: AnyObject {
    func didLeaveDatabase(in coordinator: EntryFinderCoordinator)
    func didSelectEntry(_ entry: Entry, in coordinator: EntryFinderCoordinator)
}

final class EntryFinderCoordinator: Coordinator {
    var childCoordinators = [Coordinator]()
    var dismissHandler: CoordinatorDismissHandler?
    weak var delegate: EntryFinderCoordinatorDelegate?
    
    private let router: NavigationRouter
    private let entryFinderVC: EntryFinderVC
    
    private let databaseFile: DatabaseFile
    private let database: Database
    private let loadingWarnings: DatabaseLoadingWarnings?
    
    private var shouldAutoSelectFirstMatch: Bool = false
    private var serviceIdentifiers: [ASCredentialServiceIdentifier]
    private let searchHelper = SearchHelper()
    
    private let vcAnimationDuration = 0.3
    
    init(
        router: NavigationRouter,
        databaseFile: DatabaseFile,
        loadingWarnings: DatabaseLoadingWarnings?,
        serviceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
        self.router = router
        self.databaseFile = databaseFile
        self.database = databaseFile.database
        self.loadingWarnings = loadingWarnings
        self.serviceIdentifiers = serviceIdentifiers

        entryFinderVC = EntryFinderVC.instantiateFromStoryboard()
        entryFinderVC.delegate = self
        
        entryFinderVC.navigationItem.title = databaseFile.visibleFileName
    }
    
    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }
    
    func start() {
        router.prepareCustomTransition(
            duration: vcAnimationDuration,
            type: .fade,
            timingFunction: .easeOut
        )
        router.push(
            entryFinderVC,
            animated: false, 
            replaceTopViewController: true,
            onPop: { [weak self] in
                guard let self = self else { return }
                self.dismissHandler?(self)
                self.delegate?.didLeaveDatabase(in: self)
            }
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * vcAnimationDuration) { [weak self] in
            self?.showInitialMessages()
        }
    }
    
    func stop(animated: Bool) {
        router.pop(viewController: entryFinderVC, animated: animated)
    }
}

extension EntryFinderCoordinator {
    public func lockDatabase() {
        DatabaseSettingsManager.shared.updateSettings(for: databaseFile) {
            $0.clearMasterKey()
        }
        router.pop(viewController: entryFinderVC, animated: true)
        Diag.info("Database locked")
    }
    
    private func updateCallerID() {
        if serviceIdentifiers.isEmpty {
            entryFinderVC.callerID = nil
            return
        }
        
        let callerID = serviceIdentifiers
            .map { $0.identifier }
            .joined(separator: " | ")
        entryFinderVC.callerID = callerID
    }
    
    private func showInitialMessages() {
        if let loadingWarnings = loadingWarnings {
            showLoadingWarnings(loadingWarnings)
        }
    }
    
    private func showLoadingWarnings(_ warnings: DatabaseLoadingWarnings) {
        guard !warnings.isEmpty else { return }
        
        DatabaseLoadingWarningsVC.present(warnings, in: entryFinderVC, onLockDatabase: lockDatabase)
        StoreReviewSuggester.registerEvent(.trouble)
    }
    
    private func setupAutomaticSearchResults() {
        let results = searchHelper.find(database: database,  serviceIdentifiers: serviceIdentifiers)
        if results.isEmpty {
            entryFinderVC.activateManualSearch()
            return
        }
        
        if let perfectMatch = results.perfectMatch,
           Settings.current.autoFillPerfectMatch
        {
            delegate?.didSelectEntry(perfectMatch, in: self)
        } else {
            entryFinderVC.setSearchResults(results)
        }
    }
    
    private func performManualSearch(searchText: String) {
        var searchResults = FuzzySearchResults(exactMatch: [], partialMatch: [])
        searchResults.exactMatch = searchHelper
            .find(database: database, searchText: searchText)
            .excludingNonAutoFillableEntries()
        searchResults.partialMatch = []
        entryFinderVC.setSearchResults(searchResults)
    }
}

extension EntryFinderCoordinator: EntryFinderDelegate {
    func didLoadViewController(_ viewController: EntryFinderVC) {
        updateCallerID()
        setupAutomaticSearchResults()
    }
    
    func didChangeSearchQuery(_ searchText: String, in viewController: EntryFinderVC) {
        performManualSearch(searchText: searchText)
    }
    
    func didSelectEntry(_ entry: Entry, in viewController: EntryFinderVC) {
        delegate?.didSelectEntry(entry, in: self)
    }
    
    func didPressLockDatabase(in viewController: EntryFinderVC) {
        lockDatabase()
    }
}

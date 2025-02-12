//  KeePassium Password Manager
//  Copyright © 2021 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

final class AboutCoordinator: Coordinator {
    var childCoordinators = [Coordinator]()
    
    var dismissHandler: CoordinatorDismissHandler?
    
    private let router: NavigationRouter
    private let aboutVC: AboutVC
    
    init(router: NavigationRouter) {
        self.router = router
        aboutVC = AboutVC.instantiateFromStoryboard()
        aboutVC.delegate = self
    }
    
    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }
    
    func start() {
        setupDoneButton()
        router.push(aboutVC, animated: true, onPop: { [weak self] in
            guard let self = self else { return }
            self.removeAllChildCoordinators()
            self.dismissHandler?(self)
        })
    }
    
    private func setupDoneButton() {
        guard router.navigationController.topViewController == nil else {
            return
        }
        
        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(didPressDismiss))
        aboutVC.navigationItem.rightBarButtonItem = doneButton
    }
    
    @objc
    private func didPressDismiss(_ sender: UIBarButtonItem) {
        router.dismiss(animated: true)
    }
}

extension AboutCoordinator: AboutDelegate {
    
    func didPressContactSupport(at popoverAnchor: PopoverAnchor, in viewController: AboutVC) {
        SupportEmailComposer.show(subject: .supportRequest, parent: viewController, popoverAnchor: popoverAnchor)
    }
    
    func didPressWriteReview(at popoverAnchor: PopoverAnchor, in viewController: AboutVC) {
        AppStoreHelper.writeReview()
    }
    
    func didPressOpenLicense(url: URL, at popoverAnchor: PopoverAnchor, in viewController: AboutVC) {
        AppGroup.applicationShared?.open(url, options: [:], completionHandler: nil)
    }
}

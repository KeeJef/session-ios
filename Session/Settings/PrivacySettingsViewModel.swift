// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import LocalAuthentication
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class PrivacySettingsViewModel: SessionTableViewModel<PrivacySettingsViewModel.NavButton, PrivacySettingsViewModel.Section, PrivacySettingsViewModel.Item> {
    private let shouldShowCloseButton: Bool
    
    // MARK: - Initialization
    
    init(shouldShowCloseButton: Bool = false) {
        self.shouldShowCloseButton = shouldShowCloseButton
        
        super.init()
    }
    
    // MARK: - Config
    
    enum NavButton: Equatable {
        case close
    }
    
    public enum Section: SessionTableSection {
        case screenSecurity
        case readReceipts
        case typingIndicators
        case linkPreviews
        case calls
        
        var title: String? {
            switch self {
                case .screenSecurity: return "PRIVACY_SECTION_SCREEN_SECURITY".localized()
                case .readReceipts: return "PRIVACY_SECTION_READ_RECEIPTS".localized()
                case .typingIndicators: return "PRIVACY_SECTION_TYPING_INDICATORS".localized()
                case .linkPreviews: return "PRIVACY_SECTION_LINK_PREVIEWS".localized()
                case .calls: return "PRIVACY_SECTION_CALLS".localized()
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
    }
    
    public enum Item: Differentiable {
        case screenLock
        case screenshotNotifications
        case readReceipts
        case typingIndicators
        case linkPreviews
        case calls
    }
    
    // MARK: - Navigation
    
    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
        guard self.shouldShowCloseButton else { return Just([]).eraseToAnyPublisher() }
        
        return Just([
            NavItem(
                id: .close,
                image: UIImage(named: "X")?
                    .withRenderingMode(.alwaysTemplate),
                style: .plain,
                accessibilityIdentifier: "Close Button"
            ) { [weak self] in
                self?.dismissScreen()
            }
        ]).eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    override var title: String { "PRIVACY_TITLE".localized() }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { db -> [SectionModel] in
            return [
                SectionModel(
                    model: .screenSecurity,
                    elements: [
                        SessionCell.Info(
                            id: .screenLock,
                            title: "PRIVACY_SCREEN_SECURITY_LOCK_SESSION_TITLE".localized(),
                            subtitle: "PRIVACY_SCREEN_SECURITY_LOCK_SESSION_DESCRIPTION".localized(),
                            rightAccessory: .toggle(.settingBool(key: .isScreenLockEnabled)),
                            onTap: { [weak self] in
                                // Make sure the device has a passcode set before allowing screen lock to
                                // be enabled (Note: This will always return true on a simulator)
                                guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_NOT_AVAILABLE".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                Storage.shared.write { db in
                                    db[.isScreenLockEnabled] = !db[.isScreenLockEnabled]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .readReceipts,
                    elements: [
                        SessionCell.Info(
                            id: .readReceipts,
                            title: "PRIVACY_READ_RECEIPTS_TITLE".localized(),
                            subtitle: "PRIVACY_READ_RECEIPTS_DESCRIPTION".localized(),
                            rightAccessory: .toggle(.settingBool(key: .areReadReceiptsEnabled)),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.areReadReceiptsEnabled] = !db[.areReadReceiptsEnabled]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .typingIndicators,
                    elements: [
                        SessionCell.Info(
                            id: .typingIndicators,
                            title: SessionCell.TextInfo(
                                "PRIVACY_TYPING_INDICATORS_TITLE".localized(),
                                font: .title
                            ),
                            subtitle: SessionCell.TextInfo(
                                "PRIVACY_TYPING_INDICATORS_DESCRIPTION".localized(),
                                font: .subtitle,
                                extraViewGenerator: {
                                    let targetHeight: CGFloat = 20
                                    let targetWidth: CGFloat = ceil(20 * (targetHeight / 12))
                                    let result: UIView = UIView(
                                        frame: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
                                    )
                                    result.set(.width, to: targetWidth)
                                    result.set(.height, to: targetHeight)
                                    
                                    // Use a transform scale to reduce the size of the typing indicator to the
                                    // desired size (this way the animation remains intact)
                                    let cell: TypingIndicatorCell = TypingIndicatorCell()
                                    cell.transform = CGAffineTransform.scale(targetHeight / cell.bounds.height)
                                    cell.typingIndicatorView.startAnimation()
                                    result.addSubview(cell)
                                    
                                    // Note: Because we are messing with the transform these values don't work
                                    // logically so we inset the positioning to make it look visually centered
                                    // within the layout inspector
                                    cell.center(.vertical, in: result, withInset: -(targetHeight * 0.15))
                                    cell.center(.horizontal, in: result, withInset: -(targetWidth * 0.35))
                                    cell.set(.width, to: .width, of: result)
                                    cell.set(.height, to: .height, of: result)
                                    
                                    return result
                                }
                            ),
                            rightAccessory: .toggle(.settingBool(key: .typingIndicatorsEnabled)),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.typingIndicatorsEnabled] = !db[.typingIndicatorsEnabled]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .linkPreviews,
                    elements: [
                        SessionCell.Info(
                            id: .linkPreviews,
                            title: "PRIVACY_LINK_PREVIEWS_TITLE".localized(),
                            subtitle: "PRIVACY_LINK_PREVIEWS_DESCRIPTION".localized(),
                            rightAccessory: .toggle(.settingBool(key: .areLinkPreviewsEnabled)),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.areLinkPreviewsEnabled] = !db[.areLinkPreviewsEnabled]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .calls,
                    elements: [
                        SessionCell.Info(
                            id: .calls,
                            title: "PRIVACY_CALLS_TITLE".localized(),
                            subtitle: "PRIVACY_CALLS_DESCRIPTION".localized(),
                            rightAccessory: .toggle(.settingBool(key: .areCallsEnabled)),
                            accessibility: Accessibility(
                                label: "Allow voice and video calls"
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "PRIVACY_CALLS_WARNING_TITLE".localized(),
                                body: .text("PRIVACY_CALLS_WARNING_DESCRIPTION".localized()),
                                showCondition: .disabled,
                                confirmTitle: "continue_2".localized(),
                                confirmAccessibility: Accessibility(identifier: "Enable"),
                                confirmStyle: .textPrimary,
                                onConfirm: { _ in Permissions.requestMicrophonePermissionIfNeeded() }
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.areCallsEnabled] = !db[.areCallsEnabled]
                                }
                            }
                        )
                    ]
                )
            ]
        }
        .removeDuplicates()
        .handleEvents(didFail: { SNLog("[PrivacySettingsViewModel] Observation failed with error: \($0)") })
        .publisher(in: Storage.shared)
        .mapToSessionTableViewData(for: self)
}

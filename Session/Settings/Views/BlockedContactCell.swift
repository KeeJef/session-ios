// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

class BlockedContactCell: UITableViewCell {
    // MARK: - Components
    
    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(size: .list)
    
    private let selectionView: RadioButton = {
        let result: RadioButton = RadioButton(size: .medium)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.isUserInteractionEnabled = false
        result.font = .systemFont(ofSize: Values.mediumFontSize, weight: .bold)
        
        return result
    }()
    
    // MARK: - Initializtion
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setUpViewHierarchy()
    }
    
    // MARK: - Layout
    
    private func setUpViewHierarchy() {
        // Background color
        themeBackgroundColor = .conversationButton_background
        
        // Highlight color
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        // Add the UI
        contentView.addSubview(profilePictureView)
        contentView.addSubview(selectionView)
        
        setupLayout()
    }
    
    private func setupLayout() {
        // Profile picture view
        profilePictureView.center(.vertical, in: contentView)
        profilePictureView.topAnchor
            .constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Values.mediumSpacing)
            .isActive = true
        profilePictureView.bottomAnchor
            .constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Values.mediumSpacing)
            .isActive = true
        profilePictureView.pin(.left, to: .left, of: contentView, withInset: Values.veryLargeSpacing)
        
        selectionView.center(.vertical, in: contentView)
        selectionView.topAnchor
            .constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Values.mediumSpacing)
            .isActive = true
        selectionView.bottomAnchor
            .constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Values.mediumSpacing)
            .isActive = true
        selectionView.pin(.left, to: .right, of: profilePictureView, withInset: Values.mediumSpacing)
        selectionView.pin(.right, to: .right, of: contentView, withInset: -Values.veryLargeSpacing)
    }
    
    // MARK: - Content
    
    public func update(with cellViewModel: BlockedContactsViewModel.DataModel, isSelected: Bool) {
        profilePictureView.update(
            publicKey: cellViewModel.id,
            threadVariant: .contact,
            customImageData: nil,
            profile: cellViewModel.profile,
            additionalProfile: nil
        )
        selectionView.text = (
            cellViewModel.profile?.displayName() ??
            Profile.truncated(id: cellViewModel.id, truncating: .middle)
        )
        selectionView.update(isSelected: isSelected)
    }
}

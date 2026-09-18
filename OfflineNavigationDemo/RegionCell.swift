import UIKit

/// Shared region row. Catalog state is descriptive; live transfer progress comes from
/// `observeOfflineRegionProgress` and is supplied separately to `configure`.
final class RegionCell: UITableViewCell {
    static let reuseIdentifier = "RegionCell"

    private let titleLabel = UILabel()
    private let detailsLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private var stackLeadingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        detailsLabel.font = .preferredFont(forTextStyle: .caption1)
        detailsLabel.textColor = .secondaryLabel
        detailsLabel.numberOfLines = 0
        detailsLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailsLabel, progressView])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        accessoryType = .detailButton
        stackLeadingConstraint = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stackLeadingConstraint,
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        details: String,
        progress: Int?,
        updateAvailable: Bool,
        indentationLevel: Int = 0
    ) {
        titleLabel.text = title
        titleLabel.textColor = updateAvailable ? .systemOrange : .label
        detailsLabel.text = details
        stackLeadingConstraint.constant = 16 + CGFloat(indentationLevel) * 18
        if let progress {
            progressView.isHidden = false
            progressView.progress = Float(max(0, min(100, progress))) / 100
        } else {
            progressView.isHidden = true
            progressView.progress = 0
        }
    }
}

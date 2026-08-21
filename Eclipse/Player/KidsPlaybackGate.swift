import UIKit

@MainActor
enum KidsPlaybackGate {

    struct Identity: Equatable {
        let isMovie: Bool
        let id: Int

        let title: String

        let policyDetails: KidsPolicyDetails?
    }

    enum Decision: Equatable {

        case allow

        case deny

        case resolve(Identity)
    }

    private static let resolutionBudget: TimeInterval = 2

    private static let pollInterval: TimeInterval = 0.08

    private static let denialMessage = "Not available on this profile"

    static func decision(for request: PlaybackRequest) -> Decision {
        guard ProfileManager.shared.isKidsModeActive else { return .allow }
        guard let identity = identity(for: request) else {
            Logger.shared.log(
                "KidsPlaybackGate: denied playback with no validated TMDB identity",
                type: "Player"
            )
            return .deny
        }

        guard TMDBContentFilter.kidsTextHeuristicsAllow(title: identity.title) else {
            Logger.shared.log(
                "KidsPlaybackGate: denied playback of \"\(identity.title)\" on metadata heuristics",
                type: "Player"
            )
            return .deny
        }
        guard let rating = TMDBMaturityRatingStore.shared.rating(
            isMovie: identity.isMovie,
            id: identity.id
        ) else {
            return .resolve(identity)
        }
        if rating.isBlockedForKids {

            return .deny
        }

        switch cachedDetailDecision(for: identity) {
        case .some(true):
            return .allow
        case .some(false):
            return .deny
        case .none:
            return .resolve(identity)
        }
    }

    private static func cachedDetailDecision(for identity: Identity) -> Bool? {
        var hasAllowedAuthority = false
        if let details = identity.policyDetails {
            guard TMDBContentFilter.kidsDetailPolicyAllows(
                title: identity.title,
                isAdult: details.isAdult,
                genreIds: details.genreIds,
                overview: details.overview
            ) else { return false }
            hasAllowedAuthority = true
        }
        if let stored = TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
            isMovie: identity.isMovie,
            id: identity.id
        ) {
            guard stored else { return false }
            hasAllowedAuthority = true
        }
        return hasAllowedAuthority ? true : nil
    }

    private static func identity(for request: PlaybackRequest) -> Identity? {
        guard let mediaInfo = request.mediaInfo else { return nil }
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            return id > 0
                ? Identity(isMovie: true, id: id, title: title, policyDetails: request.kidsPolicyDetails)
                : nil
        case .episode(let showId, _, _, let showTitle, _, _):
            return showId > 0
                ? Identity(
                    isMovie: false,
                    id: showId,
                    title: showTitle ?? "",
                    policyDetails: request.kidsPolicyDetails
                  )
                : nil
        }
    }

    static func presentDenial(from presenter: UIViewController, animated: Bool) {
        let host = KidsPlaybackGateHostViewController(state: .denied(message: denialMessage))
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: animated)
    }

    static func presentResolving(
        _ identity: Identity,
        from presenter: UIViewController,
        animated: Bool,
        onApproval: @escaping (KidsPlaybackGateHostViewController) -> Void
    ) {

        let initiatingProfileID = ProfileManager.shared.activeProfileID

        let host = KidsPlaybackGateHostViewController(state: .resolving)
        host.modalPresentationStyle = .fullScreen

        let verdict = Task { @MainActor in
            await awaitFullVerdict(identity, budget: resolutionBudget)
        }

        presenter.present(host, animated: animated) {
            Task { @MainActor [weak host] in
                let allowed = await verdict.value
                guard let host, !host.isBeingDismissed, host.viewIfLoaded?.window != nil else {

                    return
                }
                guard ProfileManager.shared.activeProfileID == initiatingProfileID else {
                    Logger.shared.log(
                        "KidsPlaybackGate: aborted playback because the profile changed during resolution",
                        type: "Player"
                    )
                    host.dismiss(animated: true)
                    return
                }
                guard allowed == true else {
                    Logger.shared.log(
                        "KidsPlaybackGate: denied \(identity.isMovie ? "movie" : "tv")/\(identity.id) because its full verdict was blocked or unresolved within budget",
                        type: "Player"
                    )
                    host.showDenial(message: denialMessage)
                    return
                }
                guard ProfileManager.shared.activeProfileID == initiatingProfileID,
                      !host.isBeingDismissed else { return }
                onApproval(host)
            }
        }
    }

    private static func awaitFullVerdict(
        _ identity: Identity,
        budget: TimeInterval
    ) async -> Bool? {
        let store = TMDBMaturityRatingStore.shared
        if let cached = cachedFullDecision(for: identity) { return cached }

        let resolution = Task {
            await store.resolve([(isMovie: identity.isMovie, id: identity.id)])
        }
        defer { resolution.cancel() }

        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if let decision = cachedFullDecision(for: identity) { return decision }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return cachedFullDecision(for: identity)
    }

    private static func cachedFullDecision(for identity: Identity) -> Bool? {
        guard let rating = TMDBMaturityRatingStore.shared.rating(
            isMovie: identity.isMovie,
            id: identity.id
        ) else { return nil }
        guard !rating.isBlockedForKids,
              TMDBContentFilter.kidsTextHeuristicsAllow(title: identity.title) else {
            return false
        }
        return cachedDetailDecision(for: identity)
    }
}

@MainActor
final class KidsPlaybackGateHostViewController: UIViewController {
    enum State {
        case resolving
        case denied(message: String)
    }

    private let initialState: State
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    init(state: State) {
        self.initialState = state
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
#if os(tvOS)
        messageLabel.font = .systemFont(ofSize: 38, weight: .semibold)
#else
        messageLabel.font = .systemFont(ofSize: 20, weight: .semibold)
#endif
        messageLabel.isHidden = true
        view.addSubview(messageLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(handleClose), for: .primaryActionTriggered)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 32
            ),
            messageLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -32
            ),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 28)
        ])

        switch initialState {
        case .resolving:
            spinner.startAnimating()
        case .denied(let message):
            showDenial(message: message)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        closeButton.isHidden ? super.preferredFocusEnvironments : [closeButton]
    }

    func showDenial(message: String) {
        spinner.stopAnimating()
        messageLabel.text = message
        messageLabel.isHidden = false
        closeButton.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }
}
